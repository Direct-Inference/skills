#!/usr/bin/env bash
# verify.sh — replays LibreChat's OpenAI custom-endpoint request sequence
# against the DirectInference endpoint and asserts each step works.
#
# LibreChat speaks the OpenAI dialect for a custom endpoint, so this mirrors
# the requests a LibreChat instance actually issues, in order:
#
#   0. GET /di/v1/models      — model discovery (models.fetch: true). Asserts
#      the catalog lists di-fusion, di-saver, di-max so the selector is populated.
#      Spends no tokens, so it fails fast on a bad host/key.
#   1. Streaming chat          — every user message: POST stream:true. Confirms
#      SSE survives the round trip (catches proxies that buffer/strip streams).
#   2. Title generation        — the titleConvo completion: a short non-stream
#      request with the title model (di-saver).
#   3. Default param set       — the params LibreChat tacks on by default
#      (temperature/top_p/penalties/stop/user). Proves no `dropParams` needed.
#   4. Custom headers          — the optional headers block (X-Title +
#      X-DI-Effort) is accepted.
#
# Checks 1–4 assert the response echoes the model id sent AND carries the
# X-DI-Request-Type header. Only DirectInference sets that header, so its
# presence proves the request reached DI and didn't quietly land elsewhere —
# a model echo alone can false-pass for ids another provider also serves.
#
# Required env:
#   DIRECTINFERENCE_API_KEY   llm_live_* credential (issued at
#                             https://app.directinference.com/api-keys)
#
# Optional env:
#   DIRECTINFERENCE_BASE_URL  host of the target server. Default:
#                             https://api.directinference.com
#
# Exit code: 0 on all-pass, 1 on any failure, 2 on missing key.

set -uo pipefail

HOST="${DIRECTINFERENCE_BASE_URL:-https://api.directinference.com}"
HOST="${HOST%/}"
KEY="${DIRECTINFERENCE_API_KEY:-}"

if [[ -z "$KEY" ]]; then
  echo "ERROR: DIRECTINFERENCE_API_KEY is not set." >&2
  echo "Issue a key at https://app.directinference.com/api-keys and export it." >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: curl is required but not on PATH." >&2
  exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "base_url : $HOST/di/v1"
echo

pass=0
fail=0

ok()  { echo "PASS  $1"; pass=$((pass + 1)); }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }

# Request-type header from a curl -D header dump (empty string if absent).
request_type() {
  grep -i '^x-di-request-type:' "$1" | head -1 | cut -d: -f2 | tr -d ' \r'
}

# ---------------------------------------------------------------------------
# 0. Model discovery — GET /di/v1/models (models.fetch: true)
#
# LibreChat populates its model selector from this list before any chat.
# ---------------------------------------------------------------------------
code=$(curl -sS -o "$work/models.json" -w '%{http_code}' \
  "$HOST/di/v1/models" \
  -H "Authorization: Bearer $KEY" || echo "000")

if [[ "$code" == "200" ]] \
   && grep -q '"di-fusion"' "$work/models.json" \
   && grep -q '"di-saver"' "$work/models.json" \
   && grep -q '"di-max"' "$work/models.json"; then
  ok "model discovery — GET /di/v1/models lists di-fusion, di-saver, di-max"
else
  bad "model discovery — HTTP $code (expected 200 listing di-fusion, di-saver, di-max)"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/models.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 1. Streaming chat — POST /di/v1/chat/completions (stream:true)
# ---------------------------------------------------------------------------
chat_model="di-fusion"
chat_body=$(cat <<JSON
{"model":"$chat_model","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -N -D "$work/chat.h" -o "$work/chat.sse" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d "$chat_body" || echo "000")

rt=$(request_type "$work/chat.h")
if [[ "$code" == "200" && -n "$rt" ]] \
   && grep -q '^data: {' "$work/chat.sse" \
   && grep -q '^data: \[DONE\]' "$work/chat.sse" \
   && grep -q "\"model\":\"$chat_model\"" "$work/chat.sse"; then
  ok "streaming chat — OpenAI SSE completed, model echoed ($chat_model), request type: $rt"
else
  bad "streaming chat — HTTP $code (expected 200 SSE ending in data: [DONE], model:\"$chat_model\", and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/chat.sse" >&2 || true
fi

# ---------------------------------------------------------------------------
# 2. Title generation — POST /di/v1/chat/completions (non-stream, titleModel)
#
# With titleConvo: true LibreChat issues a short non-streaming completion with
# the title model to name the conversation.
# ---------------------------------------------------------------------------
title_model="di-saver"
title_body=$(cat <<JSON
{"model":"$title_model","max_tokens":32,"messages":[{"role":"system","content":"Write a short title for the conversation."},{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -D "$work/title.h" -o "$work/title.json" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d "$title_body" || echo "000")

rt=$(request_type "$work/title.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"model\":\"$title_model\"" "$work/title.json"; then
  ok "title generation — non-stream completion, model echoed ($title_model), request type: $rt"
else
  bad "title generation — HTTP $code (expected 200 with model:\"$title_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/title.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 3. Default param set — the params LibreChat adds by default
#
# DirectInference accepts the standard OpenAI params and strips unknowns, so a
# LibreChat config needs no `dropParams` to avoid a 400. This asserts that.
# ---------------------------------------------------------------------------
param_model="di-fusion"
param_body=$(cat <<JSON
{"model":"$param_model","max_tokens":32,"temperature":0.8,"top_p":1,"presence_penalty":0,"frequency_penalty":0,"stop":[],"user":"librechat-user-1","messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -D "$work/param.h" -o "$work/param.json" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d "$param_body" || echo "000")

rt=$(request_type "$work/param.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"model\":\"$param_model\"" "$work/param.json"; then
  ok "default param set — temperature/top_p/penalties/stop/user accepted, request type: $rt"
else
  bad "default param set — HTTP $code (expected 200 with model:\"$param_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/param.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 4. Custom headers — the optional librechat.yaml headers: block
#
# X-Title (per-app usage attribution) + X-DI-Effort (cost/quality bias) must be
# accepted and must not suppress the request-type header.
# ---------------------------------------------------------------------------
header_model="di-fusion"
header_body=$(cat <<JSON
{"model":"$header_model","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -D "$work/header.h" -o "$work/header.json" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -H 'X-Title: LibreChat' \
  -H 'X-DI-Effort: medium' \
  -d "$header_body" || echo "000")

rt=$(request_type "$work/header.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"model\":\"$header_model\"" "$work/header.json"; then
  ok "custom headers — X-Title + X-DI-Effort accepted, request type: $rt"
else
  bad "custom headers — HTTP $code (expected 200 with model:\"$header_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/header.json" >&2 || true
fi

echo
total=$((pass + fail))
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED  $fail/$total checks"
  echo
  echo "Common fixes:"
  echo "  401 invalid api key             key is wrong / expired / has stray whitespace — re-issue at https://app.directinference.com/api-keys"
  echo "  402                             balance exhausted or spend cap reached — top up at https://app.directinference.com/billing"
  echo "  model discovery empty           bad key or base URL — confirm baseURL is exactly $HOST/di/v1"
  echo "  no X-DI-Request-Type header     request landed on /v1/* or the previous provider instead of /di/v1/*"
  echo "  streaming fails but pings pass  reverse proxy (nginx / CDN / ALB) is buffering or stripping SSE"
  exit 1
fi

echo "PASSED  $pass/$total checks"
