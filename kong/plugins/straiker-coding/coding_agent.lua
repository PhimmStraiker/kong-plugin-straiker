-- coding_agent.lua — reconstruct Claude Code hook events from wire traffic.
--
-- Pure Lua, no Kong/ngx dependencies, so it is unit-testable offline. Operates
-- on already-decoded request/response tables (the handler does the cjson decode).
-- Handles BOTH shapes seen on the wire:
--   * structured Anthropic /v1/messages: content is an array of typed blocks
--     (text / tool_use / tool_result), plus top-level system + tools.
--   * flattened gateway view (what CVS's Kong logs show): the whole user turn
--     collapsed into one string with <system-reminder>/<command-*> scaffolding
--     and the real prompt trailing at the end.
--
-- The output is a list of hook-shaped events matching the native Claude Code
-- handler contract (hook_event_name / tool_name / tool_input / session_id / ...),
-- ready to POST to /api/v1/detect with x-tool: claude-code.

local M = {}

-- ---------------------------------------------------------------------------
-- scaffolding + chatter
-- ---------------------------------------------------------------------------

-- Lua patterns for the wrappers Claude Code injects into user content.
local SCAFFOLD = {
  "<system%-reminder>.-</system%-reminder>",
  "<command%-message>.-</command%-message>",
  "<command%-name>.-</command%-name>",
  "<command%-args>.-</command%-args>",
  "<local%-command%-stdout>.-</local%-command%-stdout>",
  "<local%-command%-caveat>.-</local%-command%-caveat>",
}

-- Specific Claude-Code-generated scaffolding phrases that mark a UTILITY call
-- whose "prompt" is not user intent. These are deliberately verbatim and
-- distinctive so a genuine user prompt (e.g. "check the quota", "summarize the
-- readme") is never misclassified — the primary utility signal is structural
-- (zero tools); these markers only catch tool-bearing utility edge cases.
local CHATTER_MARKERS = {
  "[suggestion mode:",                     -- next-message suggestion (haiku)
  "suggest what the user might naturally type next",
  "the user stepped away and is coming back",   -- conversation recap
  "recap what you were doing in under",
  "write a 5-10 word title",               -- title generation
  "write the title in the predominant language",
  "you are an expert at summarizing conversations", -- compaction
  "your task is to create a detailed summary of the conversation",
}

local function lower(s) return (s or ""):lower() end

local function strip_scaffold(s)
  if type(s) ~= "string" then return "" end
  local out = s
  for _, pat in ipairs(SCAFFOLD) do
    out = out:gsub(pat, "")
  end
  return out
end

-- trim helper
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------------------------------------------------------------------------
-- text extraction
-- ---------------------------------------------------------------------------

-- From a flattened content string, recover the most recent real user prompt.
-- After stripping scaffolding, some gateways embed prior turns as role-prefixed
-- lines ("user:" / "assistant:"); if present, take the text after the last
-- "user:" marker, else the trailing residue.
local function prompt_from_string(s)
  local residue = strip_scaffold(s)
  -- take text after the last standalone "user:" marker if the transcript was flattened
  local last_user
  for seg in residue:gmatch("\nuser:(.-)\nassistant:") do last_user = seg end
  local tail_user = residue:match("\nuser:(.*)$")
  local candidate = tail_user or last_user or residue
  return trim(candidate)
end

-- From a message.content (string OR block array), return {texts=[...], is_string=bool}.
-- texts excludes <system-reminder> blocks. For arrays, order is preserved.
local function texts_of(content)
  if type(content) == "string" then
    return { prompt_from_string(content) }, true
  end
  local texts = {}
  if type(content) == "table" then
    for _, blk in ipairs(content) do
      if type(blk) == "table" and blk.type == "text" and type(blk.text) == "string" then
        if not blk.text:match("^%s*<system%-reminder>") then
          texts[#texts + 1] = blk.text
        end
      end
    end
  end
  return texts, false
end

-- ---------------------------------------------------------------------------
-- request parsing
-- ---------------------------------------------------------------------------

-- session_id: Claude Code puts a JSON string in metadata.user_id containing
-- {"device_id":..,"session_id":..}. Fall back to a provided header value.
function M.session_id(body, header_val)
  local md = type(body) == "table" and body.metadata or nil
  local uid = md and md.user_id
  if type(uid) == "string" then
    local sid = uid:match('"session_id"%s*:%s*"(.-)"')
    if sid and sid ~= "" then return sid end
    -- older encoding: user_..._session_<uuid>
    local sid2 = uid:match("session_([%w%-]+)")
    if sid2 then return sid2 end
  end
  if header_val and header_val ~= "" then return header_val end
  return nil
end

-- Is this request a Claude Code turn we should process?
function M.is_claude_code(body)
  if type(body) ~= "table" then return false end
  -- structured: tools include the Claude Code core set
  if type(body.tools) == "table" then
    for _, t in ipairs(body.tools) do
      local n = type(t) == "table" and t.name
      if n == "Bash" or n == "Read" or n == "Edit" or n == "TodoWrite" then
        return true
      end
    end
  end
  -- system prompt marker
  local sys = body.system
  if type(sys) == "string" and lower(sys):match("claude code") then return true end
  if type(sys) == "table" then
    for _, blk in ipairs(sys) do
      if type(blk) == "table" and lower(blk.text or ""):match("claude code") then return true end
    end
  end
  return false
end

-- Classify a request. Returns:
--   { kind = "utility"|"turn", session_id, user_prompt, chatter_reason,
--     tool_results = { {tool_use_id, content, is_error}, ... }, n_tools }
function M.parse_request(body, session_header)
  local res = { tool_results = {}, n_tools = 0 }
  res.session_id = M.session_id(body, session_header)

  local tools = type(body.tools) == "table" and body.tools or {}
  res.n_tools = #tools

  local msgs = type(body.messages) == "table" and body.messages or {}
  local last_user
  for i = #msgs, 1, -1 do
    if type(msgs[i]) == "table" and msgs[i].role == "user" then
      last_user = msgs[i]; break
    end
  end

  -- tool_use_id -> tool name, recovered from the transcript.
  -- The agentic loop resends the whole conversation every turn, so the assistant
  -- tool_use block that a tool_result answers is always present in THIS request.
  -- Recovering it here is what lets PostToolUse carry a tool_name: the response-side
  -- map is built in a later phase and does not survive to the next request.
  local call_names, prior_tool_uses = {}, {}
  for i = 1, #msgs do
    local m = msgs[i]
    if type(m) == "table" and m.role == "assistant" and type(m.content) == "table" then
      for _, blk in ipairs(m.content) do
        if type(blk) == "table" and blk.type == "tool_use" and blk.id then
          call_names[blk.id] = blk.name
          -- Keep the full call so streaming mode can still emit PreToolUse telemetry
          -- without buffering the response: the transcript is resent every turn, so the
          -- assistant's tool calls are recoverable from the REQUEST. Post-hoc (the tool
          -- has already run), so it is observability, not enforcement.
          prior_tool_uses[#prior_tool_uses + 1] = { id = blk.id, name = blk.name, input = blk.input }
        end
      end
    end
  end
  res.call_names = call_names
  res.prior_tool_uses = prior_tool_uses

  -- tool_results in the last user message → PostToolUse candidates
  if last_user and type(last_user.content) == "table" then
    for _, blk in ipairs(last_user.content) do
      if type(blk) == "table" and blk.type == "tool_result" then
        local c = blk.content
        local ctext
        if type(c) == "string" then
          ctext = c
        elseif type(c) == "table" then
          local parts = {}
          for _, sub in ipairs(c) do
            if type(sub) == "table" and sub.type == "text" then parts[#parts + 1] = sub.text end
          end
          ctext = table.concat(parts, "\n")
        end
        res.tool_results[#res.tool_results + 1] = {
          tool_use_id = blk.tool_use_id,
          name = blk.tool_use_id and res.call_names[blk.tool_use_id] or nil,
          content = ctext or "",
          is_error = blk.is_error and true or false,
        }
      end
    end
  end

  -- user prompt = last non-reminder text block (structured) or trailing residue (string)
  local prompt
  if last_user then
    local texts = texts_of(last_user.content)
    prompt = texts[#texts]
  end
  res.user_prompt = prompt and trim(prompt) or nil

  -- chatter / utility classification.
  -- Strong structural signal for Claude Code: main turns always carry tools;
  -- utility calls (titlegen, suggestion, recap, quota) carry zero.
  local reason
  if res.n_tools == 0 then
    reason = "no_tools_utility"
  else
    local hay = lower(prompt or "")
    for _, m in ipairs(CHATTER_MARKERS) do
      if hay:find(m, 1, true) then reason = "marker:" .. m; break end
    end
  end
  res.chatter_reason = reason
  res.kind = reason and "utility" or "turn"
  return res
end

-- ---------------------------------------------------------------------------
-- response parsing (assembled content array — SSE reassembly done by caller)
-- ---------------------------------------------------------------------------

-- content = array of blocks from the assistant message (text / tool_use).
-- Returns { tool_uses = { {id,name,input}, ... }, text = "...", stop_reason }
function M.parse_response(content, stop_reason)
  local out = { tool_uses = {}, text = nil, stop_reason = stop_reason }
  local text_parts = {}
  if type(content) == "table" then
    for _, blk in ipairs(content) do
      if type(blk) == "table" then
        if blk.type == "tool_use" then
          out.tool_uses[#out.tool_uses + 1] = { id = blk.id, name = blk.name, input = blk.input,
                                                input_json = blk.input_json, input_ok = blk.input_ok }
        elseif blk.type == "text" and type(blk.text) == "string" then
          text_parts[#text_parts + 1] = blk.text
        end
      end
    end
  end
  if #text_parts > 0 then out.text = table.concat(text_parts, "") end
  return out
end

-- ---------------------------------------------------------------------------
-- event synthesis
-- ---------------------------------------------------------------------------

-- Map a Claude Code tool name + input to the hook tool_input shape the backend
-- extracts (command / file_path / url / query, MCP passthrough).
local function hook_tool_input(name, input)
  return input or {}
end

-- Build the hook-shaped events for one request/response cycle.
-- ctx = { session_id, user_name, cwd, model, seen }  (seen = dedup state table)
-- parsed_req from parse_request; parsed_resp from parse_response (may be nil).
-- Returns a list of event tables (each ready to enrich + POST).
-- Populate a PreToolUse event from a tool_use block. Shared by the response path
-- (buffered mode) and the request-transcript path (streaming mode) so both emit
-- byte-identical events.
function M.fill_pre_tool_use(e, tu)
  e.tool_name = tu.name
  e.tool_input = hook_tool_input(tu.name, tu.input)
  e.tool_use_id = tu.id
  -- Surface unparseable tool arguments explicitly. tool_input already carries the raw
  -- text (as _unparsed_arguments) so Straiker can still scan the command; this flag lets
  -- the backend/Console treat "arguments did not parse" as a signal in its own right
  -- rather than seeing a tool call with suspiciously empty input.
  if tu.input_ok == false then
    e.tool_input_unparsed = true
    e.tool_input_raw = tu.input_json
  end
  -- MCP passthrough. Claude Code names MCP tools mcp__<server>__<tool> (the server key
  -- can itself contain single underscores; the delimiter is the double underscore).
  if type(tu.name) == "string" and tu.name:match("^mcp__") then
    local server, mtool = tu.name:match("^mcp__(.-)__(.+)$")
    e.mcp_server_name = server or tu.name:match("^mcp__(.+)$")
    e.mcp_tool_name = mtool
  end
  return e
end

function M.to_hook_events(parsed_req, parsed_resp, ctx)
  local events = {}
  local seen = ctx.seen or {}
  local sid = ctx.session_id or parsed_req.session_id or "unknown"

  local function base(ev)
    return {
      hook_event_name = ev,
      session_id = sid,
      user_name = ctx.user_name,
      cwd = ctx.cwd,
    }
  end

  -- 1. PostToolUse for any tool_result in this request (dedup by tool_use_id)
  for _, tr in ipairs(parsed_req.tool_results or {}) do
    local dkey = "post:" .. tostring(tr.tool_use_id)
    if tr.tool_use_id and not seen[dkey] then
      seen[dkey] = true
      local e = base("PostToolUse")
      -- prefer the name recovered from THIS request's transcript (always available);
      -- fall back to the response-side map for same-request correlation.
      e.tool_name = tr.name or (ctx.tool_names and ctx.tool_names[tr.tool_use_id]) or nil
      e.tool_response = tr.content
      e.tool_use_id = tr.tool_use_id
      e.is_error = tr.is_error
      events[#events + 1] = e
    end
  end

  -- 2. UserPromptSubmit for a real (non-chatter) prompt, once per distinct prompt
  if parsed_req.kind == "turn" and parsed_req.user_prompt and parsed_req.user_prompt ~= "" then
    local dkey = "prompt:" .. parsed_req.user_prompt
    if not seen[dkey] then
      seen[dkey] = true
      local e = base("UserPromptSubmit")
      e.prompt = parsed_req.user_prompt
      events[#events + 1] = e
    end
  end

  -- 3. PreToolUse for each tool_use in the response (dedup by id), record name
  if parsed_resp then
    ctx.tool_names = ctx.tool_names or {}
    for _, tu in ipairs(parsed_resp.tool_uses or {}) do
      if tu.id then ctx.tool_names[tu.id] = tu.name end
      local dkey = "pre:" .. tostring(tu.id)
      if tu.id and not seen[dkey] then
        seen[dkey] = true
        local e = base("PreToolUse")
        M.fill_pre_tool_use(e, tu)
        events[#events + 1] = e
      end
    end

    -- 4. Stop: the final assistant answer. Claude Code's native Stop hook does
    -- NOT carry this (a known coding-agent limitation) — but the gateway sees
    -- the response on the wire, so it can capture and forward the model's final
    -- output (enables output-side guardrails the endpoint hook cannot provide).
    if parsed_resp.stop_reason == "end_turn"
       and type(parsed_resp.text) == "string" and parsed_resp.text ~= "" then
      local dkey = "stop:" .. parsed_resp.text:sub(1, 96)
      if not seen[dkey] then
        seen[dkey] = true
        local e = base("Stop")
        e.app_response = parsed_resp.text
        e.stop_reason = parsed_resp.stop_reason
        events[#events + 1] = e
      end
    end
  end

  return events
end

M._internal = {
  strip_scaffold = strip_scaffold,
  prompt_from_string = prompt_from_string,
  texts_of = texts_of,
}

return M
