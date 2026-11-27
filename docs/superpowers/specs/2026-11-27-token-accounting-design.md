# Design: Per-request token accounting at the Kong gateway

- **Date:** 2026-11-27
- **Status:** Draft — awaiting user approval + 3 decisions below
- **Relation:** Separate feature from the A+C Requests live/detail work
  (branch `feat/requests-live-detail`). This is its own, later version.

## Intent / why

Operators cannot see which **consumer / source IP** drove token load. vLLM logs
token counts but not caller identity; Kong logs identity (consumer, IP) but not
tokens. This feature **joins the two at the gateway** so the portal shows, per
request, how many tokens each consumer/IP pushed — and optionally totals per
consumer/model over time.

The "8k–9k token post lên" seen in vLLM logs = `usage.prompt_tokens` (input);
output = `usage.completion_tokens`. Both live in the vLLM OpenAI-compatible
**response body** (`usage` object), which Kong does not read today (it proxies
raw to vLLM and logs only bytes/consumer/IP/latency/status).

## Goals

- Record prompt / completion / total tokens **per proxied request** into Kong's
  access log, next to the consumer + IP it already logs (no correlation id
  needed — same log line).
- Surface in the portal: a **Tokens** column in Requests + prompt/completion/
  total in the detail panel; token columns in the Requests CSV.
- (Decision 1) Optionally aggregate tokens per consumer/model in the Usage tab.

## Non-goals / anti-goals

- Not replacing vLLM's own metrics/logging.
- Not adopting Kong `ai-proxy` / AI-Gateway rearchitecture (keep raw proxy to
  vLLM). `ai-proxy` gives native token analytics but stands between client and
  model and transforms requests — out of scope here.
- Not backfilling historical requests (only from deploy forward).
- **Anti-goal:** must NOT degrade streaming latency/behaviour (Claude Code long
  streams). A version that reports tokens but delays or breaks streams is a
  failure even if the numbers are correct.

## Approach (primary)

A serverless **`post-function`** plugin (bundled in Kong OSS — inline Lua, no
external deps, air-gap safe), scoped to the LLM routes/services (Decision 3). It:

1. In `body_filter`, appends each response chunk to a small per-request buffer
   (`kong.ctx.plugin`), scanning for the `usage` object; at end-of-stream it
   parses `prompt_tokens`, `completion_tokens`, `total_tokens`.
2. Writes them with `kong.log.set_serialize_value("tokens_total", n)` (+ prompt
   / completion) so the **file-log** plugin records them in each access-log
   line. Consumer + IP are already on that line → attribution is automatic.

**Why not `enable_buffering`:** buffering the whole response breaks SSE
streaming. The chunk-scan in `body_filter` lets chunks flow to the client
untouched while we observe them.

### Token sources

- **Non-streaming** (`"stream": false`): `usage` is a field in the single JSON
  response. Reliable, exact.
- **Streaming (SSE)**: vLLM emits a final `data: {...,"usage":{...}}` chunk
  **only if** the request included `stream_options: {"include_usage": true}`
  (Decision 2).

## Key risk — streaming (MUST validate with a throwaway spike before build)

The one assumption that could fail: extracting `usage` from the live SSE stream
without buffering, cleanly, across vLLM versions. **Before committing the full
build**, run a spike on the dev stack: one non-stream call and one stream call
with `include_usage`; confirm the plugin reads tokens AND the stream reaching
the client is byte-identical / not delayed. If the chunk-scan proves fragile,
fallback = buffer **only** non-stream responses (detected via the request
`stream` flag in `access`), and accept "—" for streams.

## Decisions for the user (change what gets built)

1. **Usage-tab aggregation** — include now (tokens per consumer/model totals) or
   Requests-tab only for v1? *(Rec: Requests-tab + detail first; Usage
   aggregation as a fast follow.)*
2. **Streaming tokens** — Kong **auto-injects** `stream_options.include_usage=
   true` on `stream:true` chat requests (via request-transformer/pre-function)
   so EVERY stream reports tokens — vs **passive** (tokens only when the client
   already opted in; other streams show "—"). Auto-inject gives full coverage
   but mutates the client request (the extra end chunk is standard OpenAI, but a
   strict client could notice). *(Rec: config toggle, default **passive**; turn
   on auto-inject if full coverage is wanted.)*
3. **Plugin scope** — global vs only the LLM service/routes (avoids running the
   body-scan on non-LLM traffic). *(Rec: scope to the LLM services/routes.)*

## Portal changes (frontend, `portal.html`)

- Requests table: add **Tokens** column (total; "—" when unknown). Parse the new
  log fields in `loadRequests`; show prompt/completion/total in the detail panel.
- Requests CSV export: add token columns.
- (Decision 1) Usage tab: sum tokens per consumer/model.

## Constraints

- **Air-gap:** inline Lua only, no luarocks.
- **Memory:** keep a bounded buffer; non-stream needs the full body to reach
  `usage` (tens of KB typical) — guard/cap very large bodies.
- **Perf:** one extra Lua `body_filter` pass per LLM request; measure in spike.
- DB stays UTC; VN-time work unaffected (tokens are counts).

## Rollout

- Enable the plugin in `pca-deploy.sh` (like file-log) so PCA gets it on upgrade;
  document in `PCA-UPGRADE-GUIDE.md`.
- Its own version (e.g. 1.7.15), separate from A+C.

## Left to the builder

Exact Lua for chunk-scan + JSON extraction; log field names; column placement /
number format; CSV header; Usage aggregation query shape.
