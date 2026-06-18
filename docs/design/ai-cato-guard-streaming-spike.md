# Spike: Streaming WS-Bridged Guardrail in Kong (`ai-cato-guard`)

**Status:** Proposed — throwaway spike, not production code
**Branch:** `claude/determined-brahmagupta-ch4ywa`
**Owner:** AI gateway / guardrails
**Time-box:** ~1–2 days
**Decision gate:** Does step 1 (incremental client output from the `access`
phase) work in this Kong build? If yes → proceed to the full `ai-cato-guard`
plugin plan with the takeover bridge. If no → the streaming guardrail must be a
sidecar service, and we re-open that decision with stakeholders.

---

## 1. Why this spike exists

We want a Kong plugin that applies a Cato guardrail to **streaming** LLM
responses with the following semantics (the hard requirement):

> Receive chunks from the upstream LLM, forward them over a WebSocket to Cato,
> and **withhold them from the waiting client** while that happens. Only once
> Cato returns a verdict do we forward chunks to the client — emitting exactly
> the chunks Cato clears, **possibly in a modified (redacted/rewritten) form**,
> and never emitting a chunk Cato decides to block.

This is byte-for-byte the contract of litellm's
`async_post_call_streaming_iterator_hook` (`verified_chunk` → emit
possibly-modified; `blocking_message` → stop, emit error, end; `done` → end),
expressed in Lua.

### Why the obvious approaches don't work

- **Kong AI filter pipeline / `body_filter`** — `body_filter` runs after the
  content phase and **cannot use cosockets**, so it cannot call Cato over the
  network. Confirmed: `git grep` for `ngx.flush|ngx.eof|body_reader|websocket`
  across `kong/plugins/**` and `kong/llm/**` returns nothing — no plugin does
  network I/O or streamed output there.
- **grpc-gateway pattern** — it transcodes response chunks in `body_filter`,
  but with **pure CPU work (protobuf↔JSON), zero network calls**. Not a model
  for consulting an external service mid-stream.
- **Go / Python / JS PDK plugins** — these run as **external plugin servers**
  (separate processes; `kong/runloop/plugin_servers/`) talking to Kong over a
  unix socket via MessagePack/protobuf RPC. The RPC surface
  (`kong/include/kong/pluginsocket.proto`) is a fixed request/response method
  set — `git grep` of the proto for `flush|eof|body_reader|websocket|socket|stream|ngx.print`
  returns **zero hits**. An out-of-process plugin has no nginx connection, no
  cosocket, no streamed output, and pays per-call IPC latency on every token.
  **The streaming bridge is therefore only expressible in in-process Lua.**

### The viable mechanism: access-phase takeover bridge

The plugin stops being a filter on Kong's proxy path and becomes its **own
streaming proxy**, running entirely in the `access` phase (the earliest phase
where cosockets are legal). It:

1. opens the upstream LLM stream itself (`httpc:connect` + `res.body_reader`),
2. opens an outbound WS to Cato (`resty.websocket.client`),
3. bridges them with a **hold-back buffer**, and
4. streams cleared/modified chunks to the client via `ngx.print` + `ngx.flush`,
   finishing with `ngx.eof` / `ngx.exit(ngx.HTTP_OK)` — bypassing `proxy_pass`.

The read rate (LLM→WS) and the emit rate (WS-verdict→client) are **decoupled**:
nothing reaches the client as a side effect of a read. Every `ngx.print` is a
deliberate decision driven by a Cato verdict.

---

## 2. Grounding facts (verified in this repo)

| Capability | Evidence |
|---|---|
| Streaming HTTP read | Kong uses `httpc:connect()` + `httpc:request{}` (exposes `res.body_reader`) in `kong/llm/drivers/shared.lua:923`; `lua-resty-http == 0.17.2` pinned in `kong-latest.rockspec` |
| Outbound WS client | `resty.websocket.client` used by `kong/clustering/utils.lua` (TLS + proxy support) |
| **Duplex WS on one conn** | `kong/clustering/data_plane.lua` runs independent read/write light threads on a single `resty.websocket.client`: `ngx.thread.spawn` (`:333`, `:356`), `ngx.semaphore` (`:5`, `:258`, `:390`), `ngx.thread.wait` (`:410`) |
| Incremental client output from `access` | **UNPROVEN — this is what the spike validates.** OpenResty permits `ngx.print`/`ngx.flush` in `access_by_lua`, but no Kong plugin does it; Kong's own `kong.response.exit()` buffers and prints once |

---

## 3. Spike deliverables

A throwaway plugin plus mocks, exercised with `curl -N` against a local Kong:

```
spike/
  kong/plugins/spike-stream-bridge/
    handler.lua          -- access-phase takeover bridge
    schema.lua           -- minimal: upstream_url, cato_ws_url, fail_open
  mocks/
    sse_upstream.lua     -- mock LLM: emits N SSE chunks with delays
    cato_ws_echo.lua     -- mock Cato WS: DECOUPLED verdicts (not 1:1 echo)
  run/
    kong.conf            -- loads spike-stream-bridge as a custom plugin
    test.sh              -- curl -N driver + assertions
  NOTES.md               -- findings, latency numbers, go/no-go call
```

Everything is hardcoded. Mocks only. No real Cato, no auth, no provider
normalization.

---

## 4. The five things the spike must prove (in risk order)

### Step 1 — Incremental client output from `access` *(highest risk — gate)*

In `handler.lua`'s `access`, **in isolation** (no WS, no upstream yet):

```lua
ngx.status = 200
ngx.header["Content-Type"] = "text/event-stream"
for i = 1, 5 do
  ngx.print("data: chunk " .. i .. "\n\n")
  ngx.flush(true)
  -- simulated delay between chunks
end
ngx.eof()
return ngx.exit(ngx.HTTP_OK)   -- bypass proxy_pass
```

**Pass criterion:** `curl -N` shows the 5 chunks arriving **spread over time**,
not buffered into one blob at the end. Also confirm the `log` phase still runs
(emit a marker in `log` and check the Kong log) so analytics/metrics survive the
takeover.

**If this fails:** stop. The in-Kong streaming design is not viable; fall back
to the sidecar and re-open the decision. Do **not** build steps 2–5.

### Step 2 — Streaming upstream read

`httpc:connect()` + `httpc:request{}` against `sse_upstream.lua`; consume
`res.body_reader` in a loop. **Pass:** chunks are read incrementally as the mock
emits them (not all at once after the body completes).

### Step 3 — Outbound WS round-trip from `access`

`resty.websocket.client:connect("ws://mock")`, `send_text` / `recv_frame`
against `cato_ws_echo.lua`. **Pass:** cosocket works in `access`; record added
per-chunk latency.

### Step 4 — The full duplex bridge with hold-back buffer

Wire it together using the **`data_plane.lua` thread/semaphore pattern**, not a
single loop, because verdicts are **not 1:1** with reads (Cato may consume N
chunks of lookahead before clearing M):

- **upstream-reader thread:** LLM `body_reader` → append to buffer (indexed) →
  `ws:send_text(chunk)`
- **verdict-reader thread:** `ws:recv_frame()` → interpret verdict → drive the
  emit side
- **emit side:** `ngx.print` + `ngx.flush` exactly the chunks the verdict
  clears, using the **bytes the verdict carries** (so modified/redacted chunks
  are emitted verbatim from Cato, not from the buffer)
- coordinated by `ngx.semaphore`; joined by `ngx.thread.wait`

Honor the three control signals:
- `verified_chunk` → emit (possibly-modified) and advance
- `blocking_message` → stop, emit an error SSE event, `ngx.eof`
- `done` → `ngx.eof`

`cato_ws_echo.lua` **must** model decoupling: e.g. consume 3 chunks, then emit
"clear chunk 1 (modified)", "hold", "block at chunk 3" — so the spike actually
exercises the lookahead gap and the buffer.

### Step 5 — Failure & lifecycle behavior

- **Client disconnects mid-stream:** does the `ngx.print` error propagate so we
  can tear down both the LLM conn and the WS? (`ngx.thread.wait` should unwind.)
- **WS connect fails:** `fail_open` (proxy raw) vs `fail_closed` (503) — make it
  a config flag and test both.
- **Upstream timeout / WS timeout:** clean teardown, no orphaned cosockets.
- **Hold-back safety (security-critical):** with a mock that blocks at chunk 3,
  assert the client receives chunks 1–2 (or 0, per Cato lookahead) plus the
  error event, and **never** the bytes of chunk 3.

---

## 5. Out of scope for the spike

- Real Cato protocol, auth headers, TLS to Cato
- ai-proxy loopback integration / provider normalization / analytics
- Multi-provider SSE formats (OpenAI vs Anthropic vs Bedrock framing)
- Non-streaming REST guardrail path (stays on the normal Kong AI filter chain)
- Schema polish, config validation, multi-tenant concerns

These belong to the full `ai-cato-guard` plan, gated on this spike passing.

---

## 6. Exit criteria & decision

**Go (build the full plugin):** steps 1–4 pass and step 5 shows clean teardown +
the hold-back safety assertion holds. Record per-chunk latency overhead from
step 3/4 in `NOTES.md`.

**No-go (sidecar):** step 1 fails, or duplex teardown in step 5 proves
unreliable (orphaned connections, client hangs). Document the failure mode and
re-open the sidecar-vs-in-Kong decision with stakeholders.

---

## 7. Appendix: the full plugin (only if the spike passes)

For reference — the shape the production plugin would take, not part of the
spike:

```
kong/plugins/ai-cato-guard/
  handler.lua            -- branch: streaming → bridge; else → REST filters
  schema.lua             -- api_key, api_base, app_name, timeout, fail_open,
                         --   guard_request/response, stream_mode, loopback target
  cato_client.lua        -- REST /fw/v1/analyze (non-stream paths)
  cato_ws_bridge.lua     -- duplex WS bridge (this spike, hardened)
  filters/
    guard-request.lua    -- REQ_TRANSFORMATION (REST)
    guard-response.lua   -- RES_TRANSFORMATION (REST, non-stream)
    stream-bridge.lua    -- access-phase takeover for stream=true
spec/03-plugins/NN-ai-cato-guard/
    00-config_spec / 01-unit_spec / 02-integration_spec (+ streaming test)
```

Non-streaming requests stay on Kong's idiomatic AI filter pipeline
(`REQ_TRANSFORMATION` / `RES_TRANSFORMATION` calling Cato's REST
`/fw/v1/analyze`). Only `stream=true` responses take the takeover bridge.
Optionally, the bridge's upstream call targets the local ai-proxy-backed route
over loopback, preserving ai-proxy's provider normalization + analytics while
the plugin owns the client-facing stream.

Headers carried on both REST and WS: `Authorization: Bearer`, `x-cato-call-id`
(Kong request id), `x-cato-user-email`, `x-cato-session-id`,
`x-cato-gateway-key-alias` (= `app_name`), `x-cato-kong-version`. Plus plugin
registration in `kong/constants.lua` and the rockspec.
