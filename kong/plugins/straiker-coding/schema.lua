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
              -- TRADEOFF (this is the streaming-vs-security switch):
              --
              -- "full"      Buffers the model response so a dangerous tool call can be
              --             blocked BEFORE the client executes it. Blocks on the prompt
              --             (kill switch), the tool call, and poisoned tool results.
              --             COST: token streaming is lost — the user sees nothing until
              --             the whole answer is ready. Measured: time-to-first-token
              --             0.84s -> 18.7s on a 500-word answer (total time is unchanged;
              --             only ~0.9s is real added latency).
              --
              -- "streaming" No response buffering, so native token streaming is preserved
              --             (~0.8s to first token). Still blocks on the prompt (the kill
              --             switch applies) and on poisoned tool results — both are
              --             request-side and need no buffering. Tool calls are still
              --             reported to Straiker for visibility, reconstructed from the
              --             next request's transcript, but they are POST-HOC: the tool has
              --             already run, so they cannot be blocked.
              --
              -- Pick "full" for enforcement, "streaming" for interactive comfort.
              type = "string", default = "full",
              one_of = { "full", "streaming" },
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
