local typedefs = require("kong.db.schema.typedefs")


return {
  name = "ai-cato-networks-guard",
  fields = {
    { protocols = typedefs.protocols_http },
    { consumer = typedefs.no_consumer },
    { config = {
        type = "record",
        fields = {
          { api_key = {
              description = "Cato Networks AI firewall API key. Sent as `Authorization: Bearer <api_key>` "
                         .. "(token format: `cato-<tenant_id>-<token_id>`).",
              type = "string",
              required = true,
              referenceable = true,
          }, },
          { api_base = {
              description = "Base URL of the Cato Networks AI firewall.",
              type = "string",
              required = true,
              default = "https://api.aim.security",
          }, },
          { app_name = {
              description = "Logical application name. Sent as `x-cato-gateway-key-alias` so the firewall "
                         .. "applies the guardrails associated with this key alias.",
              type = "string",
              required = false,
          }, },
          { guard_request = {
              description = "Analyze the incoming prompt before it reaches the LLM (block / anonymize).",
              type = "boolean",
              required = true,
              default = true,
          }, },
          { guard_response = {
              description = "Analyze the (non-streaming) LLM response before it reaches the client. "
                         .. "Streaming responses are not inspected by this plugin (see `on_streaming`).",
              type = "boolean",
              required = true,
              default = true,
          }, },
          { on_streaming = {
              description = "What to do when a request asks for a streamed response (`stream: true`), "
                         .. "since this plugin does not guard streamed responses: `passthrough` proxies "
                         .. "the stream unguarded (the request prompt is still guarded), `block` rejects "
                         .. "the request with 422.",
              type = "string",
              required = true,
              default = "passthrough",
              one_of = { "passthrough", "block" },
          }, },
          { http_timeout = {
              description = "Timeout in milliseconds for calls to the Cato Networks firewall.",
              type = "integer",
              required = true,
              default = 30000,
              gt = 0,
          }, },
          { https_verify = {
              description = "Verify the TLS certificate of the Cato Networks firewall.",
              type = "boolean",
              required = true,
              default = true,
          }, },
          { fail_open = {
              description = "If the firewall is unreachable or errors, allow the request/response through "
                         .. "instead of failing closed with a 5xx.",
              type = "boolean",
              required = true,
              default = false,
          }, },
          { max_request_body_size = {
              description = "Maximum request body size (bytes) read for analysis.",
              type = "integer",
              required = true,
              default = 8 * 1024,
              gt = 0,
          }, },
        },
    }, },
  },
}
