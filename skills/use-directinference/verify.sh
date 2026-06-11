#!/usr/bin/env bash
# verify.sh — post-swap smoke for the DirectInference drop-in endpoint.
#
# Runs five quick checks:
#   0. GET /di/v1/models — proves the host and API key before spending tokens.
#   1. OpenAI-shape ping — response echoes the model id sent.
#   2. Anthropic-shape ping — same echo assertion.
#   3. OpenAI streaming ping — confirms SSE survives the round trip
#      (catches reverse proxies that buffer or strip stream responses).
#   4. Gemini-shape ping — generateContent echoes the gemini-* id back as
#      modelVersion.
#
# Checks 1–4 also assert the response carries the X-DI-Request-Type header.
# Only DirectInference sets that header, so its presence proves the request
# did not quietly land on the original provider — a model echo alone can
# false-pass for ids the original provider also serves.
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
# 0. Auth + model list — GET /di/v1/models
#
# Fails fast on a bad host or key without spending any tokens.
# ---------------------------------------------------------------------------
code=$(curl -sS -o "$work/models.json" -w '%{http_code}' \
  "$HOST/di/v1/models" \
  -H "Authorization: Bearer $KEY" || echo "000")

if [[ "$code" == "200" ]] && grep -q '"data"' "$work/models.json"; then
  ok "auth + model list — GET /di/v1/models"
else
  bad "auth + model list — HTTP $code (expected 200 from GET /di/v1/models)"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/models.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 1. OpenAI shape — POST /di/v1/chat/completions
# ---------------------------------------------------------------------------
openai_model="gpt-5.5-mini"
openai_body=$(cat <<JSON
{"model":"$openai_model","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -D "$work/openai.h" -o "$work/openai.json" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d "$openai_body" || echo "000")

rt=$(request_type "$work/openai.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"model\":\"$openai_model\"" "$work/openai.json"; then
  ok "openai shape — model echoed ($openai_model), request type: $rt"
else
  bad "openai shape — HTTP $code (expected 200 with model:\"$openai_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/openai.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 2. Anthropic shape — POST /di/v1/messages
# ---------------------------------------------------------------------------
anthropic_model="claude-sonnet-4-6"
anthropic_body=$(cat <<JSON
{"model":"$anthropic_model","max_tokens":32,"messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -D "$work/anthropic.h" -o "$work/anthropic.json" -w '%{http_code}' \
  "$HOST/di/v1/messages" \
  -H "x-api-key: $KEY" \
  -H 'anthropic-version: 2023-06-01' \
  -H 'Content-Type: application/json' \
  -d "$anthropic_body" || echo "000")

rt=$(request_type "$work/anthropic.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"model\":\"$anthropic_model\"" "$work/anthropic.json"; then
  ok "anthropic shape — model echoed ($anthropic_model), request type: $rt"
else
  bad "anthropic shape — HTTP $code (expected 200 with model:\"$anthropic_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/anthropic.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 3. Streaming — POST /di/v1/chat/completions with stream:true
#
# Confirms the SSE transport survives end-to-end. Catches reverse proxies
# that buffer or strip streaming responses — a common production-only bug.
# ---------------------------------------------------------------------------
stream_model="gpt-5.5-mini"
stream_body=$(cat <<JSON
{"model":"$stream_model","stream":true,"max_tokens":16,"messages":[{"role":"user","content":"Reply with exactly PONG."}]}
JSON
)

code=$(curl -sS -N -D "$work/stream.h" -o "$work/stream.sse" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -H 'Accept: text/event-stream' \
  -d "$stream_body" || echo "000")

rt=$(request_type "$work/stream.h")
if [[ "$code" == "200" && -n "$rt" ]] \
   && grep -q '^data: {' "$work/stream.sse" \
   && grep -q '^data: \[DONE\]' "$work/stream.sse"; then
  ok "streaming — OpenAI SSE completed, request type: $rt"
else
  bad "streaming — HTTP $code (expected 200 with data: chunks ending in data: [DONE] and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/stream.sse" >&2 || true
fi

# ---------------------------------------------------------------------------
# 4. Gemini shape — POST /di/v1beta/models/{model}:generateContent
#
# The Google GenAI SDKs append /v1beta/models/{model}:generateContent to the
# base URL and send the key as x-goog-api-key. The response echoes the
# gemini-* id back as modelVersion (zero-knowledge: the backend stays hidden).
# ---------------------------------------------------------------------------
gemini_model="gemini-2.5-flash"
gemini_body='{"contents":[{"role":"user","parts":[{"text":"Reply with exactly PONG."}]}],"generationConfig":{"maxOutputTokens":32}}'

code=$(curl -sS -D "$work/gemini.h" -o "$work/gemini.json" -w '%{http_code}' \
  "$HOST/di/v1beta/models/$gemini_model:generateContent" \
  -H "x-goog-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d "$gemini_body" || echo "000")

rt=$(request_type "$work/gemini.h")
if [[ "$code" == "200" && -n "$rt" ]] && grep -q "\"modelVersion\":\"$gemini_model\"" "$work/gemini.json"; then
  ok "gemini shape — model echoed ($gemini_model), request type: $rt"
else
  bad "gemini shape — HTTP $code (expected 200 with modelVersion:\"$gemini_model\" and an X-DI-Request-Type header; got type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/gemini.json" >&2 || true
fi

echo
total=$((pass + fail))
if [[ "$fail" -gt 0 ]]; then
  echo "FAILED  $fail/$total checks"
  echo
  echo "Common fixes:"
  echo "  401 invalid api key             key is wrong / expired / has stray whitespace — re-issue at https://app.directinference.com/api-keys"
  echo "  402                             balance exhausted or spend cap reached — top up at https://app.directinference.com/billing"
  echo "  404 on Anthropic shape          base URL is the host only ($HOST); SDK appends /v1/messages"
  echo "  no X-DI-Request-Type header     request landed on /v1/* or on the original provider instead of /di/v1/*"
  echo "  streaming fails but pings pass  reverse proxy (nginx / CDN / ALB) is buffering or stripping SSE"
  exit 1
fi

echo "PASSED  $pass/$total checks"
