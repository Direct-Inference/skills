#!/usr/bin/env bash
# verify.sh — post-swap smoke for the DirectInference drop-in endpoint.
#
# Runs eight quick checks:
#   0. GET /di/v1/models — proves the host and API key before spending tokens.
#   1. OpenAI-shape ping — response echoes the model id sent.
#   2. Anthropic-shape ping — same echo assertion.
#   3. OpenAI streaming ping — confirms SSE survives the round trip
#      (catches reverse proxies that buffer or strip stream responses).
#   4. Gemini-shape ping — generateContent echoes the gemini-* id back as
#      modelVersion.
#   5. OpenAI forced tool call — declares one function tool, forces it, and
#      asserts the returned arguments are clean, parseable JSON.
#   6. Gemini forced functionCall — functionDeclarations + mode ANY; asserts
#      a functionCall part whose args are a clean JSON object with no `_raw`
#      fallback wrapper (an `_raw` key marks an unusable tool call).
#   7. Rejection quality — a provider server-side tool (googleSearch) must be
#      rejected with a descriptive 400, not accepted or mangled.
#
# Checks 1–6 also assert the response carries the X-DI-Request-Type header.
# Only DirectInference sets that header, so its presence proves the request
# did not quietly land on the original provider — a model echo alone can
# false-pass for ids the original provider also serves.
#
# Checks 5–6 validate tool-call arguments with python3 (or node) when
# available; with neither on PATH they fall back to a cruder grep heuristic.
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

# tool_args_verdict <body-file> <openai|gemini> <expected-tool-name>
#
# Prints "CLEAN" when the response carries a tool call for the expected tool
# whose arguments are a parseable JSON object with no `_raw` fallback wrapper;
# otherwise prints the reason. Uses python3 or node when available, else a
# grep heuristic.
tool_args_verdict() {
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, mode, want = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    body = json.load(open(path))
except Exception as e:
    print(f"response is not JSON: {e}")
    sys.exit(0)
try:
    if mode == "openai":
        calls = (body["choices"][0]["message"].get("tool_calls")) or []
        if not calls:
            print("no tool_calls in response"); sys.exit(0)
        fn = calls[0].get("function") or {}
        name = fn.get("name")
        try:
            args = json.loads(fn.get("arguments") or "{}")
        except Exception:
            print("arguments are not valid JSON — unusable tool call"); sys.exit(0)
    else:
        parts = body["candidates"][0]["content"]["parts"]
        fcs = [p["functionCall"] for p in parts if isinstance(p, dict) and "functionCall" in p]
        if not fcs:
            print("no functionCall part in response"); sys.exit(0)
        name = fcs[0].get("name")
        args = fcs[0].get("args")
        if args is None:
            args = {}
except Exception as e:
    print(f"unexpected response shape: {e}"); sys.exit(0)
if name != want:
    print(f"tool name {name!r} != expected {want!r}"); sys.exit(0)
if not isinstance(args, dict):
    print("arguments are not a JSON object"); sys.exit(0)
if "_raw" in args:
    print("arguments came back unparsed (_raw) — unusable tool call"); sys.exit(0)
print("CLEAN")
PY
  elif command -v node >/dev/null 2>&1; then
    node -e '
const fs = require("fs");
const [path, mode, want] = process.argv.slice(1);
let body;
try { body = JSON.parse(fs.readFileSync(path, "utf8")); }
catch (e) { console.log("response is not JSON: " + e.message); process.exit(0); }
let name, args;
try {
  if (mode === "openai") {
    const calls = (body.choices[0].message || {}).tool_calls || [];
    if (!calls.length) { console.log("no tool_calls in response"); process.exit(0); }
    name = (calls[0].function || {}).name;
    try { args = JSON.parse((calls[0].function || {}).arguments || "{}"); }
    catch { console.log("arguments are not valid JSON — unusable tool call"); process.exit(0); }
  } else {
    const parts = body.candidates[0].content.parts || [];
    const fc = parts.find((p) => p && p.functionCall);
    if (!fc) { console.log("no functionCall part in response"); process.exit(0); }
    name = fc.functionCall.name;
    args = fc.functionCall.args || {};
  }
} catch (e) { console.log("unexpected response shape: " + e.message); process.exit(0); }
if (name !== want) { console.log(`tool name ${name} != expected ${want}`); process.exit(0); }
if (typeof args !== "object" || Array.isArray(args)) { console.log("arguments are not a JSON object"); process.exit(0); }
if (Object.prototype.hasOwnProperty.call(args, "_raw")) { console.log("arguments came back unparsed (_raw) — unusable tool call"); process.exit(0); }
console.log("CLEAN");
' "$1" "$2" "$3"
  else
    if grep -q '_raw' "$1"; then
      echo "arguments came back unparsed (_raw) — unusable tool call"
    elif grep -q "\"$3\"" "$1" && grep -qE '"(tool_calls|functionCall)"' "$1"; then
      echo "CLEAN"
    else
      echo "tool call missing (install python3 or node for precise validation)"
    fi
  fi
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

# ---------------------------------------------------------------------------
# 5. OpenAI forced tool call — POST /di/v1/chat/completions
#
# Declares one function tool and forces it via tool_choice. The response must
# contain a tool call for that tool whose arguments are clean, parseable JSON.
# Catches translation failures that a plain ping can never see.
# ---------------------------------------------------------------------------
tool_model="gpt-5.5-mini"
tool_openai_body=$(cat <<JSON
{"model":"$tool_model","max_tokens":1024,
 "messages":[{"role":"user","content":"What is the weather in Paris right now? Use the get_weather tool."}],
 "tools":[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
 "tool_choice":{"type":"function","function":{"name":"get_weather"}}}
JSON
)

code=$(curl -sS -D "$work/tool_openai.h" -o "$work/tool_openai.json" -w '%{http_code}' \
  "$HOST/di/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d "$tool_openai_body" || echo "000")

rt=$(request_type "$work/tool_openai.h")
verdict=$(tool_args_verdict "$work/tool_openai.json" openai get_weather)
if [[ "$code" == "200" && -n "$rt" && "$verdict" == "CLEAN" ]]; then
  ok "openai forced tool — get_weather called with clean args, request type: $rt"
else
  bad "openai forced tool — HTTP $code, ${verdict:-no verdict} (expected 200 with a clean get_weather tool call; type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/tool_openai.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 6. Gemini forced functionCall — :generateContent with toolConfig mode ANY
#
# The structured-output shape most agent frameworks compile to. Asserts a
# functionCall part whose args are a clean JSON object — and specifically that
# no `_raw` fallback wrapper appears (an `_raw` key means the arguments came
# back unusable and framework validation will fail).
# ---------------------------------------------------------------------------
tool_gemini_model="gemini-2.0-flash"
tool_gemini_body=$(cat <<'JSON'
{"contents":[{"role":"user","parts":[{"text":"What is the weather in Paris right now? Use the get_weather tool."}]}],
 "tools":[{"functionDeclarations":[{"name":"get_weather","description":"Get current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]}],
 "toolConfig":{"functionCallingConfig":{"mode":"ANY"}},
 "generationConfig":{"maxOutputTokens":1024}}
JSON
)

code=$(curl -sS -D "$work/tool_gemini.h" -o "$work/tool_gemini.json" -w '%{http_code}' \
  "$HOST/di/v1beta/models/$tool_gemini_model:generateContent" \
  -H "x-goog-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d "$tool_gemini_body" || echo "000")

rt=$(request_type "$work/tool_gemini.h")
verdict=$(tool_args_verdict "$work/tool_gemini.json" gemini get_weather)
if [[ "$code" == "200" && -n "$rt" && "$verdict" == "CLEAN" ]]; then
  ok "gemini forced tool — functionCall returned with clean args, request type: $rt"
else
  bad "gemini forced tool — HTTP $code, ${verdict:-no verdict} (expected 200 with a clean get_weather functionCall; type: '${rt:-none}')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/tool_gemini.json" >&2 || true
fi

# ---------------------------------------------------------------------------
# 7. Rejection quality — server-side tools must fail loud at request time
#
# googleSearch is a provider server-side tool DirectInference does not serve.
# The correct behavior is a deterministic 400 that names the offending element
# — not a 200 with degraded output, and not an opaque error.
# ---------------------------------------------------------------------------
code=$(curl -sS -o "$work/reject.json" -w '%{http_code}' \
  "$HOST/di/v1beta/models/gemini-2.5-flash:generateContent" \
  -H "x-goog-api-key: $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"contents":[{"role":"user","parts":[{"text":"hi"}]}],"tools":[{"googleSearch":{}}]}' || echo "000")

if [[ "$code" == "400" ]] && grep -q 'googleSearch' "$work/reject.json" && grep -q 'not supported' "$work/reject.json"; then
  ok "rejection quality — googleSearch rejected with a descriptive 400"
else
  bad "rejection quality — HTTP $code (expected 400 naming googleSearch with 'not supported')"
  echo "    response head:" >&2
  sed -n '1,5p' "$work/reject.json" >&2 || true
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
  echo "  forced tool checks fail         the endpoint returned an unusable tool call (e.g. _raw arguments) — re-run to confirm, and report it to DirectInference; tool-calling traffic is affected"
  echo "  rejection check got 200         a server-side tool was accepted unexpectedly — keep that call site on the original provider and report it"
  exit 1
fi

echo "PASSED  $pass/$total checks"
