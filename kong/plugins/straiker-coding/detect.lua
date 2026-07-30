-- detect.lua — sign + POST a synthesized hook event to Straiker /api/v1/detect
-- with x-tool: claude-code, mirroring the native Claude Code hook handler.
local http = require "resty.http"

local M = {}

local function to_hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

-- HMAC-SHA256 hex over "{ts}.{payload}" keyed by the API key.
local function sign(key, ts, payload)
  local ok, hmac = pcall(require, "resty.openssl.hmac")
  if not ok then return nil end
  local h = hmac.new(key, "sha256")
  if not h then return nil end
  local ok2 = h:update(ts .. "." .. payload)
  if not ok2 then return nil end
  local raw = h:final()
  if not raw then return nil end
  return to_hex(raw)
end

-- Post an event. `enforce` = true means block mode (expect hookSpecificOutput).
-- Returns res, err. On enforce+deny the caller reads
-- res.body -> hookSpecificOutput.permissionDecision == "deny".
function M.post(conf, event_json, enforce)
  local ts = tostring(ngx.time())
  local headers = {
    ["Content-Type"] = "application/json",
    ["Authorization"] = "Bearer " .. conf.api_key,
    ["x-tool"] = conf.x_tool or "claude-code",
  }
  if conf.sign_payloads then
    local sig = sign(conf.api_key, ts, event_json)
    if sig then
      headers["X-Straiker-Webhook-Signature"] = sig
      headers["X-Straiker-Webhook-Timestamp"] = ts
    end
  end
  -- Straiker-Debug (rich score) and enforcement are mutually exclusive: only
  -- ask for debug when NOT enforcing, so block mode gets hookSpecificOutput.
  if not enforce then
    headers["Straiker-Debug"] = "TRUE"
  end

  local client = http.new()
  client:set_timeout(conf.timeout_ms or 5000)
  local res, err = client:request_uri(conf.detect_url, {
    method = "POST",
    body = event_json,
    headers = headers,
    ssl_verify = conf.ssl_verify ~= false,
    keepalive_timeout = 60000,
    keepalive_pool = 10,
  })
  return res, err
end

return M
