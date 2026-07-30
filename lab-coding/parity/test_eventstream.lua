-- Offline test: decode a real Bedrock vnd.amazon.eventstream capture through the
-- plugin's eventstream.lua + sse.lua and confirm the Anthropic events + tool_use
-- are recovered. Provides cjson + a pure-Lua base64 decoder (Kong uses
-- ngx.decode_base64 at runtime).
local cjson = require "cjson"
package.path = package.path .. ";" .. os.getenv("PLUGIN_REPO") .. "/?.lua"
local eventstream = require "kong.plugins.straiker-coding.eventstream"
local sse = require "kong.plugins.straiker-coding.sse"
local coding = require "kong.plugins.straiker-coding.coding_agent"

-- minimal base64 decoder
local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local dec = {}
for i = 1, #b64 do dec[b64:sub(i, i)] = i - 1 end
local function b64decode(s)
  s = s:gsub("[^" .. b64 .. "=]", "")
  local out = {}
  local acc, nbits = 0, 0
  for i = 1, #s do
    local c = s:sub(i, i)
    if c == "=" then break end
    acc = acc * 64 + dec[c]
    nbits = nbits + 6
    if nbits >= 8 then
      nbits = nbits - 8
      local byte = math.floor(acc / (2 ^ nbits)) % 256
      out[#out + 1] = string.char(byte)
      acc = acc % (2 ^ nbits)   -- drop consumed high bits (prevents overflow)
    end
  end
  return table.concat(out)
end

local f = io.open(arg[1], "rb")
local raw = f:read("*a"); f:close()

-- safe decode (mirror cjson.safe used in Kong)
local function safe_decode(s)
  local ok, v = pcall(cjson.decode, s)
  if ok then return v end
  return nil
end

-- diagnostic: walk frames manually
local function u32(s, i) local a,b,c,d=s:byte(i,i+3); return ((a*256+b)*256+c)*256+d end
local i, n, fr = 1, #raw, 0
while i + 12 <= n do
  local total=u32(raw,i); local hlen=u32(raw,i+4)
  if not total or total<16 or i+total-1>n then break end
  fr=fr+1
  local ps=i+12+hlen; local pl=total-hlen-16
  local payload=raw:sub(ps, ps+pl-1)
  -- header region: find :event-type value (type 7 string)
  local hdr=raw:sub(i+12, i+12+hlen-1)
  print(string.format("frame %d total=%d hlen=%d payload_len=%d payload_head=%q", fr, total, hlen, pl, payload:sub(1,50)))
  i=i+total
end
print("---")

local events = eventstream.decode_events(raw, safe_decode, b64decode)
print("decoded event count:", #events)
local types = {}
for _, e in ipairs(events) do types[#types + 1] = e.type end
print("event types:", table.concat(types, ", "))

local assembled = sse.assemble_events(events, safe_decode)
local presp = coding.parse_response(assembled.content, assembled.stop_reason)
print("stop_reason:", tostring(assembled.stop_reason))
print("tool_uses:", #presp.tool_uses)
for _, tu in ipairs(presp.tool_uses) do
  print("  tool_use:", tu.name, cjson.encode(tu.input))
end
if presp.text then print("text:", presp.text:sub(1, 80)) end
