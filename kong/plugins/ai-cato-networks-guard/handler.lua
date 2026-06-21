-- ai-cato-networks-guard: guard LLM requests/responses via the Cato Networks
-- AI firewall. (Non-streaming: streamed responses are not inspected.)
--
-- Runs entirely in the access phase (the only phase where cosockets are
-- available for the firewall calls):
--   1. Request guard  -- POST /fw/v1/analyze (hook=pre_call): block / anonymize.
--   2. Response guard -- take over the upstream call (like ai-response-transformer)
--      and analyze the buffered response (hook=output): block / redact.
-- Streaming requests (stream: true) are handled per conf.on_streaming.
local http       = require("resty.http")
local cjson      = require("cjson.safe")
local kong_utils = require("kong.tools.gzip")
local meta       = require("kong.meta")
local cato       = require("kong.plugins.ai-cato-networks-guard.cato_client")

local ngx  = ngx
local kong = kong


local CatoNetworksGuard = {
  -- After ai-prompt-guard (771); we take over the upstream call when guarding
  -- the response.
  PRIORITY = 772,
  VERSION = meta.version,
}


local function bad_request(msg)
  kong.log.info("ai-cato-networks-guard: ", msg)
  return kong.response.exit(400, { error = { message = msg } })
end


local function server_error(msg)
  kong.log.err("ai-cato-networks-guard: ", msg)
  return kong.response.exit(500, { error = { message = msg } })
end


-- Request context forwarded to the firewall (headers carried on the REST call).
local function request_context(conf)
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


-- Take over the upstream call, exactly as ai-response-transformer does:
-- connect to the resolved balancer target and replay the (possibly modified)
-- request, returning the buffered response. Returns res or nil, err.
local function subrequest(conf, request_body)
  local httpc = http.new()
  httpc:set_timeout(conf.http_timeout)

  local upstream_uri = ngx.var.upstream_uri
  if ngx.var.is_args == "?" or string.sub(ngx.var.request_uri, -1) == "?" then
    ngx.var.upstream_uri = upstream_uri .. "?" .. (ngx.var.args or "")
  end

  local ok, err = httpc:connect({
    scheme          = ngx.var.upstream_scheme,
    host            = ngx.ctx.balancer_data.host,
    port            = ngx.ctx.balancer_data.port,
    ssl_verify      = false,
    ssl_server_name = ngx.ctx.balancer_data.host,
  })
  if not ok then
    return nil, "failed to connect to upstream: " .. err
  end

  local headers = kong.request.get_headers()
  headers["transfer-encoding"] = nil
  headers["content-length"] = nil
  if ngx.var.upstream_host == "" then
    headers["host"] = nil
  else
    headers["host"] = ngx.var.upstream_host
  end

  local res
  res, err = httpc:request({
    method  = kong.request.get_method(),
    path    = ngx.var.upstream_uri,
    headers = headers,
    body    = request_body,
  })
  if not res then
    return nil, "subrequest failed: " .. err
  end

  local res_body = res:read_body()
  httpc:close()

  return res, res_body
end


-- Analyze a buffered upstream response and return it, blocking or redacting per
-- the firewall verdict.
local function guard_buffered_response(conf, ctx, res, res_body, request_messages)
  if res.headers["Content-Encoding"] == "gzip" then
    res_body = kong_utils.inflate_gzip(res_body)
  end

  local parsed = cjson.decode(res_body)
  local choice = type(parsed) == "table" and type(parsed.choices) == "table" and parsed.choices[1]
  local message = type(choice) == "table" and choice.message
  local content = type(message) == "table" and message.content
  if type(content) ~= "string" then
    content = nil
  end

  res.headers["content-encoding"] = nil
  res.headers["content-length"] = nil

  if not content then
    -- Nothing analyzable; pass the response through untouched.
    return kong.response.exit(res.status, res_body, res.headers)
  end

  local messages = {}
  for i = 1, #request_messages do
    messages[i] = request_messages[i]
  end
  messages[#messages + 1] = { role = "assistant", content = content }

  local analysis, err = cato.analyze(conf, messages, "output", ctx)
  if not analysis then
    if conf.fail_open then
      kong.log.warn("ai-cato-networks-guard: fail_open on response analysis: ", err)
      return kong.response.exit(res.status, res_body, res.headers)
    end
    return server_error("response analysis failed: " .. err)
  end

  local action, detection_message, redacted_output = cato.interpret_output(analysis)
  if action == "block_action" then
    return bad_request(detection_message)
  end

  if action == "anonymize_action" and redacted_output then
    message.content = redacted_output
    res_body = cjson.encode(parsed)
  end

  return kong.response.exit(res.status, res_body, res.headers)
end


function CatoNetworksGuard:access(conf)
  local ctx = request_context(conf)

  local raw_body = kong.request.get_raw_body(conf.max_request_body_size)
  local body = raw_body and cjson.decode(raw_body)
  if type(body) ~= "table" then
    body = nil
  end
  local messages = (body and type(body.messages) == "table") and body.messages or {}
  local is_stream = body ~= nil and body.stream == true

  -- 1. Request guard (applies to streaming and non-streaming alike).
  if conf.guard_request and #messages > 0 then
    local analysis, err = cato.analyze(conf, messages, "pre_call", ctx)
    if not analysis then
      if not conf.fail_open then
        return server_error("request analysis failed: " .. err)
      end
      kong.log.warn("ai-cato-networks-guard: fail_open on request analysis: ", err)
    else
      local action, detection_message, redacted = cato.interpret_request(analysis)
      if action == "block_action" then
        return bad_request(detection_message)
      end
      if action == "anonymize_action" and redacted then
        body.messages = redacted
        messages = redacted
        raw_body = cjson.encode(body)
        kong.service.request.set_raw_body(raw_body)
      end
    end
  end

  -- Streaming responses are not inspected by this plugin.
  if is_stream then
    if conf.on_streaming == "block" then
      return kong.response.exit(422, {
        error = { message = "streaming responses are not supported by ai-cato-networks-guard" },
      })
    end
    -- passthrough: the prompt was guarded above; let Kong proxy the stream.
    return
  end

  -- No response guarding: let Kong proxy the (possibly anonymized) request.
  if not conf.guard_response then
    return
  end

  -- 2. Response guard -- take over the upstream call and analyze the response.
  local res, res_body = subrequest(conf, raw_body)
  if not res then
    if conf.fail_open then
      kong.log.warn("ai-cato-networks-guard: fail_open on subrequest: ", res_body)
      return  -- fall back to Kong's normal proxying
    end
    return server_error(tostring(res_body))
  end

  return guard_buffered_response(conf, ctx, res, res_body, messages)
end


return CatoNetworksGuard
