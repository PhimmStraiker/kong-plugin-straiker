#!/usr/bin/env python3
"""Controlled mock of /api/v1/detect for demonstrating the plugin's BLOCK
plumbing end-to-end. It mirrors the coding-agent response contract:

  * with Straiker-Debug: TRUE  -> returns {score, severity, action, ...}
  * without it (enforcement)    -> returns {"hookSpecificOutput":{permissionDecision}}

Deny policy (stand-in for a tenant's high-severity control): deny any PreToolUse
whose tool_input contains a denylisted token. Everything else is allowed. This
lets us drive Claude Code through Kong in block mode and watch a real tool call
get blocked — proving the enforcement path — without depending on the backend's
severity gate. Real-backend blocking is a policy/severity-tuning matter.
"""
import json, http.server

DENY_TOKENS = ("printenv", "env", "curl", "base64", "/etc/shadow", "id_rsa", "credentials")


def is_deny(event):
    ti = json.dumps(event.get("tool_input") or {})
    ev = event.get("hook_event_name", "")
    if ev not in ("PreToolUse", "PostToolUse"):
        return False, None
    for tok in DENY_TOKENS:
        if tok in ti:
            return True, tok
    return False, None


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(n)
        try:
            event = json.loads(raw)
        except Exception:
            event = {}
        deny, tok = is_deny(event)
        debug = self.headers.get("Straiker-Debug", "").upper() == "TRUE"
        if debug:
            body = {
                "turn_id": "mock-turn", "score": 0.95 if deny else 0.0,
                "severity": "critical" if deny else "low",
                "score_category": "Destructive Command" if deny else None,
                "action": "block" if deny else "detect",
                "reason": f"lab policy: denied token '{tok}'" if deny else None,
            }
        else:
            if deny:
                body = {"hookSpecificOutput": {
                    "hookEventName": event.get("hook_event_name"),
                    "permissionDecision": "deny",
                    "permissionDecisionReason": f"Blocked by Straiker (lab policy: '{tok}')."}}
            else:
                body = {"hookSpecificOutput": {
                    "hookEventName": event.get("hook_event_name"),
                    "permissionDecision": "allow", "permissionDecisionReason": "allow"}}
        out = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    http.server.HTTPServer(("0.0.0.0", 8901), H).serve_forever()
