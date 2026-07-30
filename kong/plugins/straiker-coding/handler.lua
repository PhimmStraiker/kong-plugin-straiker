-- straiker-coding — reconstruct Claude Code hook events from Anthropic/Bedrock
-- wire traffic at the gateway and enforce guardrails at hook parity by posting
-- to /api/v1/detect with x-tool: claude-code (the same backend pipeline the
-- native Claude Code enforcement hooks use).
--
-- Buffered design (access + response): the response is fully buffered so
-- PreToolUse can be scored and, in block mode, the tool call removed before the
-- client executes it. A streaming-hold variant (preserves token streaming) is
-- tracked separately — see docs/latency-analysis.md.
--
-- Robustness contract: all parsing/synthesis runs under pcall so a parser bug
-- fails OPEN (traffic passes through untouched) and never 500s the developer.
-- kong.response.exit (the block action) is only ever invoked OUTSIDE pcall.
local cjson   = require "cjson.safe"
local coding  = require "kong.plugins.straiker-coding.coding_agent"
local sse     = require "kong.plugins.straiker-coding.sse"
local eventstream = require "kong.plugins.straiker-coding.eventstream"
local detect  = require "kong.plugins.straiker-coding.detect"

local StraikerCoding = { PRIORITY = 755, VERSION = "0.11.0" }
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

-- fire-and-forget post (monitor mode) via a light timer — zero added latency.
-- Logs "recon" lines carrying session_id + event + turn_id so the same message
-- can be reconciled between Kong (this log / the X-Straiker-Session-Id header)
-- and the Straiker Console (the turn's session_id).
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

-- synchronous post returning deny?, reason (block mode)
local function post_enforce(conf, event_json)
  local res, err = detect.post(conf, event_json, true)
  if not res then
    if conf.debug then kong.log.warn(LOG, " enforce detect error (fail-open): ", err or "?") end
    return false
  end
  local body = cjson.decode(res.body or "") or {}
  local hso = body.hookSpecificOutput or {}
  if hso.permissionDecision == "deny" then
    return true, hso.permissionDecisionReason or "Blocked by Straiker policy"
  end
  return false
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

-- ---------------------------------------------------------------------------
-- pure builders (pcall-safe: parsing only, no exit, no I/O)
-- ---------------------------------------------------------------------------

-- returns events, ctx  (request-side: PostToolUse, UserPromptSubmit)
local function build_request_events(conf, raw, session_header)
  local body = cjson.decode(raw)
  if type(body) ~= "table" then return nil end
  if conf.agent ~= "off" and not coding.is_claude_code(body) then return nil end

  local sid = coding.session_id(body, kong.request.get_header(session_header))
  if not sid then return nil, nil, "no_session" end

  local ctx = { session_id = sid, user_name = resolve_user(conf) }
  local preq = coding.parse_request(body, kong.request.get_header(session_header))
  if conf.chatter_filter == false then preq.kind = "turn" end

  local events = coding.to_hook_events(preq, nil, ctx)
  return events, ctx, nil, preq
end

-- returns events, ctx (response-side: PreToolUse)
local function build_response_events(conf, raw, ctype, sid, user)
  local parsed
  if eventstream.is_eventstream(ctype) then
    -- Bedrock InvokeModelWithResponseStream: unwrap binary frames -> Anthropic events
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

-- ---------------------------------------------------------------------------
-- access: request-side events
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
    return
  end
  if not events or not ctx then
    if conf.debug and err == "no_session" then kong.log.notice(LOG, " access: no session_id, skip") end
    return
  end

  kong.ctx.plugin.sid = ctx.session_id
  kong.ctx.plugin.user = ctx.user_name

  if conf.debug then
    local types = {}
    for _, e in ipairs(events) do types[#types + 1] = e.hook_event_name end
    kong.log.notice(LOG, " access sid=", ctx.session_id, " kind=", preq and preq.kind,
      " n_tools=", preq and preq.n_tools, " prompt=", (preq and preq.user_prompt or ""):sub(1, 40),
      " tr=", preq and #preq.tool_results, " events=[", table.concat(types, ","), "]")
  end

  for _, e in ipairs(events) do
    if first_time(ctx.session_id, evkey(e), 3600) then
      local ej = encode_event(e, ctx, conf)
      if conf.mode == "block" and e.hook_event_name == "PostToolUse" then
        local deny, reason = post_enforce(conf, ej)
        if deny then
          if conf.debug then kong.log.notice(LOG, " BLOCK PostToolUse ", e.tool_use_id) end
          return kong.response.exit(200, anthropic_block_body(reason),
            { ["Content-Type"] = "application/json" })
        end
      else
        post_async(conf, ej, e.hook_event_name, ctx.session_id)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- response: response-side events (PreToolUse from the model's tool_use)
-- ---------------------------------------------------------------------------

function StraikerCoding:response(conf)
  local sid = kong.ctx.plugin.sid
  if not sid then return end

  local raw = kong.response.get_raw_body()
  local ctype = kong.response.get_header("Content-Type") or ""
  if not raw or raw == "" then return end

  local ok, events, ctx, parsed = pcall(build_response_events, conf, raw, ctype, sid, kong.ctx.plugin.user)
  if not ok then
    kong.log.warn(LOG, " response build error (fail-open): ", tostring(events))
    return
  end
  if not events then return end

  if conf.debug then
    kong.log.notice(LOG, " response sid=", sid, " sse=", tostring(sse.is_sse(ctype)),
      " tool_uses=", parsed and #parsed.tool_uses or 0, " stop=", parsed and tostring(parsed.stop_reason))
  end

  for _, e in ipairs(events) do
    if e.hook_event_name == "PreToolUse" and first_time(sid, evkey(e), 3600) then
      local ej = encode_event(e, ctx, conf)
      if conf.mode == "block" then
        local deny, reason = post_enforce(conf, ej)
        if deny then
          if conf.debug then kong.log.notice(LOG, " BLOCK PreToolUse ", e.tool_name, " ", e.tool_use_id) end
          return kong.response.exit(200, anthropic_block_body(reason),
            { ["Content-Type"] = "application/json" })
        end
      else
        post_async(conf, ej, "PreToolUse", sid)
      end
    end
  end
end

return StraikerCoding
