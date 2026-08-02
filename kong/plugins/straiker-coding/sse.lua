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
  local model, usage
  for _, ev in ipairs(events) do
    if type(ev) == "table" then
      local t = ev.type
      if t == "content_block_start" then
        local cb = ev.content_block or {}
        -- Accumulate into TABLES, not by string concat. A long answer arrives as
        -- thousands of deltas; `s = s .. d` reallocates the whole string every time
        -- (O(n^2) bytes copied). table.concat at the end is linear.
        blocks[ev.index] = { type = cb.type, id = cb.id, name = cb.name,
                             text_parts = { cb.text or "" }, json_parts = {} }
      elseif t == "content_block_delta" then
        local b = blocks[ev.index]
        local d = ev.delta or {}
        if b then
          if d.type == "text_delta" then
            b.text_parts[#b.text_parts + 1] = d.text or ""
          elseif d.type == "input_json_delta" then
            b.json_parts[#b.json_parts + 1] = d.partial_json or ""
          end
        end
      elseif t == "message_start" then
        -- the REAL model id and input-token count live here and were being discarded;
        -- the backend otherwise hardcodes model="claude" and has no usage at all
        local m = ev.message or {}
        model = m.model or model
        if type(m.usage) == "table" then usage = m.usage end
      elseif t == "message_delta" then
        local d = ev.delta or {}
        if d.stop_reason then stop_reason = d.stop_reason end
        if type(ev.usage) == "table" then
          usage = usage or {}
          for k, v in pairs(ev.usage) do usage[k] = v end   -- output_tokens lands here
        end
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
      local raw_json = table.concat(b.json_parts)
      local input, input_ok = {}, true
      if raw_json ~= "" then
        local v = decode(raw_json)
        if type(v) == "table" then
          input = v
        else
          -- SECURITY: the arguments did not parse (truncated stream, or deliberately
          -- malformed). Previously `input` stayed {} and raw_json was DISCARDED, so the
          -- tool call reached Straiker with empty arguments — nothing to score — and was
          -- allowed. Keep the raw text so the actual command is still scanned, and flag
          -- it so callers can treat unparseable arguments as suspicious rather than empty.
          input_ok = false
          -- Put the raw text under `command` specifically. The backend's field extractor
          -- (argus hook_dispatcher.py:64-65) only reads command|file_path|url|query — a
          -- custom key like _unparsed_arguments is silently ignored, leaving command=""
          -- and nothing scanned. `command` is the field the detectors actually consume,
          -- and when arguments failed to parse there is no real command to displace.
          input = { command = raw_json, _unparsed_arguments = raw_json }
        end
      end
      content[#content + 1] = { type = "tool_use", id = b.id, name = b.name,
                                input = input, input_json = raw_json, input_ok = input_ok }
    elseif b.type == "text" then
      content[#content + 1] = { type = "text", text = table.concat(b.text_parts) }
    end
  end
  return { content = content, stop_reason = stop_reason, model = model, usage = usage }
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
