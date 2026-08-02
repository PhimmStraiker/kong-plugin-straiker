-- dialects.lua — normalize non-Anthropic coding-agent wire formats into the SAME
-- request shape coding_agent.lua already produces, so every agent lands on the identical
-- hook events (UserPromptSubmit / PreToolUse / PostToolUse / Stop) and the identical
-- Straiker pipeline. Backward compatibility with the coding-agent security model is the
-- whole point: nothing downstream should be able to tell which agent it came from.
--
-- The axis of variation is the WIRE FORMAT, not the product. Codex speaks OpenAI
-- Responses; OpenCode/Cursor/Copilot speak OpenAI Chat Completions; Claude Code speaks
-- Anthropic Messages (handled natively in coding_agent.lua). OpenCode can be pointed at
-- any of them, which is exactly why keying on the format rather than the agent matters.
--
-- Shapes below were taken from REAL captured traffic (spec/fixtures/dialects/), not docs.
local M = {}

-- ---------------------------------------------------------------------------
-- OpenAI Chat Completions  (OpenCode, Cursor, Copilot)
--   history : messages[]                      role user/assistant/system/tool
--   tools   : tools[].function.name           (NESTED — differs from Responses)
--   calls   : assistant.tool_calls[] {id, function:{name, arguments(JSON string)}}
--   results : {role:"tool", tool_call_id, content}
-- ---------------------------------------------------------------------------
local function parse_openai_chat(body, decode)
  local msgs = type(body.messages) == "table" and body.messages or {}
  local tools = type(body.tools) == "table" and body.tools or {}

  local call_names, call_inputs = {}, {}
  for _, m in ipairs(msgs) do
    if type(m) == "table" and type(m.tool_calls) == "table" then
      for _, tc in ipairs(m.tool_calls) do
        local fn = type(tc["function"]) == "table" and tc["function"] or {}
        if tc.id then
          call_names[tc.id] = fn.name
          -- arguments is a JSON *string* here (unlike Anthropic's object)
          local args = fn.arguments
          if type(args) == "string" and args ~= "" then
            local v = decode(args)
            call_inputs[tc.id] = type(v) == "table" and v
              or { command = args, _unparsed_arguments = args }
          end
        end
      end
    end
  end

  -- last user text = the prompt; role:"tool" messages = completed tool results
  local prompt, tool_results = nil, {}
  for i = #msgs, 1, -1 do
    local m = msgs[i]
    if type(m) == "table" then
      if m.role == "tool" and m.tool_call_id then
        tool_results[#tool_results + 1] = {
          tool_use_id = m.tool_call_id,
          name = call_names[m.tool_call_id],
          input = call_inputs[m.tool_call_id],
          content = type(m.content) == "string" and m.content or "",
          is_error = false,
        }
      elseif m.role == "user" and not prompt then
        if type(m.content) == "string" then prompt = m.content
        elseif type(m.content) == "table" then
          for _, blk in ipairs(m.content) do
            if type(blk) == "table" and blk.type == "text" and blk.text then prompt = blk.text end
          end
        end
      end
    end
  end

  return { n_tools = #tools, user_prompt = prompt, tool_results = tool_results,
           stream = body.stream == true, model = body.model,
           call_names = call_names, call_inputs = call_inputs, prior_tool_uses = {} }
end

-- ---------------------------------------------------------------------------
-- OpenAI Responses  (Codex CLI — it REMOVED Chat Completions support)
--   history : input[]                          typed items, not messages
--   system  : instructions (top level string)  NOT a message
--   tools   : tools[].name                     (FLAT)
--   calls   : {type:"function_call", call_id, name, arguments(JSON string)}
--   results : {type:"function_call_output", call_id, output}
--   NB: function_call carries BOTH id (fc_…) and call_id (call_…); the output
--       references call_id. Correlating on id is a permanent miss.
-- ---------------------------------------------------------------------------
local function parse_openai_responses(body, decode)
  local items = type(body.input) == "table" and body.input or {}
  local tools = type(body.tools) == "table" and body.tools or {}

  local call_names, call_inputs = {}, {}
  for _, it in ipairs(items) do
    if type(it) == "table" and it.type == "function_call" and it.call_id then
      call_names[it.call_id] = it.name
      local args = it.arguments
      if type(args) == "string" and args ~= "" then
        local v = decode(args)
        call_inputs[it.call_id] = type(v) == "table" and v
          or { command = args, _unparsed_arguments = args }
      end
    end
  end

  local prompt, tool_results = nil, {}
  for i = #items, 1, -1 do
    local it = items[i]
    if type(it) == "table" then
      if it.type == "function_call_output" and it.call_id then
        tool_results[#tool_results + 1] = {
          tool_use_id = it.call_id,
          name = call_names[it.call_id],
          input = call_inputs[it.call_id],
          content = type(it.output) == "string" and it.output or "",
          is_error = false,
        }
      elseif it.type == "message" and it.role == "user" and not prompt then
        local c = it.content
        if type(c) == "string" then prompt = c
        elseif type(c) == "table" then
          for _, blk in ipairs(c) do
            -- Responses uses input_text (not text)
            if type(blk) == "table" and (blk.type == "input_text" or blk.type == "text") and blk.text then
              prompt = blk.text
            end
          end
        end
      end
    end
  end

  return { n_tools = #tools, user_prompt = prompt, tool_results = tool_results,
           stream = body.stream == true, model = body.model,
           call_names = call_names, call_inputs = call_inputs, prior_tool_uses = {} }
end

-- ---------------------------------------------------------------------------
-- detection + dispatch
-- ---------------------------------------------------------------------------

-- Identify the wire format from the decoded body. Cheap structural checks only.
function M.detect(body)
  if type(body) ~= "table" then return nil end
  if type(body.input) == "table" and body.instructions ~= nil then return "openai_responses" end
  if type(body.input) == "table" and type(body.messages) ~= "table" then return "openai_responses" end
  if type(body.messages) == "table" then
    -- Anthropic also uses messages[]; the discriminator is where tool names live
    local tools = body.tools
    if type(tools) == "table" and tools[1] and type(tools[1]) == "table" then
      if type(tools[1]["function"]) == "table" then return "openai_chat" end
      if tools[1].input_schema ~= nil or tools[1].name ~= nil then return "anthropic" end
    end
    if body.max_tokens and body.system == nil and body.stream_options ~= nil then return "openai_chat" end
  end
  return nil
end

-- Parse a non-Anthropic body into the shape coding_agent.to_hook_events consumes.
-- Returns nil for Anthropic (coding_agent handles it natively) or unknown shapes.
function M.parse_request(body, decode, session_header_val)
  local d = M.detect(body)
  local res
  if d == "openai_chat" then res = parse_openai_chat(body, decode)
  elseif d == "openai_responses" then res = parse_openai_responses(body, decode)
  else return nil end

  res.dialect = d
  res.session_id = session_header_val   -- these agents carry the session in HEADERS
  -- Chatter: these agents' utility calls (title generation) carry no tools at all.
  res.kind = (res.n_tools == 0 and (res.user_prompt or "") == "") and "utility" or "turn"
  if res.n_tools == 0 and res.user_prompt then
    -- OpenCode's title-generation call has a distinctive system prompt and no tools
    res.kind = "utility"
    res.chatter_reason = "no_tools_utility"
  end
  return res
end

-- Session id from request headers (Codex: session-id / OpenCode: x-session-id).
-- Unlike Claude Code these agents do NOT bury it in the body, which is simpler.
function M.session_id_from_headers(get_header)
  for _, h in ipairs({ "session-id", "x-session-id", "thread-id", "x-session-affinity" }) do
    local v = get_header(h)
    if v and v ~= "" then return v end
  end
  return nil
end

return M
