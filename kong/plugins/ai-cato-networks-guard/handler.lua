-- ai-cato-networks-guard: an EE AI-guardrail plugin (built on the
-- kong.llm.plugin.guardrail_plugin framework) that guards LLM traffic via the
-- Cato Networks AI firewall.
--
--   request           : block / anonymize  (REST /fw/v1/analyze, hook=pre_call)
--   buffered response : block / anonymize  (REST /fw/v1/analyze, hook=output)
--   streaming response: block only         (per-window WS to /fw/v1/analyze/stream)
--
-- NOTE: requires Kong Gateway Enterprise (kong.llm.plugin.guardrail_plugin is an
-- EE module). It will not load on OSS Kong.
local factory       = require("kong.llm.plugin.guardrail_plugin")
local ai_plugin_ctx = require("kong.llm.plugin.ctx")
local cjson         = require("cjson.safe")
local cato          = require("kong.plugins.ai-cato-networks-guard.cato_client")
local cato_stream   = require("kong.plugins.ai-cato-networks-guard.cato_stream")

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
  local analysis, err = cato.analyze(conf, messages, "pre_call", ctx)
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
    new_body.messages = redacted
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
  local content = type(message) == "table" and message.content
  if type(content) ~= "string" then
    return ALLOW   -- nothing analyzable
  end

  -- Build the conversation (request messages + assistant answer) for context.
  local messages = {}
  local req_messages = request_messages()
  if req_messages then
    for i = 1, #req_messages do
      messages[i] = req_messages[i]
    end
  end
  messages[#messages + 1] = { role = "assistant", content = content }

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
    message.content = redacted_output
    return { masked = true, body = cjson.encode(parsed), metrics = { output_masked = true } }
  end

  return ALLOW
end


-- Streaming: forward each accumulated window to Cato over WS; block-only.
local function guard_stream_response(conf, chunk)
  if type(chunk) ~= "string" or chunk == "" then
    return ALLOW
  end

  local ctx = cato.request_context(conf)
  local verdict, err = cato_stream.guard_window(conf, chunk, ctx)
  if not verdict then
    return nil, err
  end

  if verdict.block then
    return { block = true, block_message = verdict.block_message,
             metrics = { output_block_reason = verdict.block_message or "blocked" } }
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
