"""A fake vLLM. CLIENT ONBOARDING FIXTURE — never run this in production.

Purpose, stated narrowly on purpose: configuring opencode, aider and Claude Code
against the gateway, issuing keys to teammates, and checking the metadata.user
convention reads right in the spend log. That is hours of fiddling, and doing it
against a live pod bills a GPU that is doing nothing. Here it is free.

It needs no change to config.yaml, because ENGINE_API_BASE was already an
environment variable — so what you configure clients against is byte-identical
to what the office server will run.

What this stub can HONESTLY establish (verify.sh grades these):
  - LiteLLM forwards extra_body upstream as top-level chat_template_kwargs.
    Real signal, because the stub echoes back what actually arrived on the wire
    and cannot fake LiteLLM having sent something it did not send. Worth
    verifying rather than assuming: if the forwarding fails, the coder /
    coder-max split is a silent no-op — a bigger bill, not an error.
  - The engine secret is sent and enforced (wrong secret -> 401), so a rotation
    that fails to take effect is loud rather than silent.
  - Streaming works end to end, which is the path agents actually use.

What it CANNOT establish, and no stub ever will — do not add checks for these:
  - tool_calls: this file returns well-formed calls BY CONSTRUCTION. The real
    failure is a wrong parser returning prose, which a stub cannot exhibit. A
    check that can only pass is worse than no check.
  - the coder / coder-max behaviour split: honouring enable_thinking here proves
    only that this file honours it, not that vLLM does.
  - vllm:num_requests_running: the stub exposes whatever name is hardcoded
    below. The real risk is vLLM renaming it across versions.
  - model quality, throughput, TTFT, KV-cache sizing, VRAM headroom, and whether
    vLLM took the hybrid-attention path at all.

Those need real hardware. Phase B, ~$1.60 of L40S time.
"""

import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENGINE_SECRET = os.environ.get("ENGINE_SECRET", "")
SERVED_NAME = os.environ.get("SERVED_MODEL_NAME", "coder")
# Seconds of simulated generation. Non-zero so num_requests_running is
# observable and the drain loop in gpu-down.sh has something to wait for.
LATENCY = float(os.environ.get("MOCK_LATENCY", "0.4"))

_lock = threading.Lock()
_running = 0


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass  # quiet; the gateway logs what matters

    # ------------------------------------------------------------ helpers

    def _send(self, code, payload, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self):
        # The real engine's --api-key. Checking it here is what makes the
        # secret-rotation path in gpu-up.sh testable: a stale gateway secret
        # must fail loudly rather than silently working.
        if not ENGINE_SECRET:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {ENGINE_SECRET}"

    # ------------------------------------------------------------ GET

    def do_GET(self):
        if self.path == "/__mock__":
            # verify.sh probes this so it can label the run loudly. A green
            # test suite against a stub must never read as a verified engine.
            return self._send(200, {"mock": True, "warning": "not a real engine"})

        if self.path.rstrip("/") == "/metrics":
            with _lock:
                n = _running
            # Prometheus text format, matching the metric gpu-down.sh greps for.
            return self._send(
                200,
                f"# HELP vllm:num_requests_running Number of requests currently running.\n"
                f"# TYPE vllm:num_requests_running gauge\n"
                f"vllm:num_requests_running {float(n)}\n".encode(),
                "text/plain; version=0.0.4",
            )

        if self.path.rstrip("/") in ("/health", "/ping"):
            return self._send(200, {"status": "ok"})

        if self.path.rstrip("/") == "/v1/models":
            if not self._authed():
                return self._send(401, {"error": {"message": "bad engine secret"}})
            return self._send(200, {
                "object": "list",
                "data": [{"id": SERVED_NAME, "object": "model", "owned_by": "mock"}],
            })

        return self._send(404, {"error": {"message": "not found"}})

    # ------------------------------------------------------------ POST

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._send(404, {"error": {"message": "not found"}})
        if not self._authed():
            return self._send(401, {"error": {"message": "bad engine secret"}})

        n = int(self.headers.get("Content-Length", 0))
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._send(400, {"error": {"message": "bad json"}})

        # THE check this stub exists for. LiteLLM's extra_body must land here as
        # a top-level key; if it does not, the coder / coder-max split is a
        # no-op and both aliases think. Verify this rather than
        # assume it — this is where that happens.
        kwargs = req.get("chat_template_kwargs") or {}
        thinking = bool(kwargs.get("enable_thinking", False))
        tools = req.get("tools") or []
        stream = bool(req.get("stream", False))

        global _running
        with _lock:
            _running += 1
        try:
            time.sleep(LATENCY)
            if stream:
                return self._stream(thinking, tools, kwargs)
            return self._once(thinking, tools, kwargs)
        finally:
            with _lock:
                _running -= 1

    # ------------------------------------------------------------ responses

    def _message(self, thinking, tools, kwargs):
        seen = f"[mock engine] chat_template_kwargs={json.dumps(kwargs)}"
        if tools:
            # A wrong tool-call parser returns prose here instead. Emitting
            # real structured tool_calls is what lets verify.sh tell the
            # difference — and aider would NOT surface that failure, because it
            # uses text diffs.
            name = tools[0].get("function", {}).get("name", "unknown")
            msg = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "call_mock_1",
                    "type": "function",
                    "function": {"name": name, "arguments": json.dumps({"city": "Berlin"})},
                }],
            }
        else:
            msg = {"role": "assistant", "content": f"4 x 4 = 16. {seen}"}
        if thinking:
            # Separated from content, never embedded as a raw <think> block —
            # that is what --reasoning-parser qwen3 does on the real engine.
            msg["reasoning_content"] = "Let me work through this. 17 x 23 = 391."
        return msg

    def _once(self, thinking, tools, kwargs):
        msg = self._message(thinking, tools, kwargs)
        self._send(200, {
            "id": "chatcmpl-mock",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": SERVED_NAME,
            "choices": [{
                "index": 0,
                "message": msg,
                # Never "length": an empty content with finish_reason=length is
                # the failure mode a too-tight cap produces, and the stub must
                # not fake it by accident.
                "finish_reason": "tool_calls" if tools else "stop",
            }],
            "usage": {"prompt_tokens": 24, "completion_tokens": 32, "total_tokens": 56},
        })

    def _stream(self, thinking, tools, kwargs):
        # Agents stream. A stub that only answered non-streaming would leave the
        # path they actually use untested.
        msg = self._message(thinking, tools, kwargs)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {
                "id": "chatcmpl-mock", "object": "chat.completion.chunk",
                "created": int(time.time()), "model": SERVED_NAME,
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
            }
            self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()

        chunk({"role": "assistant"})
        if thinking:
            chunk({"reasoning_content": msg["reasoning_content"]})
        if msg.get("tool_calls"):
            chunk({"tool_calls": [dict(tc, index=0) for tc in msg["tool_calls"]]})
            chunk({}, "tool_calls")
        else:
            for word in (msg["content"] or "").split(" "):
                chunk({"content": word + " "})
            chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    port = int(os.environ.get("MOCK_PORT", "8000"))
    print(f"[mock engine] serving '{SERVED_NAME}' on :{port} — NOT A REAL ENGINE", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
