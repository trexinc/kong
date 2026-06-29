local typedefs = require("kong.db.schema.typedefs")

return {
  name = "ai-cato-networks-guard",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          -- Cato Networks firewall connection
          { api_key = {
              type = "string",
              required = true,
              referenceable = true,
              encrypted = true,
              description = "Cato Networks AI firewall API key, sent as `Authorization: Bearer <api_key>` "
                         .. "(token format: `cato-<tenant_id>-<token_id>`).",
          }, },
          { api_base = {
              type = "string",
              required = true,
              referenceable = true,
              default = "https://api.aim.security",
              description = "Base URL of the Cato Networks AI firewall. The WebSocket base used for "
                         .. "streaming is derived from this (http->ws, https->wss).",
          }, },
          { app_name = {
              type = "string",
              required = false,
              referenceable = true,
              description = "Logical application name, sent as `x-cato-gateway-key-alias`.",
          }, },
          { http_timeout = {
              type = "integer",
              required = true,
              default = 30000,
              gt = 0,
              description = "Timeout in milliseconds for REST and WebSocket calls to the firewall.",
          }, },
          { https_verify = {
              type = "boolean",
              required = true,
              default = true,
              description = "Verify the TLS certificate of the Cato Networks firewall.",
          }, },

          -- Guardrail framework fields (required by the guard-* shared filters)
          { guarding_mode = {
              type = "string",
              required = true,
              default = "BOTH",
              one_of = { "INPUT", "OUTPUT", "BOTH" },
              description = "Which phases to guard: INPUT (request), OUTPUT (response), or BOTH.",
          }, },
          { allow_masking = {
              type = "boolean",
              required = true,
              default = true,
              description = "Allow the firewall to anonymize/redact request and buffered-response content "
                         .. "(applies the `anonymize_action` verdict). Streaming responses are never "
                         .. "masked -- they can only be blocked.",
          }, },
          { stop_on_error = {
              type = "boolean",
              required = true,
              default = true,
              description = "If a firewall call errors, stop processing (fail closed). When false, the "
                         .. "request/response is allowed through (fail open).",
          }, },
          { response_buffer_size = {
              type = "number",
              required = true,
              default = 100,
              description = "Bytes of streamed response to accumulate before each streaming guard check.",
          }, },
          { log_blocked_content = {
              type = "boolean",
              required = true,
              default = false,
              description = "Whether to log prompts/responses that are blocked by the guardrail.",
          }, },
        },
        entity_checks = {},
    }, },
  },
}
