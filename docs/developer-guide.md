# Developer guide — using the office model

**Audience:** anyone writing code against it. No infra knowledge needed.

You get an OpenAI-compatible endpoint. Almost any coding agent, editor plugin or
script that can point at a custom OpenAI base URL will work.

---

## What you need

| | |
|---|---|
| **Base URL** | `https://gateway.<TAILNET>.ts.net/v1` |
| **API key** | `sk-…` — from a gateway admin, one per person |
| **Models** | `coder`, and `coder-max` if you were granted it |
| **Requirement** | Tailscale running and logged in |

Ask your admin for the real `<TAILNET>` value. Off the tailnet, the gateway does
not exist — no VPN client, no certificate to install, no port to forward.

## Setup, once

1. Install Tailscale ([tailscale.com/download](https://tailscale.com/download))
   and log in with your **work identity** — the same one your admin invited.
2. If your machine needs approval, your admin approves it. Until then everything
   times out while looking connected.
3. Confirm you can reach the gateway:

```bash
curl -s https://gateway.<TAILNET>.ts.net/health/liveliness
```

4. Confirm your key works and see what you have access to:

```bash
curl -s https://gateway.<TAILNET>.ts.net/v1/models -H "Authorization: Bearer sk-..."
```

5. Put the key in your shell profile so no config file ever contains it:

```bash
echo 'export OFFICE_LLM_KEY=sk-...' >> ~/.zshrc
```

```bash
echo 'export OFFICE_LLM_BASE=https://gateway.<TAILNET>.ts.net/v1' >> ~/.zshrc
```

Every example below reads those two variables.

## Which model

| | `coder` | `coder-max` |
|---|---|---|
| Reasoning | off | on |
| Max output | 8k tokens | 32k tokens |
| Speed | fast | slow — visibly |
| Use for | day-to-day agentic work, edits, tests, refactors | architecture, hard debugging, tricky refactors |

Same weights, same machine, so switching is free and instant.

**Set `coder` as your editor default.** `coder-max` thinks before every reply,
including "rename this variable" — that's GPU time your teammates are queued
behind. Reach for it deliberately, on the hard one.

If `coder-max` is unavailable it degrades to `coder` rather than erroring, so a
reply that arrives suspiciously fast may not have used reasoning.

---

## Any OpenAI-compatible tool

Whatever the tool, you're filling in three fields:

```
base URL / API base / endpoint   https://gateway.<TAILNET>.ts.net/v1
API key                          sk-...
model                            coder
```

The provider type is **OpenAI** or **OpenAI-compatible** / **custom OpenAI** —
never "Ollama" or "local", even though it's your own hardware. It speaks the
OpenAI HTTP API and expects a bearer token.

Test any tool's config with the raw request first — it isolates your setup from
theirs:

```bash
curl -s "$OFFICE_LLM_BASE/chat/completions" -H "Authorization: Bearer $OFFICE_LLM_KEY" -H 'Content-Type: application/json' -d '{"model":"coder","messages":[{"role":"user","content":"reply with the single word: ok"}]}'
```

Streaming, tool/function calling and the standard `/chat/completions` and
`/v1/models` routes all work. Don't set `max_tokens` yourself — the gateway sets
the right cap per tier, and a value below the reasoning length makes `coder-max`
return **empty** responses.

---

## opencode

`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "office": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Office gateway",
      "options": {
        "baseURL": "https://gateway.<TAILNET>.ts.net/v1",
        "apiKey": "{env:OFFICE_LLM_KEY}"
      },
      "models": {
        "coder": {
          "name": "coder (fast)",
          "tool_call": true,
          "limit": { "context": 65536, "output": 8192 }
        },
        "coder-max": {
          "name": "coder-max (thinking)",
          "tool_call": true,
          "reasoning": true,
          "interleaved": { "field": "reasoning_content" },
          "limit": { "context": 65536, "output": 16384 }
        }
      }
    }
  },
  "model": "office/coder"
}
```

Without the `limit` block opencode shows "Context: 0" and cannot manage its
own context window; without `reasoning` + `interleaved` it hides `coder-max`'s
thinking and reports "No reasoning" — the capability flags for a custom
provider are declared here, not discovered. `coder-max` gets `output: 16384`
because the thinking pass alone can exceed 8k tokens on a hard task (measured).

opencode is the tool that will tell you the truth about tool calling — it surfaces
a malformed `tool_calls` response as a failure instead of quietly showing you
prose. Use it when something feels off.

## aider

```bash
export OPENAI_API_BASE="$OFFICE_LLM_BASE"
```

```bash
export OPENAI_API_KEY="$OFFICE_LLM_KEY"
```

```bash
aider --model openai/coder
```

Note the `openai/` prefix — that's aider's provider routing, not part of the model
name.

⚠️ aider edits via text diffs, not tool calls. That makes it robust, but it also
means it will **not** show you a tool-calling problem. If agents elsewhere are
behaving strangely and aider seems fine, believe the agents.

## Claude Code

Claude Code speaks the Anthropic Messages API; the gateway translates it.

```bash
export ANTHROPIC_BASE_URL=https://gateway.<TAILNET>.ts.net
```

```bash
export ANTHROPIC_AUTH_TOKEN="$OFFICE_LLM_KEY"
```

```bash
export ANTHROPIC_MODEL=coder
```

No `/v1` suffix here — Claude Code appends its own path.

⚠️ This is the one path in this document that has not been driven against a real
engine yet. The Anthropic-to-OpenAI translation is the part most likely to need
adjusting. Tell your admin what you see, good or bad.

## VS Code — built-in

VS Code's chat has a **Custom Endpoint** provider. No extension needed, and it
works **without a GitHub account and without a Copilot plan**.

Model picker → **Manage Language Models** → **Add Models** → **Custom Endpoint**.
It asks for the endpoint URL, the API key and the API type — pick **Chat
Completions**.

The stored config (`chatLanguageModels.json`) looks like this; edit it directly if
you prefer:

```json
[
  {
    "name": "Office gateway",
    "vendor": "customendpoint",
    "apiKey": "${input:officeLlmKey}",
    "apiType": "chat-completions",
    "models": [
      {
        "id": "coder",
        "name": "coder (fast)",
        "url": "https://gateway.<TAILNET>.ts.net/v1/chat/completions",
        "toolCalling": true,
        "vision": false,
        "maxInputTokens": 65536,
        "maxOutputTokens": 8192
      },
      {
        "id": "coder-max",
        "name": "coder-max (thinking)",
        "url": "https://gateway.<TAILNET>.ts.net/v1/chat/completions",
        "toolCalling": true,
        "vision": false,
        "maxInputTokens": 65536,
        "maxOutputTokens": 32768
      }
    ]
  }
]
```

Three things that will bite you:

- ⚠️ **`toolCalling` must be `true`** or the model is hidden from the picker in
  agent mode entirely — VS Code only offers tool-calling models to agents. It's a
  declaration, not a test, so if it's wrong you get silence rather than an error.
- Give the **full URL including `/chat/completions`**. VS Code appends a path
  based on `apiType` when you don't, which is one more thing to guess wrong.
- `maxInputTokens` is the engine's context window (65536). `maxOutputTokens`
  differs per alias — that's the whole difference between the two tiers.

**Not covered by this:** code completions, semantic search and anything using
embeddings still require a GitHub account. Doesn't matter here — neither alias is
a fill-in-the-middle model, so you would not want tab completion pointed at it
anyway.

## VS Code — extensions

**Continue** — `~/.continue/config.yaml`:

```yaml
name: office
version: 0.0.1
schema: v1
models:
  - name: coder
    provider: openai
    model: coder
    apiBase: https://gateway.<TAILNET>.ts.net/v1
    apiKey: sk-...
    roles: [chat, edit, apply]
  - name: coder-max
    provider: openai
    model: coder-max
    apiBase: https://gateway.<TAILNET>.ts.net/v1
    apiKey: sk-...
    roles: [chat]
```

`provider: openai` with an `apiBase` is what makes it use ours. Leave
**autocomplete unset** — neither alias is a fill-in-the-middle model, and pointing
tab-completion at a reasoning model burns GPU on every keystroke pause for bad
suggestions.

**Cline / Roo Code** — settings → API Provider: **OpenAI Compatible** → Base URL
`https://gateway.<TAILNET>.ts.net/v1`, your key, Model ID `coder`. Tick whatever
the version calls "supports tools / function calling".

Prefer the built-in Custom Endpoint above unless you already live in Continue or
Cline. One less moving part, and it's the one Microsoft maintains.

Don't use the built-in **Ollama** provider — it's deprecated, and it wouldn't work
here anyway: it speaks Ollama's native protocol, which the gateway does not serve.

## JetBrains (WebStorm, IntelliJ, PyCharm)

**AI Assistant** — supports OpenAI-compatible endpoints natively as of 2026.2, and
JetBrains' own documentation names LiteLLM as an example, so this is a supported
path rather than a workaround.

**Settings | Tools | AI Assistant | Providers & API keys** → Third-party AI
providers → select the provider, then:

| Field | Value |
|---|---|
| URL of the provider's API endpoint | `https://gateway.<TAILNET>.ts.net/v1` |
| API Key | your `sk-…` |
| Tool calling | **enable** |

**Test Connection**, then **Apply**.

- ⚠️ Enable **tool calling**. It's what allows the model to invoke tools
  configured through MCP; left off, the model works in chat and quietly can't do
  agentic work.
- Assign models per feature under **Models Assignment**. Leave **AI Completion**
  on JetBrains' own model — inline completion needs a fill-in-the-middle model and
  neither alias is one.
- The default context window for custom models is 64,000 tokens, which happens to
  match the engine's 65536. Nothing to change.
- Whether a JetBrains AI licence is still required when you supply your own
  endpoint isn't stated in their docs. Find out before assuming you can drop the
  subscription.

**Continue** — plugin marketplace; reads the same `~/.continue/config.yaml` as VS
Code, so one file covers both editors. Good if you want identical behaviour across
the two.

**ProxyAI** (formerly CodeGPT) — Settings → Providers → **Custom OpenAI**: base
URL `https://gateway.<TAILNET>.ts.net/v1`, your key, model `coder`.

## Scripts and CI

The official OpenAI SDKs work unchanged:

```python
from openai import OpenAI
import os

client = OpenAI(base_url=os.environ["OFFICE_LLM_BASE"], api_key=os.environ["OFFICE_LLM_KEY"])
r = client.chat.completions.create(model="coder", messages=[{"role": "user", "content": "hi"}])
print(r.choices[0].message.content)
```

CI runners are not on the tailnet, so this only works from a developer machine.
Putting a runner on the tailnet is an admin decision with real perimeter
implications — ask, don't improvise.

---

## Rules of use

**Keep your key to yourself.** It's issued per person and everything is attributed
to it. Sharing one makes revocation an all-or-nothing event and destroys the only
audit signal the system keeps.

**Internal source code: fine. Secrets and customer data: no.** Prompts travel
over the encrypted tailnet, but inference decrypts them in the rented machine's
RAM and VRAM, and that machine is operated by a datacenter company we have a
contract with rather than physical control over. Treat a prompt like a message to
a trusted contractor: your own code, yes; production credentials, customer PII,
signing keys, no. No firewall setting changes this — it's the accepted trade,
described in [design-notes.md](design-notes.md#accepted-risks).

**Nobody reads your prompts internally.** Content logging is off on both the
gateway and the engine. Admins see who called which model, when, and how many
tokens — never what you asked.

**The GPU is shared and it costs money by the hour.** It shuts down after 45
minutes idle and unconditionally at 22:00. That's normal, not an outage.

---

## When it breaks

| What you see | What it means | What to do |
|---|---|---|
| `503` "model backend is currently offline" | node is stopped — often just idle shutdown | retry in a few minutes; if it persists, tell an admin |
| Connection timeout | not on the tailnet, or device not approved | check the Tailscale app; then ask an admin |
| `401` | key wrong, expired or revoked | ask an admin |
| `400 model not found` | your key doesn't include that alias | ask an admin for `coder-max` |
| Empty reply, `finish_reason: length` | something capped `max_tokens` below the reasoning length | remove your own `max_tokens` |
| Very slow first reply | cold start, or you're on `coder-max` | check which model you're on |
| Agent gets prose where it wants a tool call | engine-side parser problem | tell an admin — reproduce in opencode, not aider |
| TLS / certificate error | gateway-side; not your machine | tell an admin |

**Starting the node** is an operator action (`gpu-up.sh`, operator
credentials). Some teams give developers those credentials; if yours does, first
run of the day takes minutes while weights load into VRAM. If not, a 503 is a
"wait or ask" situation, never a bug to file.

Reporting a problem usefully: which alias, which tool, the status code, and
whether `curl` (the one-liner above) also fails. That last one splits "the gateway
is broken" from "my editor config is broken" in one step, and they get fixed by
different people.
