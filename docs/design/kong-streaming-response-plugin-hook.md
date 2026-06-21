# Design: First-class streaming response control for Kong plugins

**Status:** Proposal — investigation complete, no code yet
**Branch:** `claude/determined-brahmagupta-ch4ywa`
**Related:** `docs/design/ai-cato-networks-guard-streaming-spike.md` (the proven
takeover spike this would replace), `kong/plugins/ai-cato-networks-guard/`

---

## 1. Problem

A guardrail plugin needs, **while an LLM response streams**, to:

1. perform **async network I/O** per chunk (call an external service — e.g. the
   Cato Networks firewall over WebSocket/HTTP),
2. **hold chunks back** from the client (lookahead buffering),
3. per chunk/event, **decide**: forward as-is, forward **modified**, **drop**,
   or **block** the remainder of the stream,

without buffering the whole response first (time-to-first-token must stay low),
and without every plugin reinventing the transport plumbing.

Today this is only achievable with an **access-phase takeover hack** (see the
spike and `ai-cato-networks-guard`'s `stream_bridge.lua`): the plugin abandons
Kong's normal proxy path, dials the upstream itself, runs a manual duplex
reader/verdict thread pair, and writes the client response with raw
`ngx.print`/`ngx.flush`/`ngx.eof`. It works, but it is fragile and bypasses
Kong's balancer integration, the normal plugin chain, and `ai-proxy`.

This document proposes a **core Kong change** that makes this a first-class,
supported capability — and shows that it is the natural streaming twin of a
mechanism Kong **already has** for buffered responses.

## 2. The constraint (verified)

Execution context and cosocket availability by phase (from
`kong/init.lua`, `kong/templates/nginx_kong.lua`, `kong/pdk/private/phases.lua`):

| Phase | nginx context | Cosockets? | Sees response as |
|---|---|---|---|
| rewrite / access / balancer | request | **yes** | (no response yet) |
| **response** (buffered) | runs in **access context** after `ngx.location.capture` | **yes** | **fully buffered body** |
| header_filter | filter | no | headers only |
| **body_filter** | filter (per chunk) | **no** | **streaming chunks** |
| log | log | no | — |

The two phases that could host the logic are mutually exclusive in what they
offer:

- **`body_filter`** (and the AI framework's `STREAMING` stage, id 6 in
  `kong/llm/plugin/base.lua`, which maps to `body_filter`) sees every chunk —
  it even *accumulates* the full stream into `sse_body_buffer` for analytics in
  `normalize-sse-chunk.lua` — but **cannot use cosockets**. This is an OpenResty
  invariant for filter phases, not a Kong limitation; confirmed by the framework
  falling back to `ngx.exit` (not `kong.response.exit`) there.
- The **buffered `response` phase** *can* use cosockets (it runs in access
  context), but `ngx.location.capture("/kong_buffered_http")` **buffers the
  entire body** first, defeating streaming.

That gap is precisely what forces the takeover.

## 3. Why each existing path fails

| Path | I/O during stream? | Streams? | Verdict |
|---|---|---|---|
| `body_filter` / AI `STREAMING` stage | ❌ no cosockets | ✅ | can't call the guard |
| Buffered `response` phase (`enable_buffering()`) | ✅ cosockets ok | ❌ fully buffered | kills TTFT |
| Access-phase takeover (spike / `ai-response-transformer`) | ✅ | ✅ | works, but a hack |

The takeover is a hack because the **plugin** reimplements the content phase:
manual `ngx.print`/`flush`/`eof`, manual `ngx.thread` duplex + semaphore,
bypasses nginx `proxy_pass` (so the balancer, keepalive, the normal
header/body_filter plugin chain, and `ai-proxy` are all skipped), and each
plugin must re-solve SSE framing, gzip, client-abort, and analytics.

## 4. Key insight: Kong already takes over in access — for buffering

`Kong.response()` (`kong/init.lua:1491`) is **already an access-phase takeover
owned by core**. On `kong.service.request.enable_buffering()`, `Kong.access()`
detects `ctx.buffered_proxying` and calls `Kong.response()`, which:

1. fetches the full upstream response via
   `ngx.location.capture("/kong_buffered_http")` (an internal location with all
   plugin phases disabled — `nginx_kong.lua:352`),
2. runs a dedicated **`response` plugin phase** in the cosocket-capable access
   context (`execute_collected_plugins_iterator(plugins_iterator, "response", ctx)`),
3. then `ngx.print(body); ngx.exit(status)`.

So the takeover pattern is **not foreign to Kong — it is how buffering works.**
The clean fix is to add the **streaming sibling** of this mechanism.

## 5. Proposal: a streaming-response phase owned by core

Five components:

### (a) Opt-in PDK
`kong.service.response.enable_streaming_processing()` — sibling of
`enable_buffering()` (`kong/pdk/service/request.lua:91`). Sets a
`ctx.streaming_proxying` flag in rewrite/access.

### (b) Runloop branch
In `Kong.access()`, alongside the existing `ctx.buffered_proxying` check, add a
`ctx.streaming_proxying` branch that dispatches to a new
`Kong.stream_response()` — the streaming analog of `Kong.response()`.

### (c) Core Lua-land proxy
`Kong.stream_response()` connects to the **already-selected**
`ngx.ctx.balancer_data` target with `lua-resty-http` and reads `res.body_reader`
incrementally. **Core (not the plugin)** owns: SSE framing (reuse
`ai_shared.frame_to_events`), gzip, `ngx.print`/`ngx.flush`/`ngx.eof`,
client-abort detection, and end-of-stream analytics accumulation.

### (d) New plugin phase `response_stream`
For each chunk/SSE event, core runs a new collected-plugins phase **in the
cosocket-capable access-context coroutine** — exactly mirroring how
`Kong.response()` runs the `response` phase. This is where a plugin calls its
external guard. Cosockets (`resty.http`, `resty.websocket.client`) are allowed
here.

### (e) Hold-back / verdict contract
Core maintains a bounded hold-back buffer. The per-event hook returns a
disposition; core decides what to emit. The plugin makes decisions; it never
touches `ngx.*` or manages threads.

This removes **every** hack we flagged: no plugin-level output writes, no manual
threads, balancer/keepalive/analytics handled once by core, and it composes
because core drives phase ordering.

## 6. Proposed plugin-facing API (interface sketch — design, not implementation)

```lua
-- opt in (access phase)
kong.service.response.enable_streaming_processing()

-- new handler method, invoked by core per SSE event,
-- in a cosocket-capable coroutine
function MyPlugin:response_stream(event, ctx)
  -- event.data : the parsed SSE payload (decoded)
  -- ALLOWED here: resty.http / resty.websocket / any cosocket I/O (may yield)
  return {
    action  = "forward" | "replace" | "hold" | "drop" | "block",
    data    = <modified event bytes when action == "replace">,
    message = <client-facing reason when action == "block">,
  }
end
```

Core semantics:

- `forward` — emit the event unchanged.
- `replace` — emit `data` (modified/redacted bytes).
- `hold` — withhold and accumulate (lookahead); released when a later event
  returns `forward`/`replace`.
- `drop` — discard the event.
- `block` — stop the stream, emit `message` as a terminal SSE event, close.

Lifecycle callbacks: `:response_stream_eof(ctx)` (flush held buffer / send
`[DONE]`) and a teardown hook so the plugin can close its WS connection on
client disconnect or upstream end.

### How the Cato Networks guard maps onto it

`response_stream` opens the firewall WebSocket **once** (lazily, on first
event), sends each `event.data`, awaits the verdict, and returns:
`replace`/`forward` for `verified_chunk` (possibly modified), `hold` while the
firewall buffers lookahead, `block` for `blocking_message`. **No `ngx.*`, no
`ngx.thread`, no SSE parsing in the plugin** — `stream_bridge.lua` collapses to
a thin verdict-translation layer.

## 7. Integration with the AI plugin framework

Add a stage `STREAMING_ASYNC` (or a per-filter flag on `STREAMING`) in
`kong/llm/plugin/base.lua` that maps to the new `response_stream` phase instead
of `body_filter`. The existing shared filters need no rewrite:

- `parse-sse-chunk.lua` already frames chunks into events,
- `normalize-sse-chunk.lua` already transforms per event and accumulates the
  full body for analytics.

Only the **execution context** changes (cosocket-capable coroutine instead of
`body_filter`). `ai-proxy` opts in via `enable_streaming_processing()` when
`stream:true` and a participating guard plugin is on the route.

## 8. Risks & limitations (honest)

- **Balancer semantics.** Core can retry at **connect time** by looping balancer
  target selection. **Mid-stream failover is impossible** — but that is already
  true of nginx `proxy_pass` (you cannot fail over once bytes are sent).
  Document it.
- **Memory.** The hold-back buffer must be bounded (config cap → `block` or
  fail-open on overflow), or a large/hostile stream can OOM the worker.
- **Backpressure / TTFT.** The guard's per-event latency now gates client TTFT.
  Needs timeouts and a fail-open path identical to the buffered path.
- **Performance.** A Lua-land proxy is heavier than nginx `proxy_pass`; it is
  **opt-in per route**, so only guarded routes pay. Must benchmark against the
  buffered path.
- **Scope.** v1 targets SSE chat-completions only. HTTP/2, non-SSE framings, and
  WebSocket *upstreams* are out of scope.
- **Maintenance / upstreaming.** This touches the core proxy path. Two tracks:
  (i) carry it as a **fork patch** — fast to ship, ours to maintain; (ii) file
  an **upstream Kong RFC** for a general "streaming response filter" hook —
  slower, but offloads maintenance and benefits beyond AI. Pursue (i) to ship,
  (ii) in parallel.

## 9. Phased plan

1. **Prototype (fork).** Implement (a)+(b)+(c)+(d) minimally:
   `enable_streaming_processing()`, `Kong.stream_response()` streaming
   `res.body_reader` from `balancer_data`, and a single hardcoded
   `response_stream` invocation. Validate end-to-end against the spike's mock
   Cato (`spike/mocks`). *This is the de-risking step.*
2. **Hold-back + contract.** Add the verdict/disposition buffer (e) with bounded
   memory.
3. **AI-framework wiring.** Add `STREAMING_ASYNC`; port `ai-cato-networks-guard`
   streaming onto it and delete `stream_bridge.lua`'s `ngx.*`/thread machinery —
   it becomes core's job.
4. **Harden.** Timeouts, fail-open, client-abort, gzip, analytics parity with
   the buffered path; benchmark.
5. **Upstream RFC.** Write it up for Kong OSS as a general hook.

**Effort:** phase 1 ≈ a few days (essentially promoting the proven spike into
`Kong.stream_response()`); phases 2–4 are the bulk; phase 5 is ongoing.

## 10. Bottom line

The clean design is not novel — it is the **streaming twin of Kong's existing
`enable_buffering()` / `Kong.response()` takeover**, plus a new cosocket-capable
`response_stream` plugin phase. Core owns the proxy loop, SSE framing, output,
and the hold-back buffer; plugins make per-event decisions with full async I/O.
That eliminates every hack in the current takeover approach.
