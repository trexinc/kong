-- Cato Networks AI firewall REST client + shared header/URL construction.
--
-- Mirrors the litellm "aim" guardrail contract:
--   POST {api_base}/fw/v1/analyze   with { messages = [...] }
--   verdict in `required_action.action_type`:
--     nil | "monitor_action"  -> allow
--     "block_action"          -> block (required_action.detection_message)
--     "anonymize_action"      -> rewrite from redacted_chat.all_redacted_messages
local http  = require("resty.http")
local cjson = require("cjson.safe")
local meta  = require("kong.meta")

local _M = {}


-- Request context forwarded to the firewall, read from incoming headers.
function _M.request_context(conf)
  return {
    call_id    = kong.request.get_header("x-cato-call-id")
              or kong.request.get_header("x-aim-call-id")
              or ngx.var.request_id,
    session_id = kong.request.get_header("x-cato-session-id")
              or kong.request.get_header("x-aim-session-id"),
    user_email = kong.request.get_header("x-cato-user-email")
              or kong.request.get_header("x-aim-user-email"),
    key_alias  = conf.app_name,
  }
end


-- `hook` is the request phase ("pre_call" before the LLM, "output" for the
-- response). x-cato-* are the firewall's preferred header names.
function _M.build_headers(conf, hook, ctx)
  local headers = {
    ["Authorization"]       = "Bearer " .. conf.api_key,
    ["x-aim-litellm-hook"]  = hook,
    ["x-cato-kong-version"] = meta.version,
  }
  if ctx.call_id    then headers["x-cato-call-id"]           = ctx.call_id    end
  if ctx.session_id then headers["x-cato-session-id"]        = ctx.session_id end
  if ctx.user_email then headers["x-cato-user-email"]        = ctx.user_email end
  if ctx.key_alias  then headers["x-cato-gateway-key-alias"] = ctx.key_alias  end
  return headers
end


function _M.headers_to_array(headers)
  local arr = {}
  for k, v in pairs(headers) do
    arr[#arr + 1] = k .. ": " .. v
  end
  return arr
end


function _M.analyze_url(conf)
  return conf.api_base .. "/fw/v1/analyze"
end


function _M.stream_url(conf)
  local base = conf.api_base:gsub("^http://", "ws://"):gsub("^https://", "wss://")
  return base .. "/fw/v1/analyze/stream"
end


-- POST messages to the firewall for analysis. Returns parsed table, or nil + err.
function _M.analyze(conf, messages, hook, ctx)
  local headers = _M.build_headers(conf, hook, ctx)
  headers["Content-Type"] = "application/json"

  local body = cjson.encode({ messages = messages })
  if not body then
    return nil, "failed to encode analyze request"
  end

  local httpc = http.new()
  httpc:set_timeout(conf.http_timeout)

  local res, err = httpc:request_uri(_M.analyze_url(conf), {
    method = "POST",
    body = body,
    headers = headers,
    ssl_verify = conf.https_verify,
  })
  if not res then
    return nil, "firewall request failed: " .. tostring(err)
  end
  if res.status >= 400 then
    return nil, "firewall returned status " .. res.status
  end

  local parsed = cjson.decode(res.body)
  if not parsed then
    return nil, "failed to decode firewall response"
  end
  return parsed
end


-- cjson decodes JSON `null` to a truthy sentinel, so resolve via table checks.
local function action_of(res)
  local required = res.required_action
  if type(required) ~= "table" then
    return nil, nil
  end
  return required.action_type, required
end


local function redacted_messages_of(res)
  local chat = res.redacted_chat
  if type(chat) ~= "table" or type(chat.all_redacted_messages) ~= "table" then
    return nil
  end
  return chat.all_redacted_messages
end


-- REQUEST phase: returns action, detection_message, redacted_messages(table).
function _M.interpret_request(res)
  local action, required = action_of(res)
  if action == "block_action" then
    return action, required.detection_message or "blocked by Cato Networks guardrail", nil
  end
  if action == "anonymize_action" then
    local redacted = redacted_messages_of(res)
    if redacted then
      local messages = {}
      for i = 1, #redacted do
        messages[i] = { role = redacted[i].role, content = redacted[i].content }
      end
      return action, nil, messages
    end
  end
  return action, nil, nil
end


-- OUTPUT phase: returns action, detection_message, redacted_output(string).
function _M.interpret_output(res)
  local action, required = action_of(res)
  if action == "block_action" then
    return action, required.detection_message or "blocked by Cato Networks guardrail", nil
  end
  if action == "anonymize_action" then
    local redacted = redacted_messages_of(res)
    if redacted and #redacted > 0 then
      return action, nil, redacted[#redacted].content
    end
  end
  return action, nil, nil
end


return _M
