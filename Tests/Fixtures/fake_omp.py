#!/usr/bin/env python3
import sys
import json
import time

def main():
    args = sys.argv[1:]

    # Simulation modes via CLI flags
    if "--fail-handshake" in args:
        # Exit immediately with non-zero exit code
        sys.stderr.write("Simulated handshake crash\n")
        sys.stderr.flush()
        sys.exit(2)

    if "--ready-timeout" in args:
        # Sleep without emitting ready frame
        time.sleep(30)
        sys.exit(0)

    # Normal ready announcement
    ready_frame = {
        "type": "ready",
        "protocolVersion": 1,
        "supportedProtocolVersions": [1, 2],
        "maxFrameBytes": 1048576,
        "maxReassembledBytes": 67108864
    }
    sys.stdout.write(json.dumps(ready_frame) + "\n")
    sys.stdout.flush()

    active_model = "openai-codex/gpt-6.1-sol"
    for i, a in enumerate(args):
        if a.startswith("--model="):
            active_model = a.split("=", 1)[1]
        elif a == "--model" and i + 1 < len(args):
            active_model = args[i + 1]

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue

        try:
            cmd = json.loads(line)
        except Exception:
            continue

        cmd_id = cmd.get("id", "c_0")
        cmd_type = cmd.get("type", "")

        if cmd_type == "negotiate_protocol":
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "negotiate_protocol",
                "success": True,
                "data": {"protocolVersion": 2}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        elif cmd_type == "set_host_tools":
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "set_host_tools",
                "success": True,
                "data": {}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        elif cmd_type == "get_state":
            reported_model = active_model
            if "--model-mismatch" in args:
                reported_model = "unwanted-provider/fallback-model"

            parts = reported_model.split("/", 1)
            provider = parts[0] if len(parts) > 1 else ""
            m_id = parts[1] if len(parts) > 1 else reported_model

            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "get_state",
                "success": True,
                "data": {
                    "model": {
                        "id": m_id,
                        "provider": provider
                    },
                    "sessionFile": "/tmp/homelab-desk-test-session.jsonl",
                    "sessionId": "test-session-123",
                    "usageLimit": {
                        "tier": "scale",
                        "remaining": 100
                    }
                }
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        elif cmd_type == "get_available_models":
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "get_available_models",
                "success": True,
                "data": {
                    "models": [
                        {
                            "id": "gpt-6.1-sol",
                            "provider": "openai-codex",
                            "name": "GPT-6.1 Sol",
                            "reasoning": True,
                            "contextWindow": 128000
                        },
                        {
                            "id": "claude-3.7-sonnet",
                            "provider": "anthropic",
                            "name": "Claude 3.7 Sonnet",
                            "reasoning": True,
                            "contextWindow": 200000
                        },
                        {
                            "id": "gemini-2.5-pro",
                            "provider": "google",
                            "name": "Gemini 2.5 Pro",
                            "reasoning": False,
                            "contextWindow": 1000000
                        }
                    ]
                }
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        elif cmd_type == "prompt":
            # Ack the prompt command
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "prompt",
                "success": True,
                "data": {}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

            if "--emit-stale-error" in args:
                # Emit a stale prompt_error with mismatched id
                stale_err = {
                    "type": "prompt_error",
                    "id": "stale_past_prompt_id",
                    "error": "This stale error belongs to an earlier prompt and must be ignored"
                }
                sys.stdout.write(json.dumps(stale_err) + "\n")
                sys.stdout.flush()

            # Emit agent_start
            sys.stdout.write(json.dumps({"type": "agent_start"}) + "\n")
            sys.stdout.flush()

            # Emit assistant delta
            upd_assistant = {
                "type": "message_update",
                "message": {
                    "role": "assistant",
                    "content": "Valid assistant answer"
                }
            }
            sys.stdout.write(json.dumps(upd_assistant) + "\n")
            sys.stdout.flush()

            # Emit non-assistant delta (e.g. user message echo) which client must filter out
            upd_user = {
                "type": "message_update",
                "message": {
                    "role": "user",
                    "content": "Stray echoed user content that must NOT overwrite assistant"
                }
            }
            sys.stdout.write(json.dumps(upd_user) + "\n")
            sys.stdout.flush()

            # Emit message_end for assistant
            end_assistant = {
                "type": "message_end",
                "message": {
                    "role": "assistant",
                    "content": "Valid assistant answer"
                }
            }
            sys.stdout.write(json.dumps(end_assistant) + "\n")
            sys.stdout.flush()

            # Correlated prompt_result
            p_result = {
                "type": "prompt_result",
                "id": cmd_id,
                "agentInvoked": True,
                "status": "completed",
                "sessionSettled": True
            }
            sys.stdout.write(json.dumps(p_result) + "\n")
            sys.stdout.flush()

        elif cmd_type == "abort":
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "abort",
                "success": True,
                "data": {}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        elif cmd_type == "new_session":
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": "new_session",
                "success": True,
                "data": {}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

        else:
            resp = {
                "type": "response",
                "id": cmd_id,
                "command": cmd_type,
                "success": True,
                "data": {}
            }
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
