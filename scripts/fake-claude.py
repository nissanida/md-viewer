#!/usr/bin/env python3
"""A stand-in for `claude` in stream-json mode, for testing the chat panel
without an account or usage (development only):

    open -g -n --env MDV_AUTOMATION=1 --env MDV_CLAUDE_PATH="$PWD/scripts/fake-claude.py" \
        -a "MD Viewer.app" notes.md

What it does depends on words in the message:
  "append"   asks to edit the open document, then adds a line to it
  "command"  asks to run a shell command (and runs nothing)
  "slow"     writes slowly until stopped
  "login"    answers the way Claude Code does when it isn't signed in
Anything else gets a short reply in markdown.
"""
import json
import os
import re
import select
import sys
import time
import uuid

SESSION = str(uuid.uuid4())


def emit(message):
    print(json.dumps(message, ensure_ascii=False), flush=True)


def read(timeout=None):
    """The next message from the app, or None if none came within the timeout."""
    if timeout is not None and not select.select([sys.stdin], [], [], timeout)[0]:
        return None
    line = sys.stdin.readline()
    if not line:
        sys.exit(0)
    return json.loads(line)


def new_id(prefix):
    return prefix + uuid.uuid4().hex[:12]


def event(body):
    emit({"type": "stream_event", "event": body, "parent_tool_use_id": None, "session_id": SESSION, "uuid": str(uuid.uuid4())})


def assistant(content, message_id=None):
    emit({"type": "assistant", "message": {"id": message_id or new_id("msg_"), "type": "message", "role": "assistant",
                                            "model": "fake", "content": content, "stop_reason": None},
          "parent_tool_use_id": None, "session_id": SESSION, "uuid": str(uuid.uuid4())})


def say(text, delay=0.0):
    """Streams text word by word. Returns False if the app asked to stop."""
    message_id = new_id("msg_")
    event({"type": "message_start", "message": {"id": message_id, "type": "message", "role": "assistant", "content": []}})
    event({"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
    written = ""
    for word in re.findall(r"\S+\s*", text):
        event({"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": word}})
        written += word
        if delay:
            message = read(timeout=delay)
            if message and message.get("type") == "control_request" and message["request"].get("subtype") == "interrupt":
                emit({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": {}}})
                assistant([{"type": "text", "text": written}], message_id)
                return False
    event({"type": "content_block_stop", "index": 0})
    assistant([{"type": "text", "text": text}], message_id)
    return True


def use_tool(name, tool_input):
    """Calls a tool after asking the app. Returns (tool use id, allowed)."""
    tool_id = new_id("toolu_")
    assistant([{"type": "tool_use", "id": tool_id, "name": name, "input": tool_input}])
    request_id = str(uuid.uuid4())
    emit({"type": "control_request", "request_id": request_id,
          "request": {"subtype": "can_use_tool", "tool_name": name, "input": tool_input, "tool_use_id": tool_id}})
    while True:
        message = read()
        response = message.get("response", {})
        if message.get("type") == "control_response" and response.get("request_id") == request_id:
            return tool_id, response.get("response", {}).get("behavior") == "allow"


def tool_result(tool_id, text, is_error=False):
    block = {"type": "tool_result", "tool_use_id": tool_id, "content": text}
    if is_error:
        block["is_error"] = True
    emit({"type": "user", "message": {"role": "user", "content": [block]}, "parent_tool_use_id": None, "session_id": SESSION})


def finish(text, is_error=False):
    emit({"type": "result", "subtype": "success", "is_error": is_error, "result": text, "session_id": SESSION,
          "num_turns": 1, "duration_ms": 10})


def answer(text):
    emit({"type": "system", "subtype": "init", "session_id": SESSION, "cwd": os.getcwd(), "model": "fake", "tools": []})
    document = re.search(r"^Open document: (.+)$", text, re.MULTILINE)
    path = os.path.join(os.getcwd(), document.group(1)) if document else None
    request = text.split("</mdviewer-context>")[-1].lower()

    if "login" in request:
        assistant_error = {"type": "assistant", "message": {"id": new_id("msg_"), "type": "message", "role": "assistant", "model": "<synthetic>",
                                                            "content": [{"type": "text", "text": "Not logged in · Please run /login"}]},
                           "parent_tool_use_id": None, "session_id": SESSION, "error": "authentication_failed"}
        emit(assistant_error)
        return finish("Not logged in · Please run /login", is_error=True)

    if "append" in request and path:
        say("I'll add a line at the end.")
        with open(path, encoding="utf-8") as file:
            old = file.read()
        tool_id, allowed = use_tool("Edit", {"file_path": path, "old_string": old[-20:], "new_string": old[-20:] + "\n- added by the chat test\n"})
        if not allowed:
            tool_result(tool_id, "The user declined this action.", is_error=True)
            say("Okay, I left the document as it was.")
            return finish("Declined")
        with open(path, "w", encoding="utf-8") as file:
            file.write(old.rstrip("\n") + "\n- added by the chat test\n")
        tool_result(tool_id, f"The file {path} has been updated.")
        say("Added **one line** at the end of the list.")
        return finish("Added one line.")

    if "command" in request:
        tool_id, allowed = use_tool("Bash", {"command": "rm -rf build", "description": "Delete the build folder"})
        tool_result(tool_id, "The user declined this action." if not allowed else "(nothing ran: fake)", is_error=not allowed)
        say("You declined, so nothing ran." if not allowed else "Done.")
        return finish("Asked to run a command.")

    if "slow" in request:
        if not say("This reply is written slowly, one word at a time, so that Stop has something to stop. " * 4, delay=0.25):
            return finish("Request interrupted by user", is_error=True)
        return finish("Finished slowly.")

    say("שלום! This is the **fake** Claude.\n\n- It reads your message\n- It answers in markdown")
    finish("Replied.")


# The models a Pro plan listed in Claude Code 2.1.158.
MODELS = [
    {"value": "default", "displayName": "Default (recommended)", "description": "Sonnet 4.6 · Best for everyday tasks",
     "supportsEffort": True, "supportedEffortLevels": ["low", "medium", "high", "max"], "supportsAutoMode": True},
    {"value": "opus", "displayName": "Opus", "description": "Opus 4.8 · Most capable for complex work",
     "supportsEffort": True, "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"], "supportsAutoMode": True},
    {"value": "haiku", "displayName": "Haiku", "description": "Haiku 4.5 · Fastest for quick answers"},
]


def main():
    if os.environ.get("FAKE_CLAUDE_LOG"):  # how the app started it, for tests to check
        with open(os.environ["FAKE_CLAUDE_LOG"], "a", encoding="utf-8") as log:
            options = [arg for arg in sys.argv[1:] if not arg.startswith("You are running inside")]
            log.write("STARTED " + " ".join(options) + "\n=====\n")
    while True:
        message = read()
        kind = message.get("type")
        if kind == "control_request":
            subtype = message["request"].get("subtype")
            response = {"account": {"tokenSource": "fake"}, "models": MODELS} if subtype == "initialize" else {}
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": message["request_id"], "response": response}})
        elif kind == "user":
            content = message["message"]["content"]
            text = content if isinstance(content, str) else "".join(block.get("text", "") for block in content)
            if os.environ.get("FAKE_CLAUDE_LOG"):  # what the app sent, for tests to check
                with open(os.environ["FAKE_CLAUDE_LOG"], "a", encoding="utf-8") as log:
                    log.write(text + "\n=====\n")
            answer(text)


if __name__ == "__main__":
    main()
