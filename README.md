# bybit-signal-api

REST API server for **Bybit** trading signals (BTCUSDT perpetual futures), powered by a **DQN + CNN/LSTM** model.

A client streams exchange trades (ticks) to the server and receives a signal — **LONG / SHORT / no signal** — together with class probabilities and an expected validity time. Every client is configured individually by its `client_id`.

---

## What the server does

- **Direction prediction** — the model has two heads:
  - classification: `prob_long` / `prob_hold` / `prob_short` (softmax); the signal is taken from these;
  - time regression: `predicted_time_sec` — how many seconds the signal stays valid.
- **Per-client settings** (by `client_id`), with no retraining of the model.
- **Trend detector** over the live stream: the `direction` field (+1 long / −1 short / 0 undecided).
- The model is shared by everyone (weights, features and window are fixed) — but **entry threshold, sampling rate and horizon are per-client**.

By default the server listens on `http://127.0.0.1:5009`.

---

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/tick` | Send a market tick → get a prediction |
| `POST` | `/config` | Set client settings |
| `GET`  | `/config?client_id=...` | Read current client settings |
| `GET`  | `/state?client_id=...` | Detector state (incl. `direction`) |
| `POST` | `/reset?client_id=...` | Reset client state |

---

## Client settings

All parameters are named and tied to `client_id`. They change without retraining:

| Parameter | Range | What it does |
|-----------|-------|--------------|
| `signal_threshold` | 0.0 – 1.0 | Confidence threshold to enter LONG/SHORT. Default `0.40`. Lower = more signals / more noise. Higher = rarer but more confident. |
| `max_signal_time_sec` | 1 – 3600 | Max expected move time for which a signal is still considered valid. Default `600`. Scalper: 60–120, swing: 600+. |
| `sample_every_ticks` | 1 – 10000 | How often the model predicts (every N-th tick). Default `50`. Lower = more frequent compute, higher load. |

### Example: set settings

```bash
curl -X POST http://127.0.0.1:5009/config \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "scalper-1",
    "signal_threshold": 0.35,
    "max_signal_time_sec": 120,
    "sample_every_ticks": 20
  }'
```

Change a single parameter (others untouched):

```bash
curl -X POST http://127.0.0.1:5009/config \
  -H "Content-Type: application/json" \
  -d '{"client_id": "scalper-1", "signal_threshold": 0.30}'
```

Read current settings:

```bash
curl "http://127.0.0.1:5009/config?client_id=scalper-1"
```

---

## Get a prediction (`/tick`)

One tick = one exchange trade (`timestamp`, `side`, `size`, `price`). You can also pass `config` on the first tick.

```bash
curl -X POST http://127.0.0.1:5009/tick \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "trader-1",
    "timestamp": 1781514080.5,
    "side": "Buy",
    "size": 0.123,
    "price": 65700.0
  }'
```

**No signal yet:**

```json
{"message": "Signal not ready yet"}
```

**When there is a signal:**

```json
{
  "signal": "SHORT",
  "predicted_time_sec": 427.49,
  "prob_short": 0.6399,
  "prob_hold":  0.2975,
  "prob_long":  0.0626,
  "price": 62634.1,
  "timestamp": 1781844609.652
}
```

### How to read the response

- `signal` — entry direction: `LONG` (buy at ask) / `SHORT` (sell at bid).
- `predicted_time_sec` — how many seconds the signal stays valid.
- `prob_short` / `prob_hold` / `prob_long` — class probabilities (returned by the server).
- **Confidence** = `max(prob_short, prob_hold, prob_long)` — computed on the client side. The server compares this max against `signal_threshold`: if `max >= threshold` it returns a `signal`, otherwise `"Signal not ready yet"`.

> In a live stream it is normal to see many "no signal" responses and only occasional signals.

---

## The model needs a live stream

On the first tick the server returns `"Signal not ready yet"` — the model must accumulate **128 ticks** (`lookback_ticks`). Repeating the same REST price is useless: predictions on identical prices are meaningless. You need a **live trade stream** (Bybit WebSocket).

> **Ticks flowing but still no signal?** That is normal and usually not a bug — the model is waiting for the market to pick a direction, which can take a while in a flat market. See **[WAITING.md](WAITING.md)** for the full explanation.

### Live stream: Bybit WebSocket → server

Requires `websocat`, `jq`, `curl`. Subscribe to `publicTrade.BTCUSDT` and send every trade to `/tick`. After ~128 trades signals start arriving.

```bash
#!/usr/bin/env bash
set -euo pipefail

CLIENT_ID="trader-1"
PREDICT_URL="http://127.0.0.1:5009/tick"
WS_URL="wss://stream.bybit.com/v5/public/linear"
SUB='{"op":"subscribe","args":["publicTrade.BTCUSDT"]}'

{ echo "$SUB"; cat; } | websocat -n "$WS_URL" | while IFS= read -r MSG; do
  echo "$MSG" | jq -c '.data[]? // empty' | while IFS= read -r TRADE; do
    PRICE=$(echo "$TRADE" | jq -r '.p')
    SIDE=$(echo  "$TRADE" | jq -r '.S')
    SIZE=$(echo  "$TRADE" | jq -r '.v')
    TS=$(echo    "$TRADE" | jq -r '.T/1000')

    curl -s -X POST "$PREDICT_URL" \
      -H "Content-Type: application/json" \
      -d "{\"client_id\":\"$CLIENT_ID\",\"timestamp\":$TS,\"side\":\"$SIDE\",\"size\":$SIZE,\"price\":$PRICE}" \
      | jq -rc 'if .signal then "\(.signal) — confidence \(([.prob_short,.prob_hold,.prob_long]|max)*100|round)% — ~\(.predicted_time_sec|round)s" else (.message // "no signal") end'
  done
done
```

Example output:

```
SHORT — confidence 64% — ~427s
```

---

## Price from Bybit

Current BTCUSDT ticker (USDT perpetual):

```bash
curl "https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT"
```

- For **buying**, use `ask1Price` (a market buy fills there).
- For **selling**, use `bid1Price`.
- `lastPrice` — last trade price.

Buy price only (needs `jq`):

```bash
curl -s "https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT" \
  | jq -r '.result.list[0].ask1Price'
```

---

## Trend detector (`/state`, `/reset`)

```bash
curl "http://127.0.0.1:5009/state?client_id=trader-1"
```

Key field `direction`: `-1` downtrend (model leans SHORT), `+1` uptrend, `0` undecided.

If the detector is stuck on an old seed state, reset it and let it catch the trend from the live stream:

```bash
curl -X POST "http://127.0.0.1:5009/reset?client_id=trader-1" \
  -H "Content-Type: application/json" \
  -d '{"use_seed": false}'
```

After a reset, `direction` starts at `0`; once price moves ~0.30% in one direction it locks into the current direction (needs to re-accumulate 128 ticks, ~3–5 min on BTCUSDT).
