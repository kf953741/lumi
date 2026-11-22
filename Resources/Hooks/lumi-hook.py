#!/usr/bin/env python3
"""Universal fast lifecycle hook relay for Lumi.

Supports:
  - Antigravity (PreInvocation, PreToolUse, PostToolUse, Stop)
  - Claude Code (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SessionEnd)
  - Codex CLI / Desktop (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, Interrupt)
  - Gemini CLI (BeforeAgent, BeforeTool, AfterTool, AfterAgent)
  - Cursor / OpenCode (custom hook payload)

Usage:
  lumi-hook.py --agent <antigravity|claude|codex|gemini|cursor|opencode> [EventName]

Writes atomic JSON state into ~/.lumi/live/<agent>__<sessionId>.json (<10ms).
Always outputs valid contract JSON for the host agent and exits 0 without blocking.
"""

import json
import os
import re
import sys
import time

LIVE_DIR = os.path.expanduser("~/.lumi/live")


def clean_line(text, limit=160):
    if not text:
        return ""
    s = str(text)
    m = re.search(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", s, re.S)
    if m:
        s = m.group(1)
    s = re.sub(r"\s+", " ", s).strip()
    if len(s) > limit:
        s = s[: limit - 1] + "…"
    return s


def normalize_event(raw):
    mapping = {
        "PreInvocation": "UserPromptSubmit",
        "BeforeAgent": "UserPromptSubmit",
        "BeforeTool": "PreToolUse",
        "BeforeToolSelection": "PreToolUse",
        "AfterTool": "PostToolUse",
        "PostInvocation": "PostToolUse",
        "AfterAgent": "Stop",
        "stop": "Stop",
        "session.idle": "Stop",
        "session.busy": "UserPromptSubmit",
        "PermissionRequest": "NeedsInput",
        "Elicitation": "NeedsInput",
        "Notification": "Notification",
    }
    return mapping.get(raw, raw)


def summarize_tool(name, args):
    name = str(name or "").strip()
    if not isinstance(args, dict):
        args = {}
    low = name.lower()

    if low in ("read_file", "view_file", "read"):
        p = args.get("Path") or args.get("AbsolutePath") or args.get("file_path") or args.get("path") or ""
        base = os.path.basename(str(p)) if p else ""
        return f"读取 {base}" if base else "读取文件"
    if low in ("write_file", "edit_file", "edit", "write", "multiedit", "replace_file_content", "multi_replace_file_content"):
        p = args.get("Path") or args.get("TargetFile") or args.get("file_path") or args.get("path") or ""
        base = os.path.basename(str(p)) if p else ""
        return f"编辑 {base}" if base else "修改文件"
    if "apply_edits" in low or "apply_patch" in low:
        edits = args.get("edits")
        if isinstance(edits, list) and edits and isinstance(edits[0], dict):
            first = os.path.basename(str(edits[0].get("path") or ""))
            suffix = f" 等 {len(edits)} 个文件" if len(edits) > 1 else ""
            return f"批量编辑 {first}{suffix}" if first else f"批量编辑 {len(edits)} 个文件"
        return "应用代码补丁"
    if low in ("run_command", "bash", "exec", "shell", "execute_command", "run_shell_command"):
        summary = clean_line(args.get("toolSummary") or args.get("description") or "", 42)
        cmd = clean_line(args.get("CommandLine") or args.get("command") or args.get("cmd") or "", 46)
        return f"执行 · {summary}" if summary else (f"运行 `{cmd}`" if cmd else "运行终端命令")
    if "run_checks" in low:
        summary = clean_line(args.get("toolSummary") or "", 42)
        return f"并行检查 · {summary}" if summary else "运行并行检查"
    if "search" in low or low in ("grep", "glob", "find_by_name", "batch_search"):
        summary = clean_line(args.get("toolSummary") or args.get("query") or args.get("pattern") or "", 38)
        if "web" in low:
            return f"联网搜索 · {summary}" if summary else "联网搜索"
        return f"检索 · {summary}" if summary else "检索代码"
    if "subagent" in low or low == "task" or low == "agent":
        role = clean_line(args.get("Role") or args.get("description") or args.get("TypeName") or "", 32)
        return f"派发子 Agent · {role}" if role else "派发子 Agent"
    if "browser" in low or "playwright" in low:
        return "操作浏览器"
    if low in ("ask_question", "askuserquestion"):
        return "等待你确认/回答"

    summary = clean_line(args.get("toolSummary") or "", 36)
    if summary:
        return f"{name} · {summary}"
    return f"调用 {name}" if name else ""


def parse_args():
    agent = "antigravity"
    event_arg = ""
    argv = sys.argv[1:]
    i = 0
    while i < len(argv):
        if argv[i] == "--agent" and i + 1 < len(argv):
            agent = argv[i + 1].strip().lower()
            i += 2
        else:
            event_arg = argv[i].strip()
            i += 1
    return agent, event_arg


def main():
    agent, event_arg = parse_args()
    raw = ""
    try:
        raw = sys.stdin.read()
    except Exception:
        pass

    payload = {}
    if raw:
        try:
            obj = json.loads(raw)
            if isinstance(obj, dict):
                payload = obj
        except Exception:
            pass

    raw_event = str(payload.get("hookEventName") or payload.get("hook_event_name") or event_arg or "")
    norm_event = normalize_event(raw_event)

    session_id = str(
        payload.get("conversationId")
        or payload.get("session_id")
        or payload.get("conversation_id")
        or payload.get("thread_id")
        or ""
    ).strip()

    if session_id:
        try:
            os.makedirs(LIVE_DIR, exist_ok=True)
            safe_id = re.sub(r"[^a-zA-Z0-9._-]", "_", session_id)
            path = os.path.join(LIVE_DIR, f"{agent}__{safe_id}.json")

            prev = {}
            if os.path.exists(path):
                try:
                    with open(path, "r", encoding="utf-8") as f:
                        loaded = json.load(f)
                        if isinstance(loaded, dict):
                            prev = loaded
                except Exception:
                    prev = {}

            now = time.time()
            rec = dict(prev)
            rec["agent"] = agent
            rec["sessionId"] = session_id
            rec["event"] = norm_event
            rec["rawEvent"] = raw_event
            rec["updatedAt"] = now

            cwd = payload.get("cwd") or ""
            ws = payload.get("workspacePaths") or payload.get("workspace_roots") or []
            if isinstance(ws, list) and ws:
                rec["workspacePaths"] = [str(p) for p in ws if p]
                if not cwd:
                    cwd = ws[0]
            if cwd:
                rec["cwd"] = str(cwd)
            if payload.get("transcriptPath") or payload.get("transcript_path"):
                rec["transcriptPath"] = str(payload.get("transcriptPath") or payload.get("transcript_path"))

            user_input = clean_line(
                payload.get("lastUserInput") or payload.get("prompt") or payload.get("user_prompt") or "",
                180,
            )
            if user_input:
                rec["lastUserInput"] = user_input
                if not rec.get("firstUserInput"):
                    rec["firstUserInput"] = user_input

            if payload.get("title") or payload.get("session_title"):
                rec["title"] = clean_line(payload.get("title") or payload.get("session_title"), 90)

            tool_call = payload.get("toolCall")
            if isinstance(tool_call, dict):
                t_name = tool_call.get("name") or ""
                t_args = tool_call.get("args") or {}
            else:
                t_name = payload.get("tool_name") or payload.get("toolName") or ""
                t_args = payload.get("tool_input") or payload.get("toolInput") or {}
            t_label = summarize_tool(t_name, t_args)

            if norm_event in ("SessionStart",):
                rec.setdefault("state", "idle")
            elif norm_event == "UserPromptSubmit":
                if prev.get("state") != "running" or not prev.get("turnStartedAt"):
                    rec["turnStartedAt"] = now
                rec["state"] = "running"
                rec["action"] = "思考规划中…"
                rec["terminationReason"] = ""
                rec["error"] = ""
            elif norm_event == "PreToolUse":
                if not rec.get("turnStartedAt"):
                    rec["turnStartedAt"] = now
                if str(t_name or "").lower() in ("ask_question", "askuserquestion"):
                    rec["state"] = "needs_input"
                    rec["action"] = "等待你确认/回答"
                else:
                    rec["state"] = "running"
                    if t_name:
                        rec["toolName"] = str(t_name)
                    if t_label:
                        rec["action"] = t_label
                        rec["lastToolLabel"] = t_label
            elif norm_event == "NeedsInput":
                rec["state"] = "needs_input"
                rec["action"] = f"等待确认 · {t_label}" if t_label else "等待你的审批或回复"
            elif norm_event == "Notification":
                ntype = str(payload.get("notification_type") or payload.get("type") or "").lower()
                nmsg = clean_line(payload.get("message") or payload.get("title") or "", 48)
                low_msg = nmsg.lower()
                if (
                    "permission" in ntype
                    or "elicitation" in ntype
                    or "input" in ntype
                    or "approval" in low_msg
                    or "permission" in low_msg
                    or "waiting" in low_msg
                ):
                    rec["state"] = "needs_input"
                    rec["action"] = f"等待确认 · {nmsg}" if nmsg else "等待你的审批或回复"
            elif norm_event == "PostToolUse":
                rec["state"] = "running"
                if t_label:
                    rec["lastToolLabel"] = t_label
                rec["action"] = "整理结果中…"
            elif norm_event in ("Interrupt",):
                rec["state"] = "canceled"
                rec["action"] = "已手动停止"
                rec["completedAt"] = now
                rec["turnStartedAt"] = 0
            elif norm_event == "Stop":
                reason = str(payload.get("terminationReason") or "")
                err = clean_line(payload.get("error") or "", 160)
                fully_idle = payload.get("fullyIdle", True)
                rec["terminationReason"] = reason
                rec["fullyIdle"] = bool(fully_idle)
                rec["error"] = err
                if reason == "ERROR" or err:
                    rec["completedAt"] = now
                    if rec.get("turnStartedAt"):
                        rec["durationSec"] = max(0.0, now - float(rec["turnStartedAt"]))
                    rec["state"] = "error"
                    rec["action"] = f"执行出错 · {err}" if err else "执行出错"
                    rec["turnStartedAt"] = 0
                elif reason == "USER_CANCELED":
                    rec["completedAt"] = now
                    rec["state"] = "canceled"
                    rec["action"] = "已手动停止"
                    rec["turnStartedAt"] = 0
                elif not fully_idle:
                    rec["state"] = "running"
                    rec["action"] = "等待后台任务/子 Agent 完成…"
                else:
                    rec["completedAt"] = now
                    if rec.get("turnStartedAt"):
                        rec["durationSec"] = max(0.0, now - float(rec["turnStartedAt"]))
                    rec["state"] = "done"
                    rec["action"] = "已完成"
                    rec["turnStartedAt"] = 0

            tmp = f"{path}.tmp.{os.getpid()}"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(rec, f, ensure_ascii=False)
            os.replace(tmp, path)
        except Exception:
            pass

    # Output host-specific valid JSON contract
    if agent == "antigravity":
        if raw_event == "PreToolUse":
            sys.stdout.write('{"decision":"allow"}\n')
        elif raw_event == "Stop":
            sys.stdout.write('{"decision":"stop"}\n')
        else:
            sys.stdout.write('{}\n')
        sys.stdout.flush()
    elif agent == "gemini":
        sys.stdout.write('{}\n')
        sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
