# Why there are no predictions yet — and why you need to wait

**Short version:** if ticks are flowing and prices update but you get no signal, the server is **not** broken. The model is waiting for the market to pick a direction. This can take a long time in a flat market. Be patient — once the market moves, predictions start on their own.

---

## "Ticks are flowing but nothing happens" is normal

Seeing `[TICK]` logs with fresh, changing prices means your **WebSocket to Bybit is alive** and the realtime stream works. That does **not** mean the model is producing signals yet. These are two independent things:

| Channel | What it is | Sign of life |
|---------|-----------|--------------|
| Realtime stream | WebSocket → Bybit | `[TICK]` logs, fresh prices |
| Prediction channel | `POST /tick` → server | a `signal` in the response |

A live realtime stream is a prerequisite, not a guarantee. The model still needs two more things before it speaks.

---

## What the model is waiting for

### 1. Enough history (warm-up)

The model needs to accumulate **128 ticks** (`lookback_ticks`) before it can predict anything. On the first ticks you will see:

```json
{"message": "Signal not ready yet"}
```

This is the warm-up. On BTCUSDT it usually takes a few minutes of live trades. **Repeating the same REST price does not help** — predictions on identical prices are meaningless. You need a live trade stream.

### 2. A trend direction (the real blocker)

The server has a **trend detector** that outputs a `direction`:

- `+1` — uptrend
- `-1` — downtrend
- `0` — undecided

`direction` is an **input feature** the model was trained with. While `direction = 0` ("regime undecided"), the model is in a state it almost never saw during training, so it honestly returns **HOLD** and emits no actionable signal.

After a `reset`, `direction` starts at `0` and only locks into `+1` or `-1` once price moves **±0.30%** from the reset point. Until that break happens, there is no prediction — by design, not by failure.

```
        ▲  break up   → direction = +1
        │
   ●  price now (still inside the corridor)
   ┼  reset point
        │
        ▼  break down → direction = -1
```

If the price drifts inside that ±0.30% corridor, the detector stays at `0` and you wait.

---

## Why 0.30% — and why you can't change it

`trend_pct = 0.30%` is a **noise filter** (a ZigZag / swing filter), not a profit target and not a stop-loss. Tiny ±0.05–0.1% wiggles are market noise; the detector only calls a move a "trend" once price travels a meaningful distance — 0.30% on BTC.

This value is **baked in at training time**. The `direction` feature must be computed identically in training and in production, otherwise the model gets input it was never trained on. That is why `trend_pct` is **not** a configurable parameter (`/config` only accepts `signal_threshold`, `max_signal_time_sec`, `sample_every_ticks`). Changing it would require retraining the model.

---

## How long do I wait?

This is a question about the **market**, not the server:

- **Flat market** — price stuck inside the ±0.30% corridor. You can wait a long time, sometimes an hour or more.
- **Volatility returns** — as soon as price breaks the corridor, `direction` locks in within seconds and predictions start immediately.

There is nothing to fix on your side. Keep the live stream running and wait for the move.

---

## Want to test the pipeline right now?

If you just want to confirm everything works end-to-end without waiting for a real breakout, reset with a seed direction:

```bash
curl -X POST "http://137.184.119.173:5099/reset?client_id=trader-1" \
  -H "Content-Type: application/json" \
  -d '{"use_seed": true}'
```

This forces a starting `direction` so predictions begin almost immediately.

> **Trade-off:** the seeded direction may be stale or wrong, so the first predictions can be off until a real move confirms the trend. Use it for testing the pipeline, not for live decisions.
