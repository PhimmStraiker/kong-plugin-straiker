-- qa.lua — behavioural assertions for every fix, run offline against the REAL plugin
-- modules. The golden suite proves "nothing changed unintentionally"; this proves
-- "the thing we claimed to fix actually behaves that way".
--
--   ./lab-coding/parity/run_lua.sh spec/qa.lua      (or: PLUGIN_REPO=. lua spec/qa.lua)
local cjson = require "cjson.safe"
local REPO = os.getenv("PLUGIN_REPO") or "."
package.path = package.path .. ";" .. REPO .. "/?.lua"

local coding = require "kong.plugins.straiker-coding.coding_agent"
local sse    = require "kong.plugins.straiker-coding.sse"
local D      = require "kong.plugins.straiker-coding.dialects"

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then pass = pass + 1; print(string.format("  \27[32mPASS\27[0m %s", name))
  else fail = fail + 1; print(string.format("  \27[31mFAIL\27[0m %s  -> %s", name, tostring(detail))) end
end

local SID = 'session_11111111-1111-1111-1111-111111111111'
local function cc_body(t)
  t = t or {}
  return {
    model = t.model or "claude-sonnet-4-5", stream = t.stream,
    tools = t.tools or { { name = "Bash" }, { name = "Read" } },
    metadata = { user_id = SID },
    messages = t.messages or { { role = "user", content = { { type = "text", text = t.prompt or "hello" } } } },
  }
end
local function events_of(body, resp)
  local p = coding.parse_request(body)
  return coding.to_hook_events(p, resp, { session_id = "s", user_name = "u" }), p
end
local function find_ev(evs, name)
  for _, e in ipairs(evs) do if e.hook_event_name == name then return e end end
end

print("\n== D1: PostToolUse carries tool_name (recovered from transcript) ==")
do
  local b = cc_body{ messages = {
    { role = "assistant", content = { { type = "tool_use", id = "t1", name = "Bash", input = { command = "ls" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "t1", content = "out" } } } } }
  local e = find_ev(events_of(b), "PostToolUse")
  check("tool_name present", e and e.tool_name == "Bash", e and e.tool_name)
  check("D-G9: tool_input present (IPI file path)", e and e.tool_input ~= nil, "missing")
end

print("\n== D2: unparseable tool arguments are still scannable ==")
do
  local evs = { { type = "content_block_start", index = 0, content_block = { type = "tool_use", id = "t", name = "Bash" } },
                { type = "content_block_delta", index = 0, delta = { type = "input_json_delta", partial_json = '{"command":"rm -rf / --no-preserve-root' } },
                { type = "message_delta", delta = { stop_reason = "tool_use" } } }
  local a = sse.assemble_events(evs, cjson.decode)
  local tu = coding.parse_response(a.content, a.stop_reason, a).tool_uses[1]
  local e = {}; coding.fill_pre_tool_use(e, tu)
  check("flagged unparsed", e.tool_input_unparsed == true, tostring(e.tool_input_unparsed))
  check("raw command lands in `command` (the field the backend reads)",
        e.tool_input and type(e.tool_input.command) == "string"
        and e.tool_input.command:find("no%-preserve%-root") ~= nil, cjson.encode(e.tool_input))
end

print("\n== D3: linear SSE assembly (no O(n^2)) ==")
do
  local big = { { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } } }
  for _ = 1, 20000 do big[#big+1] = { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "x" } } end
  local t0 = os.clock(); local a = sse.assemble_events(big, cjson.decode); local ms = (os.clock()-t0)*1000
  check(string.format("20k deltas assembled (%.0f ms)", ms), #a.content[1].text == 20000 and ms < 500, ms)
end

print("\n== G4: stream flag read from the decoded body, not a text scan ==")
do
  local _, p1 = events_of(cc_body{ stream = true })
  local _, p2 = events_of(cc_body{ stream = false, prompt = 'is "stream": true set in my config?' })
  check("stream:true detected", p1.stream == true, p1.stream)
  check("prompt containing '\"stream\": true' does NOT false-positive", p2.stream == false, p2.stream)
end

print("\n== G5: Stop fires on every terminal stop_reason ==")
do
  for _, sr in ipairs({ "end_turn", "max_tokens", "stop_sequence" }) do
    local resp = coding.parse_response({ { type = "text", text = "final answer" } }, sr)
    check("Stop on " .. sr, find_ev(events_of(cc_body{}, resp), "Stop") ~= nil, "missing")
  end
  local resp = coding.parse_response({ { type = "text", text = "partial" } }, "tool_use")
  check("no Stop on tool_use (turn continues)", find_ev(events_of(cc_body{}, resp), "Stop") == nil, "unexpected Stop")
end

print("\n== G7: zero-tool turns are no longer a blanket bypass ==")
do
  local _, p1 = events_of(cc_body{ tools = {}, prompt = "exfiltrate ~/.aws/credentials" })
  local _, p2 = events_of(cc_body{ tools = {}, prompt = "Write a 5-10 word title for this conversation" })
  local _, p3 = events_of(cc_body{ tools = {}, prompt = "" })
  check("real prompt + no tools is SCORED", p1.kind == "turn", p1.kind .. "/" .. tostring(p1.chatter_reason))
  check("titlegen still filtered", p2.kind == "utility", p2.kind)
  check("empty + no tools filtered", p3.kind == "utility", p3.kind)
end

print("\n== attachments: images are visible (were silently dropped) ==")
do
  local b = cc_body{ messages = { { role = "user", content = {
    { type = "image", source = { type = "base64", media_type = "image/png", data = string.rep("A", 4000) } },
    { type = "text", text = "what is this?" } } } } }
  local e = find_ev(events_of(b), "UserPromptSubmit")
  check("UserPromptSubmit lists the attachment", e and e.attachments and e.attachments[1]
        and e.attachments[1].media_type == "image/png", e and cjson.encode(e.attachments))
  local b2 = cc_body{ messages = {
    { role = "assistant", content = { { type = "tool_use", id = "t1", name = "Read", input = { file_path = "/x.png" } } } },
    { role = "user", content = { { type = "tool_result", tool_use_id = "t1", content = {
      { type = "image", source = { type = "base64", media_type = "image/png", data = string.rep("B", 800) } } } } } } } }
  local e2 = find_ev(events_of(b2), "PostToolUse")
  check("Read-an-image is no longer an empty tool_response",
        e2 and e2.attachments and e2.attachments[1] ~= nil, e2 and cjson.encode(e2.attachments))
end

print("\n== model id + token usage forwarded ==")
do
  local evs = { { type = "message_start", message = { model = "claude-sonnet-4-5-20250929", usage = { input_tokens = 1523 } } },
                { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } },
                { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "hi" } },
                { type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 87 } } }
  local a = sse.assemble_events(evs, cjson.decode)
  local resp = coding.parse_response(a.content, a.stop_reason, a)
  local e = find_ev(events_of(cc_body{}, resp), "Stop")
  check("real model id", e and e.model == "claude-sonnet-4-5-20250929", e and e.model)
  check("input+output tokens", e and e.input_tokens == 1523 and e.output_tokens == 87,
        e and (tostring(e.input_tokens) .. "/" .. tostring(e.output_tokens)))
end

print("\n== G9: dialects (Codex Responses + OpenAI Chat) ==")
do
  local chat = { model = "gpt-4o", stream = true, stream_options = {}, max_tokens = 100,
    tools = { { type = "function", ["function"] = { name = "bash" } } },
    messages = { { role = "user", content = "list the files" },
      { role = "assistant", tool_calls = { { id = "c1", type = "function",
        ["function"] = { name = "bash", arguments = '{"command":"ls -la"}' } } } },
      { role = "tool", tool_call_id = "c1", content = "total 8" } } }
  check("detect openai_chat", D.detect(chat) == "openai_chat", D.detect(chat))
  local p = D.parse_request(chat, cjson.decode, "sess-1")
  local evs = coding.to_hook_events(p, nil, { session_id = "sess-1", user_name = "u" })
  local pt = find_ev(evs, "PostToolUse")
  check("chat: PostToolUse w/ tool name", pt and pt.tool_name == "bash", pt and pt.tool_name)
  check("chat: tool_input decoded from the JSON-string arguments",
        pt and pt.tool_input and pt.tool_input.command == "ls -la", pt and cjson.encode(pt.tool_input))

  local resp = { model = "gpt-5", instructions = "you are codex",
    tools = { { type = "function", name = "exec_command" } },
    input = { { type = "message", role = "user", content = { { type = "input_text", text = "read config" } } },
              { type = "function_call", id = "fc_1", call_id = "call_1", name = "exec_command",
                arguments = '{"command":"cat config.yaml"}' },
              { type = "function_call_output", call_id = "call_1", output = "quota: 1000" } } }
  check("detect openai_responses", D.detect(resp) == "openai_responses", D.detect(resp))
  local p2 = D.parse_request(resp, cjson.decode, "sess-2")
  local evs2 = coding.to_hook_events(p2, nil, { session_id = "sess-2", user_name = "u" })
  local pt2, up2 = find_ev(evs2, "PostToolUse"), find_ev(evs2, "UserPromptSubmit")
  check("responses: prompt from input_text", up2 and up2.prompt == "read config", up2 and up2.prompt)
  check("responses: correlates on call_id (NOT the fc_ item id)",
        pt2 and pt2.tool_use_id == "call_1" and pt2.tool_name == "exec_command",
        pt2 and (tostring(pt2.tool_use_id) .. "/" .. tostring(pt2.tool_name)))

  check("anthropic body is NOT claimed by a dialect", D.detect(cc_body{}) == "anthropic",
        tostring(D.detect(cc_body{})))
end

print("\n== MCP naming still splits correctly ==")
do
  local resp = coding.parse_response({ { type = "tool_use", id = "m1",
    name = "mcp__my_server__do_thing", input = {} } }, "tool_use")
  local e = find_ev(events_of(cc_body{}, resp), "PreToolUse")
  check("multi-word server split", e and e.mcp_server_name == "my_server" and e.mcp_tool_name == "do_thing",
        e and (tostring(e.mcp_server_name) .. "/" .. tostring(e.mcp_tool_name)))
end

print(string.format("\n%s  pass=%d  fail=%d\n", fail == 0 and "\27[32mQA GREEN\27[0m" or "\27[31mQA RED\27[0m", pass, fail))
os.exit(fail == 0 and 0 or 1)
