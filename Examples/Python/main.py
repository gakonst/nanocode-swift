import ctypes
import json
import sys
import tempfile
import threading

SESSION = "01900000-0000-7000-8000-000000000002"

library = ctypes.CDLL(sys.argv[1])
Callback = ctypes.CFUNCTYPE(None, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t)
library.nanocode_start.restype = ctypes.c_void_p
library.nanocode_start.argtypes = [ctypes.c_char_p, ctypes.c_size_t, Callback, ctypes.c_void_p]
library.nanocode_send.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
library.nanocode_stop.argtypes = [ctypes.c_void_p]

opened = threading.Event()
finished = threading.Event()
failed = []


def send(message):
    data = json.dumps(message).encode()
    library.nanocode_send(runtime, data, len(data))


def note(lucky, id):
    print("[tool] Python received", {"lucky": lucky, "id": id})
    return "noted"


@Callback
def receive(_context, data, length):
    message = json.loads(ctypes.string_at(data, length))
    if "call" in message:
        call = message["call"]
        if call["kind"] == "tool":
            send({"command": {"reply": {"id": call["id"], "ok": note(**call["body"]["input"])}}})
        else:
            send({"command": {"reply": {"id": call["id"], "error": "this program does not answer that call"}}})
    if message.get("reply") == 1:
        if "error" in message:
            failed.append(message)
        opened.set()
    if "fatal" in message or (message.get("reply") == 2 and "error" in message):
        failed.append(message)
        finished.set()
    event = message.get("event", {})
    for logged in event.get("logged", []):
        inner = logged["event"].get("event", {})
        if inner.get("type") == "assistant.message":
            print("[assistant]", inner["payload"].get("text"))
    status = event.get("turn", {}).get("report", {}).get("status")
    if status in ("completed", "failed"):
        print("[turn]", status)
        finished.set()


config = json.dumps({"data_dir": tempfile.mkdtemp(prefix="libnanocode-"), "shell": sys.argv[3]}).encode()
runtime = library.nanocode_start(config, len(config), receive, None)
send({"id": 1, "command": {"open": {
    "session_id": SESSION, "provider": "claude", "model": "claude-haiku-5-5", "endpoint": sys.argv[2],
    "auth": {"api_key": "test"}, "workspace_tools": "none", "web_search": False,
    "tools": [{"name": "note", "description": "Records a number.", "parameters": {
        "type": "object", "properties": {"lucky": {"type": "number"}, "id": {"type": "string"}},
        "required": ["lucky", "id"]}}],
}}})
opened.wait()
if not failed:
    send({"id": 2, "command": {"submit": {"session": SESSION, "request_id": "turn-1", "prompt": "Note a number."}}})
    finished.wait()
library.nanocode_stop(runtime)
for message in failed:
    print("[error]", message)
sys.exit(1 if failed else 0)
