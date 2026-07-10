---
name: directinference-librechat
description: Add DirectInference to a LibreChat instance as a custom endpoint. Use whenever someone wants DirectInference available in LibreChat — e.g. "add DirectInference to LibreChat", "set up DirectInference in my librechat.yaml", "point LibreChat at DirectInference", or "wire DirectInference into our LibreChat instance". Edits librechat.yaml (and the Docker mount / .env), then verifies. Only input required is a DirectInference API key (an `llm_live_*` credential).
---

# directinference-librechat

LibreChat exposes DirectInference through its **custom endpoints** mechanism. Custom endpoints are OpenAI-shaped, so the whole integration is one block in `librechat.yaml`:

1. Base URL → `https://api.directinference.com/di/v1` (the OpenAI-compatible DI surface; LibreChat appends `/chat/completions` and `/models`).
2. Auth → one `llm_live_*` key, referenced from the environment so it never lands in the config file.
3. Models → `di-fusion`, `di-saver`, `di-max` (the whole catalog: one model, plus the same model with effort pinned low/high). LibreChat fetches them from `/models` when `models.fetch: true`.

Everything LibreChat needs from a chat endpoint is served: streaming, client-defined function tools, vision (image input), document input, prompt caching, and the `titleConvo` title-generation completion. **Treat DirectInference as a black box** — any model id is accepted and echoed back, request handling is automatic, and the only classification signal you may surface is the request type (the `X-DI-Request-Type` response header). Never name or guess the model behind a response.

The not-chat features (embeddings for RAG/file search, image generation, audio) are not served — leave LibreChat's `fileConfig`/RAG embeddings pointed at a dedicated embeddings provider.

Full reference: `https://docs.directinference.com/librechat/`. Machine-readable index: `https://docs.directinference.com/llms.txt`.

## What you need from the user

| Input | Required | Default |
|---|---|---|
| DirectInference API key (`llm_live_*`) — issued at `https://app.directinference.com/api-keys` | yes | — |
| Where the LibreChat config lives (`librechat.yaml`, or `CONFIG_PATH`) | no | `librechat.yaml` in the LibreChat project root |
| How LibreChat runs (Docker vs from source) | no | infer from the repo (a `docker-compose.yml` ⇒ Docker) |
| Env var name for the key | no | `DIRECTINFERENCE_API_KEY` |
| Multi-tenant? (each user brings their own key) | no | no — one shared key from the env |

If the key isn't in the conversation or the project env, ask for it before editing. No account yet? Signup is free at `https://app.directinference.com` (pay-as-you-go). **Never write the key into a tracked file** — it goes in `.env`, referenced with `${...}`.

## Procedure

### Step 1 — Locate the config (read-only)

Find LibreChat's config and how it runs. From the LibreChat project root:

```bash
ls librechat.yaml docker-compose.yml docker-compose.override.yml .env .env.example 2>/dev/null
grep -nE 'CONFIG_PATH' .env 2>/dev/null
# If librechat.yaml already has custom endpoints, you must APPEND, not clobber:
grep -nA3 'endpoints:' librechat.yaml 2>/dev/null
```

Note: whether `librechat.yaml` exists (or `CONFIG_PATH` points elsewhere); whether there's already an `endpoints.custom` list; and whether deployment is Docker (a `docker-compose.yml` is present) or from source.

### Step 2 — Add the custom endpoint

If `librechat.yaml` doesn't exist, create it with the minimum header plus the endpoint. If it exists, **add the entry to the existing `endpoints.custom` list** — do not overwrite other endpoints.

```yaml
# librechat.yaml — create, or merge the endpoints.custom entry into an existing file
version: 1.3.13
cache: true

endpoints:
  custom:
    - name: "DirectInference"
      apiKey: "${DIRECTINFERENCE_API_KEY}"
      baseURL: "https://api.directinference.com/di/v1"
      models:
        default: ["di-fusion", "di-saver", "di-max"]
        fetch: true
      titleConvo: true
      titleModel: "di-saver"
      modelDisplayLabel: "DirectInference"
```

Field notes:

- `apiKey` is interpolated from the environment at runtime — keep it as `"${DIRECTINFERENCE_API_KEY}"`, never the literal key. For a shared instance where each user supplies their own key, set `apiKey: "user_provided"` instead (LibreChat prompts and stores per-user).
- `baseURL` must be exactly `https://api.directinference.com/di/v1`. LibreChat appends the path.
- `models.default` is the whole catalog; `fetch: true` populates the live list from `/models`.
- `titleModel: "di-saver"` keeps auto-titling cheap (use `"current_model"` to title with whatever the chat used).
- **Do not add `dropParams`.** It exists for endpoints that reject LibreChat's default params; DirectInference accepts the standard OpenAI params and strips anything unrecognised, so it's unnecessary.
- Optional headers — offer, don't force. Add a `headers:` block for per-app usage attribution and an effort bias:

  ```yaml
      headers:
        X-Title: "LibreChat"
        X-DI-Effort: "medium"   # fast|minimal|low|medium|high|xhigh|max; omit for auto
  ```

### Step 3 — Wire the key and the mount

Add the key to `.env` (and to `.env.example` as an empty placeholder if one exists):

```bash
# .env (in the LibreChat project root) — real value, never committed
DIRECTINFERENCE_API_KEY=llm_live_...
```

```bash
# .env.example — placeholder only
DIRECTINFERENCE_API_KEY=
```

**Docker:** LibreChat merges `docker-compose.override.yml` over its shipped compose. Mount `librechat.yaml` into the `api` service (add the volume if the override already exists):

```yaml
# docker-compose.override.yml
services:
  api:
    volumes:
      - type: bind
        source: ./librechat.yaml
        target: /app/librechat.yaml
```

**From source:** `librechat.yaml` in the project root is auto-detected; otherwise set `CONFIG_PATH=/path/to/librechat.yaml` in `.env`.

### Step 4 — Restart

- Docker: `docker compose down && docker compose up -d`
- Source: restart the backend (e.g. `npm run backend`).

Config and env are only re-read on restart — a change has no effect until then.

### Step 5 — Verify

Use the bundled `verify.sh`. It replays LibreChat's exact request sequence against the DI endpoint — model discovery, a streaming chat turn, the `titleConvo` completion, LibreChat's default parameter set, and the optional custom-header path — and asserts each response echoes the model id and carries the `X-DI-Request-Type` header (the definitive proof the request reached DirectInference; a model echo alone can false-pass).

```bash
DIRECTINFERENCE_API_KEY=llm_live_... bash skills/directinference-librechat/verify.sh
```

Adjust the path to wherever the skill lives. Successful output:

```
base_url : https://api.directinference.com/di/v1

PASS  model discovery — GET /di/v1/models lists di-fusion, di-saver, di-max
PASS  streaming chat — OpenAI SSE completed, model echoed (di-fusion), request type: flash
PASS  title generation — non-stream completion, model echoed (di-saver), request type: flash
PASS  default param set — temperature/top_p/penalties/stop/user accepted, request type: flash
PASS  custom headers — X-Title + X-DI-Effort accepted, request type: flash

PASSED  5/5 checks
```

(The request-type values vary with the prompt — any value passes; the assertion is presence.) Then confirm inside LibreChat: pick **DirectInference** in the endpoint selector, send a message, and check it appears in [Traces](https://app.directinference.com/traces).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Endpoint missing from the selector | `librechat.yaml` not loaded | Docker: check the `docker-compose.override.yml` bind mount and re-run `docker compose up -d`. Source: check `CONFIG_PATH` and restart. |
| Model dropdown empty | `models.fetch` couldn't reach `/models` (bad key or base URL) | Run `verify.sh`; the `default` list still backs the selector meanwhile. |
| `401` invalid api key | Wrong key, or stray whitespace/quotes in `.env` | Re-issue at `https://app.directinference.com/api-keys`; `printenv DIRECTINFERENCE_API_KEY \| cat -A`. |
| `402` | Balance exhausted or a spend cap reached — deliberate, won't clear on retry | Top up / raise the cap at `https://app.directinference.com/billing`. |
| `404` on the first message | Base URL is one segment off | Must be exactly `https://api.directinference.com/di/v1`. |
| Vendor-branded "incorrect API key" in the built-in test | Base URL not applied yet — tested against a default vendor | Save the config, restart, re-test; `verify.sh` is ground truth the key is fine. |
| Replies arrive, nothing in Traces | Still on a previous endpoint, or `user_provided` key unset for that user | Check a reply for `X-DI-Request-Type`; if absent, re-save and restart. |

## Notes for the agent

- Append to `endpoints.custom`; never clobber endpoints the user already configured.
- The key goes in `.env` (referenced with `${...}`) or is `user_provided` — never literal in `librechat.yaml`. If you find a literal key in a tracked file, flag it and relocate it.
- Don't add `dropParams` for DirectInference — it isn't needed and adds noise.
- Rollback is trivial: remove the endpoint block and the env var.
- Embeddings (RAG / file search), image generation, and audio are not served — leave those LibreChat features on their existing providers; only the chat endpoint moves.
- The only classification fact you may surface is the request type (`X-DI-Request-Type`: `flash`, `pro`, `reason`, `code`, `json`, `long`, `vision`, `document`). Never name or guess the model/provider behind a response.
