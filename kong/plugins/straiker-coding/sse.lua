-- sse.lua — reassemble an Anthropic Messages SSE stream into assistant content.
-- Buffered mode: pass the whole response body. Incremental mode (streaming hold)
-- will reuse feed()/finalize() on a per-chunk basis.
local M = {}

-- Core: assemble a list of already-decoded Anthropic message-stream events
-- (message_start / content_block_* / message_delta) into assistant content.
-- Shared by both the Anthropic SSE path and the Bedrock event-stream path
-- (identical inner events, different transport framing).
function M.assemble_events(events, decode)
  local blocks = {}
  local stop_reason
  for _, ev in ipairs(events) do
    if type(ev) == "table" then
      local t = ev.type
      if t == "content_block_start" then
        local cb = ev.content_block or {}
        blocks[ev.index] = { type = cb.type, id = cb.id, name = cb.name,
                             text = cb.text or "", _json = "" }
      elseif t == "content_block_delta" then
        local b = blocks[ev.index]
        local d = ev.delta or {}
        if b then
          if d.type == "text_delta" then
            b.text = (b.text or "") .. (d.text or "")
          elseif d.type == "input_json_delta" then
            b._json = (b._json or "") .. (d.partial_json or "")
          end
        end
      elseif t == "message_delta" then
        local d = ev.delta or {}
        if d.stop_reason then stop_reason = d.stop_reason end
      end
    end
  end

  local idxs = {}
  for i in pairs(blocks) do idxs[#idxs + 1] = i end
  table.sort(idxs)

  local content = {}
  for _, i in ipairs(idxs) do
    local b = blocks[i]
    if b.type == "tool_use" then
      local input = {}
      if b._json and b._json ~= "" then
        local v = decode(b._json)
        if type(v) == "table" then input = v end
      end
      content[#content + 1] = { type = "tool_use", id = b.id, name = b.name, input = input }
    elseif b.type == "text" then
      content[#content + 1] = { type = "text", text = b.text }
    end
  end
  return { content = content, stop_reason = stop_reason }
end

-- assemble(raw_text, decode) -> { content, stop_reason } for an Anthropic SSE body.
function M.assemble(raw, decode)
  local events = {}
  for line in raw:gmatch("[^\n]+") do
    local data = line:match("^data:%s?(.*)")
    if data and data ~= "" and data ~= "[DONE]" then
      local ev = decode(data)
      if type(ev) == "table" then events[#events + 1] = ev end
    end
  end
  return M.assemble_events(events, decode)
end

-- Detect whether a response body is an SSE stream (vs a plain JSON message).
function M.is_sse(content_type)
  return type(content_type) == "string" and content_type:find("text/event%-stream") ~= nil
end

return M
