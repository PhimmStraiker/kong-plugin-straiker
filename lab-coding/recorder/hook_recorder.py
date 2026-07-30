#!/usr/bin/env python3
"""Claude Code hook recorder — the parity oracle side.

Wired into a lab Claude Code session via --settings. For every hook event it:
  1. appends the raw hook stdin JSON (+ enrichment) to $STRAIKER_HOOK_LOG
  2. posts it to Straiker /api/v1/detect with x-tool: claude-code (HMAC-signed,
     Straiker-Debug: TRUE) exactly like the shipping v4.1 handler, and appends
     the detect response to $STRAIKER_DETECT_LOG
  3. always exits 0 (monitor mode — never blocks the lab session)

This gives the hooks-path ground truth to diff the Kong-synthesized events
against. Env:
  STRAIKER_CODING_KEY   app detect key (required to score; skips POST if unset)
  STRAIKER_API_BASE     default https://api.prod.straiker.ai
  STRAIKER_HOOK_LOG     default ./hooks.jsonl
  STRAIKER_DETECT_LOG   default ./hooks_detect.jsonl
  STRAIKER_USER_NAME    default git email / $USER
"""
import hashlib, hmac, json, os, subprocess, sys, time, urllib.request, urllib.error


def user_name():
    v = os.environ.get("STRAIKER_USER_NAME")
    if v:
        return v
    try:
        return subprocess.check_output(["git", "config", "user.email"], text=True).strip() or os.environ.get("USER", "lab")
    except Exception:
        return os.environ.get("USER", "lab")


def main():
    raw = sys.stdin.read()
    try:
        d = json.loads(raw) if raw.strip() else {}
    except Exception:
        d = {"_unparsed": raw}

    d.setdefault("user_name", user_name())
    event = d.get("hook_event_name") or "unknown"
    hook_log = os.environ.get("STRAIKER_HOOK_LOG", "hooks.jsonl")
    detect_log = os.environ.get("STRAIKER_DETECT_LOG", "hooks_detect.jsonl")

    with open(hook_log, "a") as f:
        f.write(json.dumps({"ts": time.time(), "event": event, "payload": d}) + "\n")

    key = os.environ.get("STRAIKER_CODING_KEY")
    if key:
        base = os.environ.get("STRAIKER_API_BASE", "https://api.prod.straiker.ai")
        payload = json.dumps(d)
        ts = str(int(time.time()))
        sig = hmac.new(key.encode(), f"{ts}.{payload}".encode(), hashlib.sha256).hexdigest()
        req = urllib.request.Request(
            base + "/api/v1/detect", data=payload.encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + key,
                     "x-tool": "claude-code", "X-Straiker-Webhook-Signature": sig,
                     "X-Straiker-Webhook-Timestamp": ts, "Straiker-Debug": "TRUE"})
        rec = {"ts": time.time(), "event": event,
               "session_id": d.get("session_id"), "tool_name": d.get("tool_name")}
        try:
            resp = json.load(urllib.request.urlopen(req, timeout=10))
            rec.update({"http": 200, "score": resp.get("score"),
                        "score_category": resp.get("score_category"),
                        "action": resp.get("action"), "severity": resp.get("severity"),
                        "reason": resp.get("reason"), "turn_id": resp.get("turn_id")})
        except urllib.error.HTTPError as e:
            rec.update({"http": e.code, "err": e.read().decode()[:200]})
        except Exception as e:
            rec.update({"http": None, "err": str(e)[:200]})
        with open(detect_log, "a") as f:
            f.write(json.dumps(rec) + "\n")

    # Safety: for attack scenarios (STRAIKER_FORCE_BLOCK=1), deny every PreToolUse
    # so the risky command is captured + scored but NEVER executed. Exit 2 blocks
    # the tool even under --dangerously-skip-permissions.
    if os.environ.get("STRAIKER_FORCE_BLOCK") == "1" and event in ("PreToolUse", "PermissionRequest"):
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": event,
            "permissionDecision": "deny",
            "permissionDecisionReason": "lab: attack scenario — tool execution suppressed"}}))
        sys.exit(2)

    # monitor mode: never block
    sys.exit(0)


if __name__ == "__main__":
    main()
