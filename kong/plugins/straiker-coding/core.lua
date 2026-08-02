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

local M = {}
M.VERSION = "0.18.0"
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
--
-- FAILURE SEMANTICS MATTER HERE. dict:add returns (ok, err, forcible):
--   err == "exists"    -> genuine duplicate, suppress (the point of this function)
--   err == "no memory" -> the dict is FULL. Previously this returned false, i.e. the
--                         event was silently skipped: not scored, not blocked, not
--                         logged. Under load that is silent loss of enforcement.
--                         We now fail toward EMITTING (duplicate telemetry is a far
--                         better failure than an unscored tool call) and warn.
--   forcible == true   -> an entry was LRU-evicted to make room; capacity is short.
local dict_warned = 0
local function first_time(sid, dkey, ttl, scope)
  if scope == "none" then return true end
  local dict = ngx.shared.straiker_coding
  if not dict then
    -- no dict declared: every event is re-scored on every call. Warn once per worker
    -- rather than silently degrading (KONG_NGINX_HTTP_LUA_SHARED_DICT is required).
    if dict_warned == 0 then
      dict_warned = 1
      kong.log.err(LOG, " shared dict 'straiker_coding' is NOT declared — dedup disabled, ",
        "every event will be re-scored on every request. Set ",
        "KONG_NGINX_HTTP_LUA_SHARED_DICT='straiker_coding 32m'")
    end
    return true
  end
  local ok, err, forcible = dict:add(sid .. ":" .. dkey, 1, ttl or 3600)
  if ok then
    if forcible then
      local now = ngx.time()
      if now - dict_warned > 60 then      -- rate-limit: this can fire per request
        dict_warned = now
        kong.log.warn(LOG, " dedup dict is evicting entries (capacity pressure); ",
          "free=", dict:free_space(), " — consider raising straiker_coding size")
      end
    end
    return true
  end
  if err == "exists" then return false end       -- genuine duplicate
  -- anything else (notably "no memory"): emit rather than silently drop the event
  kong.log.warn(LOG, " dedup dict add failed (", tostring(err), ") — emitting anyway to ",
    "avoid silent loss of enforcement")
  return true
end

local function evkey(e)
  local n = e.hook_event_name
  if n == "PreToolUse" then return "pre:" .. tostring(e.tool_use_id) end
  if n == "PostToolUse" then return "post:" .. tostring(e.tool_use_id) end
  if n == "UserPromptSubmit" then return "prompt:" .. ngx.md5(e.prompt or "") end
  if n == "Stop" then return "stop:" .. ngx.md5(e.app_response or "") end
  return n
end

local function resolve_user(conf)
  -- 1) an authenticated Kong consumer (e.g. key-auth on the shared gateway) IS the identity
  local get_consumer = kong.client and kong.client.get_consumer
  local consumer = get_consumer and get_consumer()
  if consumer and consumer.username and consumer.username ~= "" then return consumer.username end
  -- 2) else an identity header the client injects (local toggle: X-Straiker-User-Name)
  local h = conf.user_name_header and kong.request.get_header(conf.user_name_header)
  if h and h ~= "" then return h end
  -- 3) else the configured default
  return conf.user_name_default or "kong-coding"
end

local function encode_event(e, ctx, conf)
  e.user_name = ctx.user_name
  e.session_id = ctx.session_id
  if conf.model_override then e.model = conf.model_override end
  -- cjson.safe returns nil (not a throw) on encode failure. Callers MUST nil-check:
  -- a nil payload reaching detect.post() makes sign() do ts .. "." .. nil, which throws
  -- OUTSIDE any pcall in the access phase and 500s the client — the exact opposite of
  -- the documented fail-open contract.
  local out, err = cjson.encode(e)
  if not out then
    kong.log.warn(LOG, " event encode failed (skipping event): ", tostring(err))
    return nil
  end
  return out
end

-- fire-and-forget post (monitor, no log_serialize) via a timer — zero latency.
local function post_async(conf, event_json, label, sid)
  local ok = ngx.timer.at(0, function(premature)
    if premature then return end
    local res, err = detect.post(conf, event_json, false)
    -- Failures are logged UNCONDITIONALLY. The recommended first-enable posture is
    -- monitor + debug:false, under which a rotated key (401), a 400, a timeout or a DNS
    -- failure previously produced NO log line at all — the Console simply went quiet
    -- while the gateway looked healthy.
    if not res then
      kong.log.warn(LOG, " ", label, " detect FAILED sid=", sid or "?", " err=", err or "?")
    elseif res.status and res.status >= 300 then
      kong.log.warn(LOG, " ", label, " detect non-2xx sid=", sid or "?",
        " status=", res.status, " body=", (res.body or ""):sub(1, 160))
    elseif conf.debug then
      local turn = (res.body or ""):match('"turn_id"%s*:%s*"([^"]+)"') or "-"
      kong.log.notice(LOG, " recon sid=", sid or "?", " event=", label,
        " status=", res.status, " turn_id=", turn)
    end
  end)
  if not ok then
    kong.log.err(LOG, " timer spawn FAILED for ", label, " sid=", sid or "?",
      " — event dropped (lua_max_running_timers?)")
  end
end

-- synchronous scoring (monitor + log): returns the full Straiker verdict so it
-- can be written into the Kong log line. enforce=false => Straiker-Debug on =>
-- response carries score/category/severity/action/turn_id.
local function score_sync(conf, event_json)
  local res, err = detect.post(conf, event_json, false)
  if not res then
    kong.log.warn(LOG, " score_sync detect FAILED err=", err or "?")
    return { detect_error = err or "unreachable" }
  end
  if res.status and res.status >= 300 then
    kong.log.warn(LOG, " score_sync non-2xx status=", res.status,
      " body=", (res.body or ""):sub(1, 160))
  end
  local b = cjson.decode(res.body or "") or {}
  return { http = res.status, turn_id = b.turn_id, score = b.score,
           score_category = b.score_category, severity = b.severity,
           action = b.action, reason = b.reason }
end

-- (Block decisions live in enforce_decision(), defined below after log_event/do_block.
--  We intentionally block on Straiker's action=="block" — the actual decision — rather
--  than the hookSpecificOutput deny signal, which the enforce path omits for
--  UserPromptSubmit. See the note on enforce_decision.)

-- Anthropic-shaped block response for a NON-streaming /v1/messages client.
local function anthropic_block_body(reason)
  return cjson.encode({
    id = "msg_blocked", type = "message", role = "assistant", model = "claude",
    stop_reason = "end_turn",
    content = { { type = "text", text = reason } },
    usage = { input_tokens = 0, output_tokens = 0 },
  })
end

-- Anthropic-shaped block response for a STREAMING (stream:true) client: a complete,
-- well-formed SSE message so Claude Code renders the block as the assistant's answer
-- and ENDS the turn — rather than seeing a malformed/JSON body, discarding it, and
-- continuing (which is what let blocked turns "keep talking").
local function anthropic_block_sse(reason)
  local function ev(name, data) return "event: " .. name .. "\ndata: " .. cjson.encode(data) .. "\n\n" end
  return table.concat({
    ev("message_start", { type = "message_start", message = {
        id = "msg_blocked", type = "message", role = "assistant", model = "claude",
        content = cjson.empty_array, stop_reason = cjson.null, stop_sequence = cjson.null,
        usage = { input_tokens = 0, output_tokens = 0 } } }),
    ev("content_block_start", { type = "content_block_start", index = 0,
        content_block = { type = "text", text = "" } }),
    ev("content_block_delta", { type = "content_block_delta", index = 0,
        delta = { type = "text_delta", text = reason } }),
    ev("content_block_stop", { type = "content_block_stop", index = 0 }),
    ev("message_delta", { type = "message_delta",
        delta = { stop_reason = "end_turn", stop_sequence = cjson.null }, usage = { output_tokens = 0 } }),
    ev("message_stop", { type = "message_stop" }),
  })
end

-- Terminate the request with a block the client will actually render. Streaming vs
-- non-streaming is stashed in access from the request's `stream` flag.
local function do_block(reason)
  -- Straiker may return reason=null (-> cjson.null userdata, which is TRUTHY in Lua) or
  -- an empty string; a null/empty text_delta makes Claude Code render nothing. Guard on
  -- the actual type so the block always carries readable text.
  if type(reason) ~= "string" or reason == "" then
    reason = "Request blocked by Straiker guardrails."
  end
  if kong.ctx.plugin.streaming then
    return kong.response.exit(200, anthropic_block_sse(reason), { ["Content-Type"] = "text/event-stream" })
  end
  return kong.response.exit(200, anthropic_block_body(reason), { ["Content-Type"] = "application/json" })
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

-- Enforcement decision. Score the event on the scoring path (score_sync) and BLOCK
-- whenever Straiker's decision is action=="block" — regardless of category, severity,
-- or which field carries it. This is deliberately broader than the enforce path's
-- hookSpecificOutput deny: the backend gates non-tool events out of the enforce
-- response (returns {} for UserPromptSubmit before `action` is even consulted —
-- argus helpers.py), so the enforce contract silently passes prompt-only turns and the
-- kill switch. The gateway can see the actual decision (action=block, which the kill
-- switch sets on EVERY event) and act on it — something the native hook handler, which
-- only reads hookSpecificOutput.permissionDecision, structurally cannot do.
-- Returns (should_block, reason). Honors fail_open on a detect error.
local function enforce_decision(conf, e, ej)
  if type(ej) ~= "string" then
    -- nothing to score; fail open (or closed if configured) rather than throwing
    return (conf.fail_open == false), "Straiker guardrail could not encode the event."
  end
  local verdict = score_sync(conf, ej)
  if conf.log_serialize then log_event(e, verdict, ej) end
  if verdict.detect_error then
    return (conf.fail_open == false), "Straiker guardrail unavailable (fail-closed)."
  end
  if verdict.action == "block" then
    return true, verdict.reason or "Request blocked by Straiker guardrails."
  end
  return false
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
    parsed = coding.parse_response(assembled.content, assembled.stop_reason, assembled)
  elseif sse.is_sse(ctype) then
    local assembled = sse.assemble(raw, cjson.decode)
    parsed = coding.parse_response(assembled.content, assembled.stop_reason, assembled)
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
    version = M.VERSION, mode = conf.mode, guardrails = "on",
    -- how each synthesized event is sent to Straiker:
    sent_to = conf.detect_url, method = "POST", x_tool = conf.x_tool,
    signing = conf.sign_payloads and "HMAC-SHA256 over {timestamp}.{payload}" or "none",
  })
end


-- exported for the phase handlers (straiker-coding = buffered, -stream = streaming)
M.read_request_body   = read_request_body
M.first_time          = first_time
M.evkey               = evkey
M.encode_event        = encode_event
M.post_async          = post_async
M.score_sync          = score_sync
M.do_block            = do_block
M.log_event           = log_event
M.enforce_decision    = enforce_decision
M.build_request_events  = build_request_events
M.build_response_events = build_response_events
M.serialize_request   = serialize_request
M.coding              = coding
M.eventstream         = eventstream
M.cjson               = cjson
M.LOG                 = LOG
-- raw detect POST for the streaming variant's timer (already off the request path,
-- so it calls detect directly rather than spawning another timer)
M.detect_post         = function(conf, ej) return detect.post(conf, ej, false) end

return M
