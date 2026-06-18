-- THROWAWAY spike plugin schema. Not production.
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "spike-stream-bridge",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Which risk to validate. See handler.lua.
          { stage = {
              type = "string",
              required = true,
              default = "static",
              one_of = { "static", "upstream", "ws", "bridge" },
          }, },
          -- Mock upstream SSE source (used by stages: upstream, bridge).
          { upstream_url = {
              type = "string",
              default = "http://127.0.0.1:9000/sse",
          }, },
          -- Mock Cato Networks WS endpoint (used by stages: ws, bridge).
          { cato_ws_url = {
              type = "string",
              default = "ws://127.0.0.1:9001/analyze",
          }, },
          -- static/ws stages: how many synthetic chunks to emit.
          { chunk_count = { type = "integer", default = 5, between = { 1, 100 } }, },
          -- static stage: delay between chunks (ms) to prove incremental flush.
          { chunk_delay_ms = { type = "integer", default = 300, between = { 0, 10000 } }, },
          -- cosocket recv timeout (ms).
          { recv_timeout_ms = { type = "integer", default = 30000, between = { 100, 600000 } }, },
          -- If the guardrail/upstream is unreachable: true = stream unguarded,
          -- false = return 5xx. Tested in plan step 5.
          { fail_open = { type = "boolean", required = true, default = false }, },
        },
    }, },
  },
}
