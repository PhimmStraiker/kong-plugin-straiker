-- lua_cli.lua — replay a captured wire.jsonl session through the ACTUAL plugin
-- parser (kong.plugins.straiker-coding.coding_agent + sse) with the same
-- cross-request dedup the handler applies, and emit the synthesized hook events
-- as JSON lines. This is the offline oracle for parity_check.py: it proves the
-- Lua the plugin runs produces the right events, without needing Kong live.
--
-- Run via parity/run_lua.sh (sets luarocks cpath + plugin package.path).
local cjson = require "cjson"

local REPO = os.getenv("PLUGIN_REPO")
package.path = package.path .. ";" .. REPO .. "/?.lua"
local coding = require "kong.plugins.straiker-coding.coding_agent"
local sse    = require "kong.plugins.straiker-coding.sse"

local wire_path = arg[1]

local seen = {}
local function first_time(sid, dkey)
  local k = sid .. ":" .. dkey
  if seen[k] then return false end
  seen[k] = true
  return true
end
local function evkey(e)
  local n = e.hook_event_name
  if n == "PreToolUse" then return "pre:" .. tostring(e.tool_use_id) end
  if n == "PostToolUse" then return "post:" .. tostring(e.tool_use_id) end
  if n == "UserPromptSubmit" then return "prompt:" .. tostring(e.prompt) end
  return n
end

local out = {}

for line in io.lines(wire_path) do
  local r = cjson.decode(line)
  local body = r.req_body
  if type(body) == "table" then
    local sid = coding.session_id(body)
    if sid then
      -- request-side: PostToolUse (tool_results) + UserPromptSubmit
      local preq = coding.parse_request(body)
      local ctx = { session_id = sid, user_name = "lab" }
      for _, e in ipairs(coding.to_hook_events(preq, nil, ctx)) do
        if first_time(sid, evkey(e)) then out[#out + 1] = e end
      end
      -- response-side: PreToolUse from the assistant tool_use blocks
      if type(r.resp_sse) == "table" then
        local parts = {}
        for _, ev in ipairs(r.resp_sse) do
          parts[#parts + 1] = "event: " .. tostring(ev.event) ..
            "\ndata: " .. cjson.encode(ev.data) .. "\n\n"
        end
        local assembled = sse.assemble(table.concat(parts), cjson.decode)
        local presp = coding.parse_response(assembled.content, assembled.stop_reason)
        local ctx2 = { session_id = sid, user_name = "lab", tool_names = {} }
        for _, e in ipairs(coding.to_hook_events({ tool_results = {}, kind = "turn" }, presp, ctx2)) do
          if e.hook_event_name == "PreToolUse" and first_time(sid, evkey(e)) then
            out[#out + 1] = e
          end
        end
      end
    end
  end
end

for _, e in ipairs(out) do
  print(cjson.encode({
    hook_event_name = e.hook_event_name,
    tool_name = e.tool_name,
    tool_input = e.tool_input,
    prompt = e.prompt,
    tool_use_id = e.tool_use_id,
    session_id = e.session_id,
  }))
end
