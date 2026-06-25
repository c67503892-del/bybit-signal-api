# bybit-signal-api

REST API-сервер торговых сигналов для Bybit (BTCUSDT, бессрочный фьючерс), работающий на модели **DQN + CNN/LSTM**.

Клиент шлёт серверу поток сделок с биржи (тики), сервер возвращает сигнал — **LONG / SHORT / нет сигнала** — с вероятностями и ожидаемым временем актуальности. Каждый клиент настраивается индивидуально по своему `client_id`.

---

## Что умеет сервер

- **Предсказание направления** — модель с двумя головами:
  - классификация: `prob_long` / `prob_hold` / `prob_short` (softmax), из них выбирается сигнал;
  - регрессия времени: `predicted_time_sec` — сколько секунд сигнал актуален.
- **Индивидуальные настройки на каждого клиента** (по `client_id`), без переобучения модели.
- **Детектор тренда** на живом потоке: поле `direction` (+1 лонг / −1 шорт / 0 не определился).
- Модель одна для всех (веса, признаки, окно фиксированы) — но **порог входа, частота сэмплинга и горизонт у каждого клиента свои**.

Сервер по умолчанию слушает `http://127.0.0.1:5009`.

---

## Эндпоинты

| Метод | Путь | Назначение |
|-------|------|-----------|
| `POST` | `/tick` | Отправить тик рынка → получить предсказание |
| `POST` | `/config` | Задать настройки клиента |
| `GET`  | `/config?client_id=...` | Посмотреть текущие настройки клиента |
| `GET`  | `/state?client_id=...` | Состояние детектора (в т.ч. `direction`) |
| `POST` | `/reset?client_id=...` | Сбросить состояние клиента |

---

## Настройки клиента

Все параметры именные, привязаны к `client_id`. Меняются без переобучения:

| Параметр | Диапазон | Что делает |
|----------|----------|-----------|
| `signal_threshold` | 0.0 – 1.0 | Порог уверенности для входа в LONG/SHORT. По умолчанию `0.40`. Ниже = больше сигналов / больше шума. Выше = реже, но увереннее. |
| `max_signal_time_sec` | 1 – 3600 | Максимальное ожидаемое время движения, при котором сигнал актуален. По умолчанию `600`. Скальпер: 60–120, свинг: 600+. |
| `sample_every_ticks` | 1 – 10000 | Как часто модель предсказывает (каждый N-й тик). По умолчанию `50`. Меньше = чаще считать, выше нагрузка. |

### Пример: задать настройки

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

Изменить только один параметр (остальные не трогаются):

```bash
curl -X POST http://127.0.0.1:5009/config \
  -H "Content-Type: application/json" \
  -d '{"client_id": "scalper-1", "signal_threshold": 0.30}'
```

Посмотреть текущие настройки:

```bash
curl "http://127.0.0.1:5009/config?client_id=scalper-1"
```

---

## Получить предсказание (`/tick`)

Один тик = одна сделка с биржи (`timestamp`, `side`, `size`, `price`). Можно задать `config` прямо при первом тике.

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

**Пока сигнала нет:**

```json
{"message": "Сигнал ещё не готов"}
```

**Когда есть сигнал:**

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

### Как читать ответ

- `signal` — направление входа: `LONG` (покупка по ask) / `SHORT` (продажа по bid).
- `predicted_time_sec` — сколько секунд сигнал актуален.
- `prob_short` / `prob_hold` / `prob_long` — вероятности по классам (приходят с сервера).
- **Уверенность** = `max(prob_short, prob_hold, prob_long)` — считается на стороне клиента. Сервер сравнивает этот max с `signal_threshold`: если `max >= порога` — отдаёт `signal`, иначе `«Сигнал ещё не готов»`.

> В живом потоке нормально видеть много «нет сигнала» и изредка — сигналы.

---

## Важно: модели нужен живой поток

На первом тике сервер отвечает `«Сигнал ещё не готов»` — модели надо накопить **128 тиков** (`lookback_ticks`). Повтор одной и той же REST-цены бесполезен: на одинаковых ценах предсказание не имеет смысла. Нужен **живой поток сделок** (Bybit WebSocket).

### Живой поток: Bybit WebSocket → сервер

Требуется `websocat`, `jq`, `curl`. Подписываемся на `publicTrade.BTCUSDT`, каждую сделку шлём в `/tick`. Через ~128 сделок начнут приходить сигналы.

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
      | jq -rc 'if .signal then "\(.signal) — уверенность \(([.prob_short,.prob_hold,.prob_long]|max)*100|round)% — ~\(.predicted_time_sec|round) сек" else (.message // "нет сигнала") end'
  done
done
```

Пример вывода:

```
SHORT — уверенность 64% — ~427 сек
```

---

## Цена с Bybit

Текущий тикер BTCUSDT (перпетуал USDT):

```bash
curl "https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT"
```

- Для **покупки** важна `ask1Price` (по ней исполнится маркет-buy).
- Для **продажи** — `bid1Price`.
- `lastPrice` — цена последней сделки.

Только цена покупки (нужен `jq`):

```bash
curl -s "https://api.bybit.com/v5/market/tickers?category=linear&symbol=BTCUSDT" \
  | jq -r '.result.list[0].ask1Price'
```

---

## Детектор тренда (`/state`, `/reset`)

```bash
curl "http://127.0.0.1:5009/state?client_id=trader-1"
```

Ключевое поле `direction`: `-1` нисходящий тренд (модель тянет в SHORT), `+1` восходящий, `0` не определился.

Если детектор «застрял» от старого seed-состояния — сбрось и дай поймать тренд по живому потоку:

```bash
curl -X POST "http://127.0.0.1:5009/reset?client_id=trader-1" \
  -H "Content-Type: application/json" \
  -d '{"use_seed": false}'
```

После сброса `direction` начнёт с `0`; как только цена пройдёт ~0.30% в одну сторону — встанет в актуальное направление (нужно снова накопить 128 тиков, ~3–5 мин на BTCUSDT).
