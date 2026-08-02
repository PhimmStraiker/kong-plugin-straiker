local typedefs = require "kong.db.schema.typedefs"

-- Guard: this plugin posts synthesized Claude Code hook events to the
-- coding-agent detect path (/api/v1/detect + x-tool: claude-code), NOT the
-- generic gateway webhook. The /detect/webhook path was verified to not enforce
-- the coding-agent pipeline, so reject a URL pointing at it.
local function not_webhook(url)
  if type(url) == "string" and url:match("/webhook%s*$") then
    return nil, "detect_url must be the /api/v1/detect coding-agent path, not /detect/webhook"
  end
  return true
end

return {
  name = "straiker-coding",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { api_key = {
              type = "string", required = true, encrypted = true, referenceable = true,
          } },
          { detect_url = {
              type = "string",
              default = "https://api.prod.straiker.ai/api/v1/detect",
              custom_validator = not_webhook,
          } },
          { x_tool = {
              type = "string", default = "claude-code",
          } },
          { mode = {
              -- monitor: synthesize + score + surface in Console, never block.
              -- block: deny tool calls whose PreToolUse/PostToolUse verdict is deny.
              type = "string", default = "monitor",
              one_of = { "monitor", "block" },
          } },
          { enforcement = {
              -- "full" — the only supported value today. Buffers the model response so a
              -- dangerous tool call is blocked BEFORE the client executes it: blocks on
              -- the prompt (kill switch), the tool call, and poisoned tool results.
              -- COST: token streaming is lost. MEASURED on a 500-word answer:
              -- time-to-first-token 0.84s -> 18.7s, while TOTAL time is nearly unchanged
              -- (+0.9s). The latency users report is lost streaming, not added processing.
              --
              -- A "streaming" value is NOT offered yet, and cannot be implemented by a
              -- runtime flag. Kong decides buffering from the EXISTENCE of a `response`
              -- handler on the plugin, in the plugin iterator, before plugin code runs:
              --     kong/runloop/plugins_iterator.lua:521
              --     if phase == "response" and not ctx.buffered_proxying then
              --       ctx.buffered_proxying = true
              -- Returning early inside :response() is far too late — buffering is already
              -- on. Verified empirically: enforcement=streaming still measured 19.6s TTFT
              -- on a control plane with no other plugins.
              --
              -- Real fix (tracked): drop :response() entirely and move to
              -- :header_filter()/:body_filter(), which do not force buffering. Then
              -- "full" accumulates chunks manually, and true streaming passes text deltas
              -- through while holding ONLY tool_use frames until scored ("streaming hold").
              type = "string", default = "full",
              one_of = { "full" },
          } },
          { chatter_filter = {
              -- Drop Claude Code utility/scaffolding calls (titlegen, suggestion
              -- mode, recap, quota, zero-tool turns) before emitting
              -- UserPromptSubmit — this is what prevents FP detections.
              type = "boolean", default = true,
          } },
          { session_header = {
              type = "string", default = "X-Straiker-Session-Id",
          } },
          { user_name_header = {
              type = "string", default = "X-Straiker-User-Name",
          } },
          { user_name_default = {
              type = "string", default = "kong-coding",
          } },
          { model_override = {
              type = "string", default = nil,
          } },
          { sign_payloads = {
              type = "boolean", default = true,
          } },
          { fail_open = {
              -- Input gate behaviour when the detect call errors. Response-side
              -- enforcement always fails open (a real answer is never withheld).
              type = "boolean", default = true,
          } },
          { timeout_ms = {
              type = "integer", default = 5000,
          } },
          { debug = {
              type = "boolean", default = false,
          } },
          { log_serialize = {
              -- When true, enrich Kong's native log serializer with the raw
              -- request/response bodies, the resolved session, the synthesized
              -- hook events, and the real Straiker verdict (scored synchronously
              -- so it lands in the same Kong log line). A Kong logging plugin
              -- (file-log/http-log) then exports exactly what Kong saw + did.
              type = "boolean", default = false,
          } },
        },
    } },
  },
}
