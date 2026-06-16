# DirectInference Agent Skills

Skills that let coding agents integrate [DirectInference](https://directinference.com) — the endpoint that replaces per-vendor model APIs. Point your existing OpenAI, Anthropic, or Gemini SDK at one base URL with one key, keep your code and model ids exactly as they are, and every request is served by the right frontier capability automatically.

A skill is a folder with a `SKILL.md` an agent can read and execute — the portable [Agent Skills](https://agentskills.io) format used by Claude Code and other coding agents.

## Skills

| Skill | What it does |
| --- | --- |
| [`use-directinference`](skills/use-directinference/SKILL.md) | Swap an existing OpenAI, Anthropic, or Gemini integration to DirectInference (or wire up a fresh one): inventory the call sites, apply the base-URL-and-key change, leave model ids untouched, and prove the result end-to-end with the bundled `verify.sh`. |
| [`directinference-librechat`](skills/directinference-librechat/SKILL.md) | Add DirectInference to a [LibreChat](https://www.librechat.ai/) instance as a custom endpoint: write the `librechat.yaml` block, wire the `.env` var and Docker mount, and prove the live request sequence with the bundled `verify.sh`. |

## Install

**Claude Code — available in every project** (personal skills directory):

```bash
git clone https://github.com/Direct-Inference/skills.git
mkdir -p ~/.claude/skills
cp -R skills/skills/use-directinference ~/.claude/skills/
```

**Claude Code — one project** (committed, shared with collaborators): copy the folder into the repo instead:

```bash
cp -R skills/skills/use-directinference /path/to/your-project/.claude/skills/
```

**Other agent harnesses**: copy the same folder to the tool-neutral path `.agents/skills/use-directinference/` in your project.

**No install at all**: paste the raw `SKILL.md` URL into your agent and ask it to follow it:

```
https://raw.githubusercontent.com/Direct-Inference/skills/main/skills/use-directinference/SKILL.md
```

Replace `use-directinference` with `directinference-librechat` in any command above to install the LibreChat skill instead.

Once installed, just tell your agent what you want — "switch this app to DirectInference", or "add DirectInference to LibreChat" — and the matching skill triggers on its description. The only input either needs is a DirectInference API key (`llm_live_…`), issued on the [API Keys](https://app.directinference.com/api-keys) page.

## Verify a finished integration

```bash
DIRECTINFERENCE_API_KEY=llm_live_... bash skills/use-directinference/verify.sh
```

Five checks: key validity (no tokens spent), the OpenAI, Anthropic, and Gemini wire shapes, and SSE streaming — each asserting your model id is echoed back and the response carries the `X-DI-Request-Type` header that only DirectInference sets.

For a LibreChat integration, `directinference-librechat` ships its own smoke that replays LibreChat's request sequence — model discovery, streaming chat, the title-generation completion, the default parameter set, and the custom-header path:

```bash
DIRECTINFERENCE_API_KEY=llm_live_... bash skills/directinference-librechat/verify.sh
```

## Docs

- Documentation: https://docs.directinference.com
- Machine-readable index for agents: https://docs.directinference.com/llms.txt (expanded: https://directinference.com/llms-full.txt)
- Dashboard & API keys: https://app.directinference.com

## License

[MIT](LICENSE)
