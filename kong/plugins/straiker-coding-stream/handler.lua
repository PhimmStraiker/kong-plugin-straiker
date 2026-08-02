-- straiker-coding-stream — STREAMING variant.
--
-- Same guardrail, same hook events, same Straiker pipeline as `straiker-coding`. The only
-- difference is which Kong phases it implements, and that difference is what preserves
-- token streaming.
--
-- WHY A SEPARATE PLUGIN INSTEAD OF A CONFIG FLAG
-- Kong decides response buffering from the mere EXISTENCE of a `response` field on the
-- handler table, in the plugin iterator, before any plugin code runs:
--     kong/runloop/plugins_iterator.lua:521
--     if phase == "response" and not ctx.buffered_proxying then ctx.buffered_proxying = true
-- A runtime `if conf.x then return end` inside :response() is far too late — buffering is
-- already on. (Verified: a config-flag attempt still measured 19.6s TTFT on a control
-- plane with no other plugins.) So the streaming variant simply has no :response().
--
-- WHAT YOU GET / GIVE UP vs straiker-coding
--   keeps   native token streaming (~0.8s to first token instead of ~19s)
--   keeps   UserPromptSubmit enforcement — the kill switch and prompt-level blocks still
--           deny the turn before the model is ever called (access phase, pre-upstream)
--   keeps   PostToolUse enforcement — a poisoned tool result is still blocked from
--           reaching the model (also request-side)
--   keeps   full PreToolUse + Stop telemetry in the Console
--   LOSES   pre-execution blocking of a tool call. Response-side events are reported
--           after the fact, so a dangerous tool call is recorded, not prevented.
--
-- HOW THE RESPONSE IS PROCESSED WITHOUT BUFFERING
-- OpenResty forbids yielding APIs (cosockets, sleep) in body_filter, so the Straiker call
-- cannot happen there. Instead: body_filter accumulates chunks (pure Lua, no yielding),
-- and the log phase hands the assembled body to an ngx.timer, which CAN use cosockets and
-- posts the events asynchronously — off the request path entirely, so it costs the user
-- nothing.
local core = require "kong.plugins.straiker-coding.core"

local StraikerCodingStream = { PRIORITY = 755, VERSION = core.VERSION }
local LOG = "[straiker-coding-stream]"

-- Cap accumulation so a pathological response can't grow a worker unbounded. Beyond the
-- cap we stop collecting and skip response telemetry for that turn (traffic is unaffected).
local MAX_ACCUM = 8 * 1024 * 1024

function StraikerCodingStream:access(conf)
  kong.service.request.set_header("X-Forwarded-Proto", "https")
  -- NO enable_buffering() and NO Accept-Encoding override: the response streams through
  -- untouched, which is the entire point of this variant.

  local raw = core.read_request_body()
  if not raw then return end

  local ok, events, ctx, err, preq = pcall(core.build_request_events, conf, raw, conf.session_header)
  if not ok then
    kong.log.warn(LOG, " access build error (fail-open): ", tostring(events))
    return
  end
  if not events or not ctx then return end

  kong.ctx.plugin.sid = ctx.session_id
  kong.ctx.plugin.user = ctx.user_name
  kong.ctx.plugin.streaming = raw:find('"stream"%s*:%s*true') ~= nil

  if conf.debug then
    local types = {}
    for _, e in ipairs(events) do types[#types + 1] = e.hook_event_name end
    kong.log.notice(LOG, " access sid=", ctx.session_id, " kind=", preq and preq.kind,
      " events=[", table.concat(types, ","), "]")
  end

  -- Request-side enforcement is unchanged and still fully blocking.
  for _, e in ipairs(events) do
    if core.first_time(ctx.session_id, core.evkey(e), 3600) then
      local ej = core.encode_event(e, ctx, conf)
      local n = e.hook_event_name
      if conf.mode == "block" and (n == "UserPromptSubmit" or n == "PostToolUse") then
        local blk, reason = core.enforce_decision(conf, e, ej)
        if blk then
          if conf.debug then kong.log.notice(LOG, " BLOCK ", n, " sid=", ctx.session_id) end
          return core.do_block(reason)
        end
      else
        core.post_async(conf, ej, n, ctx.session_id)
      end
    end
  end
end

function StraikerCodingStream:header_filter(conf)
  -- Content-Type is needed to pick the decoder later, and kong.response is not available
  -- inside the timer, so capture it now.
  kong.ctx.plugin.ctype = kong.response.get_header("Content-Type") or ""
end

function StraikerCodingStream:body_filter(conf)
  local P = kong.ctx.plugin
  if not P.sid or P.accum_over then return end

  -- Pure accumulation only. No cosockets, no sleep, no yielding — all forbidden here.
  local chunk = ngx.arg[1]
  if chunk and chunk ~= "" then
    local buf = P.rbuf
    if not buf then buf = {}; P.rbuf = buf; P.rlen = 0 end
    P.rlen = P.rlen + #chunk
    if P.rlen > MAX_ACCUM then
      P.accum_over = true
      P.rbuf = nil
      kong.log.warn(LOG, " response exceeded ", MAX_ACCUM, " bytes; skipping response telemetry")
      return
    end
    buf[#buf + 1] = chunk
  end
end

function StraikerCodingStream:log(conf)
  local P = kong.ctx.plugin
  local sid, buf = P.sid, P.rbuf
  if not sid or not buf then return end

  -- Capture by value: the request context is gone by the time the timer runs.
  local raw   = table.concat(buf)
  local ctype = P.ctype or ""
  local user  = P.user
  if raw == "" then return end

  -- Timers CAN use cosockets, so the Straiker posts happen here — asynchronously, off
  -- the request path. Response-side events are therefore monitor-only by construction.
  local ok = ngx.timer.at(0, function(premature)
    if premature then return end
    local built, events, ctx, parsed = pcall(core.build_response_events, conf, raw, ctype, sid, user)
    if not built then
      kong.log.warn(LOG, " response build error (fail-open): ", tostring(events))
      return
    end
    if not events then return end

    if conf.debug then
      kong.log.notice(LOG, " stream-log sid=", sid, " tool_uses=", parsed and #parsed.tool_uses or 0,
        " stop=", parsed and tostring(parsed.stop_reason))
    end

    for _, e in ipairs(events) do
      local n = e.hook_event_name
      if (n == "PreToolUse" or n == "Stop") and core.first_time(sid, core.evkey(e), 3600) then
        local ej = core.encode_event(e, ctx, conf)
        if ej then
          local res, perr = core.detect_post(conf, ej)
          if conf.debug then
            kong.log.notice(LOG, " posted ", n, " sid=", sid,
              " status=", res and res.status or ("err:" .. tostring(perr)))
          end
        end
      end
    end
  end)
  if not ok then kong.log.warn(LOG, " timer spawn failed; response telemetry dropped for sid=", sid) end
end

return StraikerCodingStream
