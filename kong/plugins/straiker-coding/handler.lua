-- straiker-coding — BUFFERED variant (full enforcement).
--
-- Reconstructs Claude Code hook events from Anthropic/Bedrock wire traffic and enforces
-- at hook parity by posting to /api/v1/detect with x-tool: claude-code — the same backend
-- pipeline the native enforcement hooks use.
--
-- This variant implements :response(), which means Kong buffers the upstream response
-- (kong/runloop/plugins_iterator.lua:521 sets ctx.buffered_proxying = true purely because
-- the handler HAS a `response` field). Buffering is what allows a dangerous tool call to
-- be blocked BEFORE the client executes it — and it is also what costs token streaming
-- (measured: TTFT 0.84s -> 18.7s on a 500-word answer; total time barely changes).
--
-- If you want streaming instead, attach `straiker-coding-stream` to the route: it has no
-- :response() handler, so Kong never buffers. See that plugin for the tradeoff.
--
-- Robustness: all parsing/synthesis runs under pcall so a parser bug fails OPEN.
-- kong.response.exit (the block) is only ever invoked OUTSIDE pcall.
local core = require "kong.plugins.straiker-coding.core"

local StraikerCoding = { PRIORITY = 755, VERSION = core.VERSION }
local LOG = core.LOG

function StraikerCoding:access(conf)
  kong.service.request.set_header("X-Forwarded-Proto", "https")
  kong.service.request.enable_buffering()
  kong.service.request.set_header("Accept-Encoding", "identity")

  local raw = core.read_request_body()
  if not raw then return end

  local ok, events, ctx, err, preq = pcall(core.build_request_events, conf, raw, conf.session_header)
  if not ok then
    kong.log.warn(LOG, " access build error (fail-open): ", tostring(events))
    if conf.log_serialize then core.serialize_request(conf, raw, nil) end
    return
  end
  if not events or not ctx then
    if conf.log_serialize then
      core.serialize_request(conf, raw,
        core.coding.session_id(core.cjson.decode(raw) or {}, kong.request.get_header(conf.session_header)))
    end
    return
  end

  kong.ctx.plugin.sid = ctx.session_id
  kong.ctx.plugin.user = ctx.user_name
  kong.ctx.plugin.streaming = raw:find('"stream"%s*:%s*true') ~= nil
  if conf.log_serialize then core.serialize_request(conf, raw, ctx.session_id) end

  if conf.debug then
    local types = {}
    for _, e in ipairs(events) do types[#types + 1] = e.hook_event_name end
    kong.log.notice(LOG, " access sid=", ctx.session_id, " kind=", preq and preq.kind,
      " n_tools=", preq and preq.n_tools, " tr=", preq and #preq.tool_results,
      " events=[", table.concat(types, ","), "]")
  end

  for _, e in ipairs(events) do
    if core.first_time(ctx.session_id, core.evkey(e), 3600) then
      local ej = core.encode_event(e, ctx, conf)
      local n = e.hook_event_name
      -- Request-side enforcement runs BEFORE the model is called:
      --   UserPromptSubmit -> blocks the whole turn (kill switch / prompt-level block)
      --   PostToolUse      -> stops a poisoned tool result reaching the model
      if conf.mode == "block" and (n == "UserPromptSubmit" or n == "PostToolUse") then
        local blk, reason = core.enforce_decision(conf, e, ej)
        if blk then
          if conf.debug then kong.log.notice(LOG, " BLOCK ", n, " sid=", ctx.session_id) end
          return core.do_block(reason)
        end
      elseif conf.log_serialize then
        core.log_event(e, core.score_sync(conf, ej), ej)
      else
        core.post_async(conf, ej, n, ctx.session_id)
      end
    end
  end
end

local function finalize_response_log()
  kong.log.set_serialize_value("straiker.events", kong.ctx.plugin.log_events or {})
end

function StraikerCoding:response(conf)
  local ctype = kong.response.get_header("Content-Type") or ""

  if conf.log_serialize then
    local craw = kong.response.get_raw_body()
    if craw then
      if core.eventstream.is_eventstream(ctype) then
        kong.log.set_serialize_value("straiker.response_body", ngx.encode_base64(craw))
        kong.log.set_serialize_value("straiker.response_encoding", "base64")
      else
        kong.log.set_serialize_value("straiker.response_body", craw)
        kong.log.set_serialize_value("straiker.response_encoding", "raw")
      end
      kong.log.set_serialize_value("straiker.response_bytes", #craw)
      kong.log.set_serialize_value("straiker.response_content_type", ctype)
    end
  end

  local sid = kong.ctx.plugin.sid
  if not sid then
    if conf.log_serialize then finalize_response_log() end
    return
  end

  local raw = kong.response.get_raw_body()
  if not raw or raw == "" then
    if conf.log_serialize then finalize_response_log() end
    return
  end

  local ok, events, ctx, parsed = pcall(core.build_response_events, conf, raw, ctype, sid, kong.ctx.plugin.user)
  if not ok then
    kong.log.warn(LOG, " response build error (fail-open): ", tostring(events))
    if conf.log_serialize then finalize_response_log() end
    return
  end
  if not events then
    if conf.log_serialize then finalize_response_log() end
    return
  end

  if conf.debug then
    kong.log.notice(LOG, " response sid=", sid, " tool_uses=", parsed and #parsed.tool_uses or 0,
      " stop=", parsed and tostring(parsed.stop_reason))
  end

  for _, e in ipairs(events) do
    local n = e.hook_event_name
    if (n == "PreToolUse" or n == "Stop") and core.first_time(sid, core.evkey(e), 3600) then
      local ej = core.encode_event(e, ctx, conf)
      -- Stop is monitor-only: the answer already exists, so it is scored, never blocked.
      if conf.mode == "block" and n == "PreToolUse" then
        local blk, reason = core.enforce_decision(conf, e, ej)
        if blk then
          if conf.debug then kong.log.notice(LOG, " BLOCK PreToolUse ", e.tool_name, " ", e.tool_use_id) end
          if conf.log_serialize then finalize_response_log() end
          return core.do_block(reason)
        end
      elseif conf.log_serialize then
        core.log_event(e, core.score_sync(conf, ej), ej)
      else
        core.post_async(conf, ej, n, sid)
      end
    end
  end

  if conf.log_serialize then finalize_response_log() end
end

return StraikerCoding
