-- straiker-coding — reconstruct Claude Code hook events from Anthropic/Bedrock
-- wire traffic at the gateway and enforce guardrails at hook parity by posting
-- to /api/v1/detect with x-tool: claude-code (the same backend pipeline the
-- native Claude Code enforcement hooks use).
--
-- Buffered design (access + response): the response is fully buffered so
-- PreToolUse can be scored and, in block mode, the tool call removed before the
-- client executes it.
--
-- Observability: when `log_serialize` is on, the plugin enriches Kong's native
-- log serializer (kong.log.set_serialize_value) with the raw request/response
-- bodies, the resolved session, the synthesized hook events, and the REAL
-- Straiker verdict (scored synchronously so it lands in the same Kong log line).
-- A Kong logging plugin (file-log/http-log) then exports exactly what Kong sees.
--
-- Robustness contract: all parsing/synthesis runs under pcall so a parser bug
-- fails OPEN (traffic passes through untouched) and never 500s the client.
-- kong.response.exit (the block action) is only ever invoked OUTSIDE pcall.
local cjson   = require "cjson.safe"
local coding  = require "kong.plugins.straiker-coding.coding_agent"
local sse     = require "kong.plugins.straiker-coding.sse"
local eventstream = require "kong.plugins.straiker-coding.eventstream"
local detect  = require "kong.plugins.straiker-coding.detect"

local StraikerCoding = { PRIORITY = 755, VERSION = "0.12.0" }
local LOG = "[straiker-coding]"

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function read_request_body()
  ngx.req.read_body()
  local raw = ngx.req.get_body_data()
  if raw then return raw end
  local ok, f = pcall(function() return ngx.req.get_body_file() end)
  if ok and f then
    local fh = io.open(f, "rb")
    if fh then local c = fh:read("*a"); fh:close(); return c end
  end
  return nil
end

-- cross-request dedup (the agentic loop resends the whole transcript each call).
local function first_time(sid, dkey, ttl)
  local dict = ngx.shared.straiker_coding
  if not dict then return true end
  local ok = dict:add(sid .. ":" .. dkey, 1, ttl or 3600)
  return ok and true or false
end

local function evkey(e)
  local n = e.hook_event_name
  if n == "PreToolUse" then return "pre:" .. tostring(e.tool_use_id) end
  if n == "PostToolUse" then return "post:" .. tostring(e.tool_use_id) end
  if n == "UserPromptSubmit" then return "prompt:" .. ngx.md5(e.prompt or "") end
  return n
end

local function resolve_user(conf)
  local h = conf.user_name_header and kong.request.get_header(conf.user_name_header)
  if h and h ~= "" then return h end
  return conf.user_name_default or "kong-coding"
end

local function encode_event(e, ctx, conf)
  e.user_name = ctx.user_name
  e.session_id = ctx.session_id
  if conf.model_override then e.model = conf.model_override end
  return cjson.encode(e)
end

-- fire-and-forget post (monitor, no log_serialize) via a timer — zero latency.
local function post_async(conf, event_json, label, sid)
  local ok = ngx.timer.at(0, function(premature)
    if premature then return end
    local res, err = detect.post(conf, event_json, false)
    if conf.debug then
      if res then
        local turn = (res.body or ""):match('"turn_id"%s*:%s*"([^"]+)"') or "-"
        kong.log.notice(LOG, " recon sid=", sid or "?", " event=", label,
          " status=", res.status, " turn_id=", turn)
      else
        kong.log.warn(LOG, " ", label, " detect error: ", err or "?")
      end
    end
  end)
  if not ok and conf.debug then kong.log.warn(LOG, " timer spawn failed") end
end

-- synchronous scoring (monitor + log): returns the full Straiker verdict so it
-- can be written into the Kong log line. enforce=false => Straiker-Debug on =>
-- response carries score/category/severity/action/turn_id.
local function score_sync(conf, event_json)
  local res, err = detect.post(conf, event_json, false)
  if not res then return { detect_error = err or "unreachable" } end
  local b = cjson.decode(res.body or "") or {}
  return { http = res.status, turn_id = b.turn_id, score = b.score,
           score_category = b.score_category, severity = b.severity,
           action = b.action, reason = b.reason }
end

-- synchronous enforcement (block mode). returns deny?, reason, verdict.
local function post_enforce(conf, event_json)
  local res, err = detect.post(conf, event_json, true)
  if not res then
    if conf.debug then kong.log.warn(LOG, " enforce detect error (fail-open): ", err or "?") end
    return false, nil, { detect_error = err or "unreachable" }
  end
  local body = cjson.decode(res.body or "") or {}
  local hso = body.hookSpecificOutput or {}
  local deny = hso.permissionDecision == "deny"
  return deny, hso.permissionDecisionReason, { http = res.status, decision = hso.permissionDecision }
end

-- Anthropic-shaped block response for a /v1/messages client.
local function anthropic_block_body(reason)
  return cjson.encode({
    id = "msg_blocked", type = "message", role = "assistant", model = "claude",
    stop_reason = "end_turn",
    content = { { type = "text", text = reason } },
    usage = { input_tokens = 0, output_tokens = 0 },
  })
end

-- accumulate one synthesized event for the Kong log serializer:
--   what the plugin synthesized  +  the EXACT payload posted to Straiker  +  the verdict.
local function log_event(e, verdict, payload_json)
  local le = kong.ctx.plugin.log_events
  if not le then le = {}; kong.ctx.plugin.log_events = le end
  le[#le + 1] = {
    hook_event_name = e.hook_event_name,
    tool_name = e.tool_name, tool_input = e.tool_input,
    prompt = e.prompt, tool_use_id = e.tool_use_id,
    detect_payload = payload_json and cjson.decode(payload_json) or nil,  -- exact body POSTed to Straiker
    verdict = verdict,                                                    -- Straiker response
  }
end

-- ---------------------------------------------------------------------------
-- pure builders (pcall-safe: parsing only, no exit, no I/O)
-- ---------------------------------------------------------------------------

local function build_request_events(conf, raw, session_header)
  local body = cjson.decode(raw)
  if type(body) ~= "table" then return nil end
  if conf.agent ~= "off" and not coding.is_claude_code(body) then return nil, nil, "not_cc" end

  local sid = coding.session_id(body, kong.request.get_header(session_header))
  if not sid then return nil, nil, "no_session" end

  local ctx = { session_id = sid, user_name = resolve_user(conf) }
  local preq = coding.parse_request(body, kong.request.get_header(session_header))
  if conf.chatter_filter == false then preq.kind = "turn" end

  local events = coding.to_hook_events(preq, nil, ctx)
  return events, ctx, nil, preq
end

local function build_response_events(conf, raw, ctype, sid, user)
  local parsed
  if eventstream.is_eventstream(ctype) then
    local events = eventstream.decode_events(raw, cjson.decode, ngx.decode_base64)
    local assembled = sse.assemble_events(events, cjson.decode)
    parsed = coding.parse_response(assembled.content, assembled.stop_reason)
  elseif sse.is_sse(ctype) then
    local assembled = sse.assemble(raw, cjson.decode)
    parsed = coding.parse_response(assembled.content, assembled.stop_reason)
  else
    local msg = cjson.decode(raw)
    if type(msg) == "table" and msg.content then
      parsed = coding.parse_response(msg.content, msg.stop_reason)
    end
  end
  if not parsed then return nil end
  local ctx = { session_id = sid, user_name = user, tool_names = {} }
  local events = coding.to_hook_events({ tool_results = {}, kind = "turn" }, parsed, ctx)
  return events, ctx, parsed
end

-- write the request-side serializer fields (bodies + meta) that file-log exports.
local function serialize_request(conf, raw, sid)
  kong.log.set_serialize_value("straiker.request_body", raw)
  kong.log.set_serialize_value("straiker.request_bytes", #raw)
  kong.log.set_serialize_value("straiker.session_id", sid)
  kong.log.set_serialize_value("straiker.plugin", {
    version = StraikerCoding.VERSION, mode = conf.mode, guardrails = "on",
    -- how each synthesized event is sent to Straiker:
    sent_to = conf.detect_url, method = "POST", x_tool = conf.x_tool,
    signing = conf.sign_payloads and "HMAC-SHA256 over {timestamp}.{payload}" or "none",
  })
end

-- ---------------------------------------------------------------------------
-- access: request-side events (PostToolUse, UserPromptSubmit)
-- ---------------------------------------------------------------------------

function StraikerCoding:access(conf)
  kong.service.request.set_header("X-Forwarded-Proto", "https")
  kong.service.request.enable_buffering()
  kong.service.request.set_header("Accept-Encoding", "identity")

  local raw = read_request_body()
  if not raw then return end

  local ok, events, ctx, err, preq = pcall(build_request_events, conf, raw, conf.session_header)
  if not ok then
    kong.log.warn(LOG, " access build error (fail-open): ", tostring(events))
    if conf.log_serialize then serialize_request(conf, raw, nil) end
    return
  end
  if not events or not ctx then
    -- utility/title-gen or non-CC: still log the raw request Kong saw
    if conf.log_serialize then
      serialize_request(conf, raw, coding.session_id(cjson.decode(raw) or {}, kong.request.get_header(conf.session_header)))
    end
    return
  end

  kong.ctx.plugin.sid = ctx.session_id
  kong.ctx.plugin.user = ctx.user_name
  if conf.log_serialize then serialize_request(conf, raw, ctx.session_id) end

  if conf.debug then
    local types = {}
    for _, e in ipairs(events) do types[#types + 1] = e.hook_event_name end
    kong.log.notice(LOG, " access sid=", ctx.session_id, " kind=", preq and preq.kind,
      " n_tools=", preq and preq.n_tools, " tr=", preq and #preq.tool_results,
      " events=[", table.concat(types, ","), "]")
  end

  for _, e in ipairs(events) do
    if first_time(ctx.session_id, evkey(e), 3600) then
      local ej = encode_event(e, ctx, conf)
      if conf.mode == "block" and e.hook_event_name == "PostToolUse" then
        local deny, reason, verdict = post_enforce(conf, ej)
        if conf.log_serialize then log_event(e, verdict, ej) end
        if deny then
          if conf.debug then kong.log.notice(LOG, " BLOCK PostToolUse ", e.tool_use_id) end
          return kong.response.exit(200, anthropic_block_body(reason),
            { ["Content-Type"] = "application/json" })
        end
      elseif conf.log_serialize then
        log_event(e, score_sync(conf, ej), ej)      -- sync score -> verdict in the log
      else
        post_async(conf, ej, e.hook_event_name, ctx.session_id)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- response: response-side events (PreToolUse from the model's tool_use)
-- ---------------------------------------------------------------------------

local function finalize_response_log()
  kong.log.set_serialize_value("straiker.events", kong.ctx.plugin.log_events or {})
end

function StraikerCoding:response(conf)
  local ctype = kong.response.get_header("Content-Type") or ""

  -- log the raw response Kong returned for EVERY call on the route (incl. the
  -- title-gen utility call the plugin doesn't score).
  if conf.log_serialize then
    local craw = kong.response.get_raw_body()
    if craw then
      if eventstream.is_eventstream(ctype) then
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

  local ok, events, ctx, parsed = pcall(build_response_events, conf, raw, ctype, sid, kong.ctx.plugin.user)
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
    if e.hook_event_name == "PreToolUse" and first_time(sid, evkey(e), 3600) then
      local ej = encode_event(e, ctx, conf)
      if conf.mode == "block" then
        local deny, reason, verdict = post_enforce(conf, ej)
        if conf.log_serialize then log_event(e, verdict, ej) end
        if deny then
          if conf.debug then kong.log.notice(LOG, " BLOCK PreToolUse ", e.tool_name, " ", e.tool_use_id) end
          return kong.response.exit(200, anthropic_block_body(reason),
            { ["Content-Type"] = "application/json" })
        end
      elseif conf.log_serialize then
        log_event(e, score_sync(conf, ej), ej)
      else
        post_async(conf, ej, "PreToolUse", sid)
      end
    end
  end

  if conf.log_serialize then finalize_response_log() end
end

return StraikerCoding
