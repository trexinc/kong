-- spike-stream-bridge: THROWAWAY spike plugin.
--
-- Validates that a Kong plugin can take over the request in the `access` phase
-- and stream a WebSocket-bridged response to the client, withholding chunks
-- until a Cato Networks verdict clears (and optionally modifies) them.
--
-- This is NOT production code. It exists only to answer the go/no-go question
-- in docs/design/ai-cato-networks-guard-streaming-spike.md. Everything is
-- hardcoded/configurable for manual `curl -N` validation.
--
-- The plugin is STAGED so each risk can be validated in isolation:
--   stage = "static"   -> step 1 (gate): incremental ngx.print/flush, no I/O
--   stage = "upstream" -> step 2: stream an upstream SSE body to the client
--   stage = "ws"       -> step 3: outbound WS round-trip from access
--   stage = "bridge"   -> step 4/5: full duplex hold-back bridge

local http = require "resty.http"
local ws_client = require "resty.websocket.client"
local semaphore = require "ngx.semaphore"
local cjson = require "cjson.safe"

local ngx = ngx
local kong = kong
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local kill = ngx.thread.kill

local SpikeStreamBridge = {
  -- Run very early; we take over the request before anything else proxies.
  PRIORITY = 10000,
  VERSION = "0.0.1",
}


local function sse(event, data)
  -- Minimal SSE framing for the spike.
  return "event: " .. event .. "\ndata: " .. data .. "\n\n"
end


local function begin_stream()
  ngx.status = 200
  ngx.header["Content-Type"] = "text/event-stream"
  ngx.header["Cache-Control"] = "no-cache"
  ngx.header["X-Spike-Bridge"] = "1"
end


-- Returns false if the client has gone away (so callers can tear down).
local function emit(bytes)
  local ok, err = ngx.print(bytes)
  if not ok then
    kong.log.warn("spike: client write failed (disconnect?): ", err)
    return false
  end
  ok, err = ngx.flush(true)
  if not ok then
    kong.log.warn("spike: client flush failed (disconnect?): ", err)
    return false
  end
  return true
end


local function finish()
  ngx.eof()
  return ngx.exit(ngx.HTTP_OK)
end


-- Connect to the upstream SSE source and start the streaming request.
-- Returns res, httpc on success (res.body_reader is ready to pull), or nil, err.
local function connect_upstream(conf)
  local httpc = http.new()
  httpc:set_timeout(conf.recv_timeout_ms)

  local m, err = httpc:parse_uri(conf.upstream_url)
  if not m then
    return nil, "parse upstream_url: " .. tostring(err)
  end
  local scheme, host, port, path, query = m[1], m[2], m[3], m[4], m[5]

  local ok
  ok, err = httpc:connect({ scheme = scheme, host = host, port = port })
  if not ok then
    return nil, "upstream connect: " .. tostring(err)
  end

  local res
  res, err = httpc:request({ path = path, query = query, method = "GET" })
  if not res then
    httpc:close()
    return nil, "upstream request: " .. tostring(err)
  end

  return res, httpc
end


--------------------------------------------------------------------------------
-- stage = "static" : THE GATE. No upstream, no WS. Pure incremental output.
--------------------------------------------------------------------------------
local function run_static(conf)
  begin_stream()
  for i = 1, conf.chunk_count do
    if not emit(sse("chunk", "static chunk " .. i)) then
      return finish()
    end
    ngx.sleep(conf.chunk_delay_ms / 1000)
  end
  emit(sse("done", "[DONE]"))
  return finish()
end


--------------------------------------------------------------------------------
-- stage = "upstream" : stream an upstream SSE body straight to the client.
--------------------------------------------------------------------------------
local function run_upstream(conf)
  local res, httpc = connect_upstream(conf)
  if not res then
    kong.log.err("spike: ", httpc)  -- on failure, second return is the error
    return kong.response.exit(502, { error = tostring(httpc) })
  end

  begin_stream()
  local reader = res.body_reader
  repeat
    local chunk, read_err = reader(65536)
    if read_err then
      kong.log.err("spike: upstream read error: ", read_err)
      break
    end
    if chunk and #chunk > 0 then
      if not emit(chunk) then
        break
      end
    end
  until not chunk

  httpc:close()
  return finish()
end


--------------------------------------------------------------------------------
-- stage = "ws" : prove an outbound WS round-trip works from the access phase.
--------------------------------------------------------------------------------
local function run_ws(conf)
  local wb, err = ws_client:new()
  if not wb then
    return kong.response.exit(500, { error = "ws new: " .. tostring(err) })
  end
  wb:set_timeout(conf.recv_timeout_ms)

  local ok
  ok, err = wb:connect(conf.cato_ws_url)
  if not ok then
    kong.log.err("spike: ws connect failed: ", err)
    return kong.response.exit(502, { error = "ws connect: " .. tostring(err) })
  end

  begin_stream()
  for i = 1, conf.chunk_count do
    local payload = cjson.encode({ type = "data", id = i, data = "ping " .. i })
    local sent, send_err = wb:send_text(payload)
    if not sent then
      kong.log.err("spike: ws send failed: ", send_err)
      break
    end
    local data, typ, recv_err = wb:recv_frame()
    if not data then
      kong.log.err("spike: ws recv failed: ", recv_err)
      break
    end
    if typ == "text" then
      emit(sse("ws-echo", data))
    end
  end

  wb:send_close()
  wb:close()
  emit(sse("done", "[DONE]"))
  return finish()
end


--------------------------------------------------------------------------------
-- stage = "bridge" : full duplex hold-back bridge.
--
-- Two coordinated light threads on a single request, mirroring the
-- reader/writer pattern in kong/clustering/data_plane.lua:
--
--   reader  thread: upstream body_reader -> buffer -> ws:send_text  (WS writer)
--   verdict thread: ws:recv_frame -> decide -> ngx.print            (WS reader,
--                                                                     client writer)
--
-- The client is written ONLY by the verdict thread (single writer). The WS is
-- written ONLY by the reader thread and read ONLY by the verdict thread (one
-- reader, one writer), which is the supported concurrency model.
--
-- Verdict vocabulary (from Cato Networks /analyze/stream, mirrors litellm's
-- async_post_call_streaming_iterator_hook):
--   { type = "verified_chunk", id = N, data = "..." } -> emit (data may be modified)
--   { type = "blocking_message", message = "..." }    -> stop, emit error, end
--   { type = "done" }                                 -> end
--------------------------------------------------------------------------------
local function run_bridge(conf)
  -- 1. Connect upstream LLM (streaming read).
  local res, httpc = connect_upstream(conf)
  if not res then
    kong.log.err("spike: ", httpc)  -- on failure, second return is the error
    return kong.response.exit(502, { error = tostring(httpc) })
  end

  -- 2. Connect Cato Networks WS.
  local wb, err = ws_client:new()
  if not wb then
    return kong.response.exit(500, { error = "ws new: " .. tostring(err) })
  end
  wb:set_timeout(conf.recv_timeout_ms)
  local ok
  ok, err = wb:connect(conf.cato_ws_url)
  if not ok then
    kong.log.err("spike: cato ws connect failed: ", err)
    -- fail_open: stream upstream straight through without guarding.
    if conf.fail_open then
      kong.log.warn("spike: fail_open -> streaming upstream unguarded")
      begin_stream()
      local reader = res.body_reader
      repeat
        local chunk = reader(65536)
        if chunk and #chunk > 0 and not emit(chunk) then break end
      until not chunk
      httpc:close()
      return finish()
    end
    httpc:close()
    return kong.response.exit(502, { error = "guardrail unavailable" })
  end

  begin_stream()

  local stop = semaphore.new(0)   -- posted when the stream must terminate
  local done = false

  -- reader thread: upstream -> WS
  local reader_thread = spawn(function()
    local reader = res.body_reader
    local id = 0
    repeat
      local chunk, read_err = reader(65536)
      if read_err then
        kong.log.err("spike: upstream read error: ", read_err)
        wb:send_text(cjson.encode({ type = "upstream_error" }))
        break
      end
      if chunk and #chunk > 0 then
        id = id + 1
        local sent, send_err = wb:send_text(cjson.encode({
          type = "data", id = id, data = chunk,
        }))
        if not sent then
          kong.log.err("spike: ws send failed: ", send_err)
          break
        end
      end
    until not chunk
    -- Tell Cato no more chunks are coming.
    wb:send_text(cjson.encode({ type = "upstream_done" }))
  end)

  -- verdict thread: WS -> client
  local verdict_thread = spawn(function()
    while not done do
      local data, typ, recv_err = wb:recv_frame()
      if not data then
        if recv_err and recv_err ~= "timeout" then
          kong.log.err("spike: ws recv failed: ", recv_err)
          break
        end
        -- timeout: keep waiting (upstream may be slow)
      elseif typ == "close" then
        break
      elseif typ == "text" then
        local verdict = cjson.decode(data)
        if not verdict then
          kong.log.err("spike: bad verdict json: ", data)
          break
        end

        if verdict.type == "verified_chunk" then
          -- emit possibly-MODIFIED bytes carried by the verdict, not the buffer
          if not emit(verdict.data) then
            break  -- client disconnected
          end

        elseif verdict.type == "blocking_message" then
          emit(sse("blocked", verdict.message or "blocked by guardrail"))
          break

        elseif verdict.type == "done" then
          emit(sse("done", "[DONE]"))
          break
        end
      end
    end
    done = true
    stop:post()
  end)

  -- Terminate when the verdict thread says so (done / blocked / ws closed /
  -- client gone), then tear everything down.
  stop:wait(conf.recv_timeout_ms / 1000 + 5)
  done = true

  kill(reader_thread)
  wait(verdict_thread)

  pcall(function() wb:send_close() end)
  wb:close()
  httpc:close()

  return finish()
end


local STAGES = {
  static   = run_static,
  upstream = run_upstream,
  ws       = run_ws,
  bridge   = run_bridge,
}


function SpikeStreamBridge:access(conf)
  local fn = STAGES[conf.stage]
  if not fn then
    return kong.response.exit(500, { error = "unknown stage: " .. tostring(conf.stage) })
  end
  return fn(conf)
end


-- Marker so we can confirm the log phase still runs after an access-phase
-- takeover (analytics/metrics survival check, plan step 1 & 5).
function SpikeStreamBridge:log(_conf)
  kong.log.notice("spike: log phase ran after access takeover")
end


return SpikeStreamBridge
