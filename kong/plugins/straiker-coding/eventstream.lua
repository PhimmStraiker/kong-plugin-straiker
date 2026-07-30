-- eventstream.lua — decode AWS `application/vnd.amazon.eventstream` framing
-- (Bedrock InvokeModelWithResponseStream) into the inner Anthropic
-- message-stream events, which are identical to the Anthropic SSE events.
--
-- Frame layout (big-endian):
--   [4] total byte length
--   [4] headers byte length
--   [4] prelude CRC32
--   [headers_len] headers
--   [total - headers_len - 16] payload
--   [4] message CRC32
-- For a "chunk" event the payload is JSON {"bytes": "<base64 anthropic event>"}.
-- CRCs are not validated (we are reading, not trusting-for-security, and the
-- transport already integrity-checked upstream).
local M = {}

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

-- decode_events(raw, decode_json, b64decode) -> { anthropic_event, ... }
-- decode_json = cjson.safe.decode ; b64decode = ngx.decode_base64
function M.decode_events(raw, decode_json, b64decode)
  local events = {}
  local i = 1
  local n = #raw
  while i + 12 <= n do
    local total = u32(raw, i)
    local hlen = u32(raw, i + 4)
    if not total or not hlen or total < 16 or (i + total - 1) > n then break end
    local payload_start = i + 12 + hlen
    local payload_len = total - hlen - 16
    if payload_len > 0 then
      local payload = raw:sub(payload_start, payload_start + payload_len - 1)
      local outer = decode_json(payload)
      if type(outer) == "table" and outer.bytes then
        local inner_json = b64decode(outer.bytes)
        if inner_json then
          local inner = decode_json(inner_json)
          if type(inner) == "table" then events[#events + 1] = inner end
        end
      end
    end
    i = i + total
  end
  return events
end

function M.is_eventstream(content_type)
  return type(content_type) == "string"
    and content_type:find("vnd%.amazon%.eventstream") ~= nil
end

return M
