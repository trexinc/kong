-- Streaming response guard: duplex WebSocket bridge between the upstream LLM
-- SSE stream and the Cato Networks firewall, run from the access phase (the
-- only phase where cosockets are available).
--
-- Two coordinated light threads on a single request, mirroring the
-- reader/writer pattern in kong/clustering/data_plane.lua:
--   reader  thread: upstream SSE chunk -> firewall WS        (WS writer)
--   verdict thread: firewall WS verdict -> client (ngx.print) (WS reader,
--                                                              client writer)
-- The client is written only by the verdict thread (single writer); the WS is
-- written only by the reader thread and read only by the verdict thread.
--
-- Firewall verdicts (LiteLLMResponseStreamResponse):
--   { verified_chunk = {...} }                 -> emit framed SSE to client
--   { blocking_message = "...",
--     first_blocked_chunk = {...} }            -> emit replacement + stop
--   { done = true }                            -> end
local ws_client = require("resty.websocket.client")
local semaphore = require("ngx.semaphore")
local cjson     = require("cjson.safe")
local cato      = require("kong.plugins.ai-cato-networks-guard.cato_client")

local ngx   = ngx
local kong  = kong
local spawn = ngx.thread.spawn
local wait  = ngx.thread.wait
local kill  = ngx.thread.kill

local _M = {}


local function emit(bytes)
  local ok, err = ngx.print(bytes)
  if not ok then
    kong.log.warn("ai-cato-networks-guard: client write failed: ", err)
    return false
  end
  ok, err = ngx.flush(true)
  if not ok then
    kong.log.warn("ai-cato-networks-guard: client flush failed: ", err)
    return false
  end
  return true
end


local function frame(chunk_table)
  local encoded = cjson.encode(chunk_table)
  if not encoded then
    return nil
  end
  return "data: " .. encoded .. "\n\n"
end


-- Pull complete SSE events ("...\n\n") out of an accumulating buffer.
-- Returns the list of event bodies found and the unconsumed remainder.
local function take_events(buffer)
  local events = {}
  while true do
    local s, e = buffer:find("\n\n", 1, true)
    if not s then
      break
    end
    events[#events + 1] = buffer:sub(1, s - 1)
    buffer = buffer:sub(e + 1)
  end
  return events, buffer
end


-- Extract the `data:` payload from an SSE event body, or nil if none.
local function sse_data(event)
  local payload = event:match("data:%s?(.*)")
  return payload
end


-- conf, ctx: plugin config and forwarded request context
-- upstream_res, upstream_httpc: the in-flight upstream SSE response + its client
function _M.run(conf, ctx, upstream_res, upstream_httpc)
  local headers = cato.build_headers(conf, "output", ctx)

  local wb, err = ws_client:new()
  if not wb then
    upstream_httpc:close()
    return kong.response.exit(500, { error = { message = "ws client: " .. tostring(err) } })
  end
  wb:set_timeout(conf.http_timeout)

  local ok
  ok, err = wb:connect(cato.stream_url(conf), {
    ssl_verify = conf.https_verify,
    headers = cato.headers_to_array(headers),
  })
  if not ok then
    kong.log.err("ai-cato-networks-guard: firewall ws connect failed: ", err)
    if conf.fail_open then
      -- Stream the upstream straight through, unguarded.
      ngx.status = upstream_res.status
      ngx.header["Content-Type"] = upstream_res.headers["Content-Type"]
      local reader = upstream_res.body_reader
      repeat
        local chunk = reader(65536)
        if chunk and #chunk > 0 and not emit(chunk) then break end
      until not chunk
      upstream_httpc:close()
      ngx.eof()
      return ngx.exit(ngx.HTTP_OK)
    end
    upstream_httpc:close()
    return kong.response.exit(502, { error = { message = "guardrail unavailable" } })
  end

  ngx.status = upstream_res.status
  ngx.header["Content-Type"] = upstream_res.headers["Content-Type"] or "text/event-stream"
  ngx.header["Cache-Control"] = "no-cache"

  local stop = semaphore.new(0)
  local done = false

  -- reader thread: upstream SSE -> firewall WS
  local reader_thread = spawn(function()
    local reader = upstream_res.body_reader
    local buffer = ""
    repeat
      local chunk, read_err = reader(65536)
      if read_err then
        kong.log.err("ai-cato-networks-guard: upstream read error: ", read_err)
        break
      end
      if chunk and #chunk > 0 then
        buffer = buffer .. chunk
        local events
        events, buffer = take_events(buffer)
        for _, event in ipairs(events) do
          local payload = sse_data(event)
          if payload then
            if payload == "[DONE]" then
              wb:send_text(cjson.encode({ done = true }))
            else
              local sent, send_err = wb:send_text(payload)
              if not sent then
                kong.log.err("ai-cato-networks-guard: ws send failed: ", send_err)
                return
              end
            end
          end
        end
      end
    until not chunk
    -- Upstream ended without an explicit [DONE]; tell the firewall anyway.
    wb:send_text(cjson.encode({ done = true }))
  end)

  -- verdict thread: firewall WS -> client
  local verdict_thread = spawn(function()
    while not done do
      local data, typ, recv_err = wb:recv_frame()
      if not data then
        if recv_err and recv_err ~= "timeout" then
          kong.log.err("ai-cato-networks-guard: ws recv failed: ", recv_err)
          break
        end
      elseif typ == "close" then
        break
      elseif typ == "text" then
        local verdict = cjson.decode(data)
        if not verdict then
          kong.log.err("ai-cato-networks-guard: bad verdict json")
          break
        end

        if verdict.verified_chunk then
          local framed = frame(verdict.verified_chunk)
          if framed and not emit(framed) then
            break  -- client disconnected
          end

        elseif verdict.blocking_message then
          kong.log.info("ai-cato-networks-guard: response blocked: ", verdict.blocking_message)
          if verdict.first_blocked_chunk then
            emit(frame(verdict.first_blocked_chunk) or "")
          end
          emit("data: [DONE]\n\n")
          break

        elseif verdict.done then
          emit("data: [DONE]\n\n")
          break
        end
      end
    end
    done = true
    stop:post()
  end)

  stop:wait(conf.http_timeout / 1000 + 5)
  done = true

  kill(reader_thread)
  wait(verdict_thread)

  pcall(function() wb:send_close() end)
  wb:close()
  upstream_httpc:close()

  ngx.eof()
  return ngx.exit(ngx.HTTP_OK)
end


return _M
