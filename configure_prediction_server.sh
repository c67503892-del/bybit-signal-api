#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Configure how the prediction server RESPONDS for a specific client_id.
#
# This is NOT the bot's trading logic (that lives in config_live_ai_bot.json).
# Here we only set HOW the server shapes signals for our client_id:
#   • signal_threshold    — confidence threshold (max of prob_*) to emit a signal
#   • max_signal_time_sec — upper horizon bound; beyond it no signal is returned
#   • sample_every_ticks  — how often (every N ticks) the server actually predicts
#
# Parameters are named and tied to client_id (see README). Run once
# (and re-run whenever you change settings):
#   chmod +x configure_prediction_server.sh
#   ./configure_prediction_server.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Server base = SERVER_URL from config_live_ai_bot.json without the /tick suffix.
SERVER_BASE="http://137.184.119.173:5099"
CLIENT_ID="USER"

# ── Response settings for this client_id ─────────────────────────────────────
# Ranges (see README):
#   signal_threshold    0.0–1.0   lower = more signals/noise, higher = rarer/surer
#   max_signal_time_sec 1–3600    scalper 60–120, swing 600+
#   sample_every_ticks  1–10000   lower = predict more often, higher load
SIGNAL_THRESHOLD=0.40
MAX_SIGNAL_TIME_SEC=1800
SAMPLE_EVERY_TICKS=50

echo "[CONFIG] -> ${SERVER_BASE}/config  client_id=${CLIENT_ID}"
curl -sS -X POST "${SERVER_BASE}/config" \
  -H "Content-Type: application/json" \
  -d "{
    \"client_id\": \"${CLIENT_ID}\",
    \"signal_threshold\": ${SIGNAL_THRESHOLD},
    \"max_signal_time_sec\": ${MAX_SIGNAL_TIME_SEC},
    \"sample_every_ticks\": ${SAMPLE_EVERY_TICKS}
  }"
echo

# Verify the server accepted the settings.
echo "[CHECK] current settings for client_id=${CLIENT_ID}:"
curl -sS "${SERVER_BASE}/config?client_id=${CLIENT_ID}"
echo
