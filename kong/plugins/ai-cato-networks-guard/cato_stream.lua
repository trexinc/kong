-- Per-window WebSocket forwarder to the Cato Networks firewall streaming
-- endpoint (/fw/v1/analyze/stream).
--
-- IMPORTANT — this is invoked from `guard-stream-response`, which the guardrail
-- framework runs inside an `ngx.timer.at(0, ...)` callback. That context DOES
-- allow cosockets (so the WS connect/send/recv works), BUT the framework fires
-- a fresh timer per response buffer window, and cosockets cannot be reused
-- across timer contexts. So we CANNOT hold one persistent Cato streaming
-- session for the whole response -- each window opens its own short-lived WS.
-- The framework also only acts on `block` for streaming (it streams to the
-- client optimistically and cannot hold back or rewrite tokens). A single
-- ordered hold-back session would require the access-phase takeover instead.
local ws_client = require("resty.websocket.client")
local cjson     = require("cjson.safe")
local cato      = require("kong.plugins.ai-cato-networks-guard.cato_client")

local _M = {}


-- Forward one accumulated text window to Cato over WS; return a verdict table
-- { block = bool, block_message = string|nil }, or nil + err.
function _M.guard_window(conf, text, ctx)
  local wb, err = ws_client:new()
  if not wb then
    return nil, "ws client: " .. tostring(err)
  end
  wb:set_timeout(conf.http_timeout)

  local ok, cerr = wb:connect(cato.stream_url(conf), {
    ssl_verify = conf.https_verify,
    headers = cato.headers_to_array(cato.build_headers(conf, "output", ctx)),
  })
  if not ok then
    return nil, "ws connect: " .. tostring(cerr)
  end

  -- Send the window shaped like an OpenAI streaming delta, then signal done.
  wb:send_text(cjson.encode({ choices = { { delta = { content = text } } } }))
  wb:send_text(cjson.encode({ done = true }))

  local blocked, message
  while true do
    local data, typ, rerr = wb:recv_frame()
    if not data then
      if rerr and rerr ~= "timeout" then
        err = "ws recv: " .. rerr
        break
      end
    elseif typ == "close" then
      break
    elseif typ == "text" then
      local verdict = cjson.decode(data)
      if verdict then
        if verdict.blocking_message then
          blocked = true
          message = verdict.blocking_message
          break
        elseif verdict.done then
          break
        end
        -- verified_chunk -> allowed; keep reading until done/blocking_message
      end
    end
  end

  pcall(function() wb:send_close() end)
  wb:close()

  if err then
    return nil, err
  end
  return { block = blocked or false, block_message = message }
end


return _M
