-- ai-cato-networks-guard: an EE AI-guardrail plugin (built on the
-- kong.llm.plugin.guardrail_plugin framework) that guards LLM traffic via the
-- Cato Networks AI firewall.
--
--   request           : block / anonymize  (REST /fw/v1/analyze, hook=pre_call)
--   buffered response : block / anonymize  (REST /fw/v1/analyze, hook=output)
--   streaming response: block only         (per-window REST /fw/v1/analyze, hook=output)
--
-- NOTE: requires Kong Gateway Enterprise (kong.llm.plugin.guardrail_plugin is an
-- EE module). It will not load on OSS Kong.
local factory       = require("kong.llm.plugin.guardrail_plugin")
local ai_plugin_ctx = require("kong.llm.plugin.ctx")
local cjson         = require("cjson.safe")
local cato          = require("kong.plugins.ai-cato-networks-guard.cato_client")

local kong = kong

local _M = {
  NAME = "ai-cato-networks-guard",
  PRIORITY = 772,
  MANIFESTS = {
    can_guard_request           = true,
    can_guard_buffered_response = true,
    can_guard_stream_response   = true,
    can_streaming               = true,   -- allow streaming (block-only guard)
    can_serialize_analytics     = true,
  },
}

local ALLOW = { block = false }


-- Collect the request messages from the in-use request body table.
local function request_messages()
  local request_table = ai_plugin_ctx.get_request_body_table_inuse()
  if type(request_table) ~= "table" or type(request_table.messages) ~= "table" then
    return nil, request_table
  end
  return request_table.messages, request_table
end


local function guard_request(conf)
  local messages, request_table = request_messages()
  if not messages then
    return ALLOW
  end

  local ctx = cato.request_context(conf)
  -- Forward tool definitions too, so injection hidden in tool descriptions /
  -- parameter schemas is screened. Tool-call messages are already in `messages`.
  local tools = type(request_table.tools) == "table" and request_table.tools or nil
  local analysis, err = cato.analyze(conf, messages, "pre_call", ctx, tools)
  if not analysis then
    return nil, err
  end

  local action, detection_message, redacted = cato.interpret_request(analysis)
  if action == "block_action" then
    return { block = true, block_message = detection_message,
             metrics = { input_block_reason = detection_message } }
  end

  if action == "anonymize_action" and redacted and conf.allow_masking then
    local new_body = {}
    for k, v in pairs(request_table) do
      new_body[k] = v
    end
    -- Merge redacted content into the original messages so tool_calls /
    -- tool_call_id / name are preserved (rebuilding {role,content} would break
    -- tool-calling conversations).
    new_body.messages = cato.merge_redacted_content(messages, redacted)
    return { masked = true, body = new_body, metrics = { input_masked = true } }
  end

  return ALLOW
end


local function guard_buffered_response(conf)
  local body, err = ai_plugin_ctx.get_response_body()
  if err or not body then
    return nil, err or "no response body"
  end

  local parsed = cjson.decode(body)
  local choice  = type(parsed) == "table" and type(parsed.choices) == "table" and parsed.choices[1]
  local message = type(choice) == "table" and choice.message
  if type(message) ~= "table" then
    return ALLOW
  end

  -- Analyzable if there is text/multimodal content OR a tool call. For tool
  -- calls the payload lives in message.tool_calls[].function.arguments, not in
  -- content, so we must inspect the whole assistant message.
  local content   = message.content
  local has_content = type(content) == "string" or type(content) == "table"
  local has_tool  = type(message.tool_calls) == "table" and #message.tool_calls > 0
  if not (has_content or has_tool) then
    return ALLOW
  end

  -- Build the conversation (request messages + the assistant message, including
  -- its tool_calls) for context.
  local messages = {}
  local req_messages = request_messages()
  if req_messages then
    for i = 1, #req_messages do
      messages[i] = req_messages[i]
    end
  end
  messages[#messages + 1] = message

  local ctx = cato.request_context(conf)
  local analysis, aerr = cato.analyze(conf, messages, "output", ctx)
  if not analysis then
    return nil, aerr
  end

  local action, detection_message, redacted_output = cato.interpret_output(analysis)
  if action == "block_action" then
    return { block = true, block_message = detection_message,
             metrics = { output_block_reason = detection_message } }
  end

  if action == "anonymize_action" and redacted_output and conf.allow_masking then
    -- Redacts textual content only; tool_calls are preserved as-is (Cato's
    -- output redaction returns a content string, not structured tool args).
    message.content = redacted_output
    return { masked = true, body = cjson.encode(parsed), metrics = { output_masked = true } }
  end

  return ALLOW
end


-- Streaming: analyze each accumulated window via REST; block-only (the
-- framework streams to the client optimistically and cannot hold back or
-- rewrite tokens, so masking is intentionally not applied here).
-- LIMITATION: the framework's stream accumulator (normalize-sse-chunk's
-- get_token_text) captures only delta.content / text, NOT
-- delta.tool_calls[].function.arguments -- so tool-call output is not inspected
-- while streaming. Tool calls ARE inspected on the request and buffered-response
-- paths; for streamed tool-call inspection, disable streaming (can_streaming via
-- guarding) or use a buffered route.
local function guard_stream_response(conf, chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return ALLOW
  end

  local ctx = cato.request_context(conf)
  local messages = { { role = "assistant", content = chunk } }
  local analysis, err = cato.analyze(conf, messages, "output", ctx)
  if not analysis then
    return nil, err
  end

  local action, detection_message = cato.interpret_output(analysis)
  if action == "block_action" then
    return { block = true, block_message = detection_message,
             metrics = { output_block_reason = detection_message } }
  end

  return ALLOW
end


local function get_metrics(conf)
  return { cato_api_base = conf.api_base }
end


local builder = factory.new(_M)

builder:register_function("guard-request", guard_request)
builder:register_function("guard-buffered-response", guard_buffered_response)
builder:register_function("guard-stream-response", guard_stream_response)
builder:register_function("guard-serialize-analytics", get_metrics)

return builder:build()
