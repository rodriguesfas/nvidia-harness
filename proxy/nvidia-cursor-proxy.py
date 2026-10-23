#!/usr/bin/env python3
"""Shim Cursor Agent → NVIDIA NIM + pool grátis do OpenCode (LiteLLM).

Cursor envia content em lista de partes ({type,text}) e, em modelos openai/*,
às vezes o formato Responses API. A NIM (Harmony/vLLM) exige content string
e /v1/chat/completions. Sem este shim o Agent devolve 400 Pydantic.

Ids curtos do free-router (coder, fast, …) vão para NH_FREE_ROUTER_URL
(default http://127.0.0.1:4000); o resto continua na NVIDIA.
"""
from __future__ import annotations

import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

UPSTREAM = os.environ.get("NVIDIA_ORIGIN", "https://integrate.api.nvidia.com").rstrip("/")
FREE_ROUTER = os.environ.get("NH_FREE_ROUTER_URL", "http://127.0.0.1:4000").rstrip("/")
LISTEN = (
    os.environ.get("NH_CURSOR_PROXY_HOST", "127.0.0.1"),
    int(os.environ.get("NH_CURSOR_PROXY_PORT", "12436")),
)
FREE_ROUTER_MODELS = frozenset(
    {
        "coder",
        "fast",
        "gemini-flash",
        "gemini-lite",
        "mistral-medium",
        "mistral-small",
        "codestral",
        "openrouter-free",
        "openrouter-qwen3.8-free",
        "openrouter-nemotron-super-free",
        "groq-gpt-oss-120b",
        "groq-gpt-oss-20b",
        "groq-qwen3.8-27b",
        "local-qwen7b",
        "local-qwen3b",
    }
)
GPT_OSS_20B_MAX_TOKENS = 4096
HOP_BY_HOP = {
    "host",
    "content-length",
    "connection",
    "transfer-encoding",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "upgrade",
}


def _env_files() -> list[Path]:
    files: list[Path] = []
    for raw in (
        os.environ.get("NH_ENVF"),
        os.environ.get("NH_FREE_ROUTER_ENV"),
        str(Path.home() / ".config/nvidia-harness/env"),
        str(Path.home() / ".config/nvidia-harness/proxy.env"),
    ):
        if not raw:
            continue
        p = Path(raw)
        if p.is_file() and p not in files:
            files.append(p)
    return files


def _key_from_files(name: str) -> str:
    prefix = name + "="
    for path in _env_files():
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("export "):
                line = line[7:].strip()
            if line.startswith(prefix):
                return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def load_litellm_key() -> str:
    return (os.environ.get("LITELLM_MASTER_KEY") or "").strip() or _key_from_files(
        "LITELLM_MASTER_KEY"
    )


def flatten_content(content):
    if content is None:
        return None
    if isinstance(content, str):
        return content
    if isinstance(content, (int, float, bool)):
        return str(content)
    if isinstance(content, dict):
        if "text" in content:
            return content.get("text") or ""
        if content.get("type") in {"text", "input_text", "output_text"}:
            return content.get("text") or ""
        return json.dumps(content, ensure_ascii=False)
    if isinstance(content, (list, tuple)):
        parts = []
        for item in content:
            flat = flatten_content(item)
            if flat:
                parts.append(flat)
        return "".join(parts)
    return str(content)


def normalize_message(msg: dict) -> dict:
    out = dict(msg)
    if "content" in out or out.get("role") == "tool":
        out["content"] = flatten_content(out.get("content"))
        if out.get("role") == "tool" and out.get("content") is None:
            out["content"] = ""
    if out.get("role") == "developer":
        out["role"] = "system"
    return out


def responses_input_to_messages(inp) -> list[dict]:
    messages: list[dict] = []
    pending: list[dict] = []

    def flush_tools() -> None:
        if not pending:
            return
        messages.append(
            {
                "role": "assistant",
                "content": None,
                "tool_calls": list(pending),
            }
        )
        pending.clear()

    for item in inp or []:
        if not isinstance(item, dict):
            continue
        typ = item.get("type")
        role = item.get("role")
        if role in {"system", "user", "assistant", "developer"} and typ not in {
            "function_call",
            "function_call_output",
            "tool_call",
            "tool_result",
        }:
            flush_tools()
            content = flatten_content(item.get("content"))
            mapped = "system" if role == "developer" else role
            messages.append({"role": mapped, "content": content})
            continue
        if typ in {"function_call", "tool_call"}:
            fn = item.get("function") or {}
            pending.append(
                {
                    "id": item.get("call_id") or item.get("id") or "call_1",
                    "type": "function",
                    "function": {
                        "name": item.get("name") or fn.get("name"),
                        "arguments": item.get("arguments") or fn.get("arguments") or "{}",
                    },
                }
            )
            continue
        if typ in {"function_call_output", "tool_result"} or role == "tool":
            flush_tools()
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": item.get("call_id")
                    or item.get("tool_call_id")
                    or item.get("id"),
                    "content": flatten_content(item.get("output") or item.get("content"))
                    or "",
                }
            )
    flush_tools()
    return messages


def filter_tools(tools):
    if not isinstance(tools, list):
        return tools
    kept = []
    for tool in tools:
        if not isinstance(tool, dict):
            continue
        typ = tool.get("type")
        if typ == "custom":
            continue
        fn = tool.get("function")
        if typ in {None, "function"} or fn:
            if not fn:
                fn = {
                    "name": tool.get("name"),
                    "description": tool.get("description"),
                    "parameters": tool.get("parameters") or tool.get("input_schema") or {},
                }
            if not fn.get("name"):
                continue
            kept.append({"type": "function", "function": fn})
    return kept


def normalize_payload(payload: dict, path: str) -> tuple[dict, str]:
    body = dict(payload)
    out_path = path

    if "messages" not in body and isinstance(body.get("input"), list):
        body["messages"] = responses_input_to_messages(body.pop("input"))
        if out_path.rstrip("/").endswith("/responses"):
            out_path = "/v1/chat/completions"

    if isinstance(body.get("messages"), list):
        body["messages"] = [
            normalize_message(m) if isinstance(m, dict) else m for m in body["messages"]
        ]

    if "tools" in body:
        body["tools"] = filter_tools(body["tools"])
        if body["tools"] == []:
            body.pop("tools", None)
            body.pop("tool_choice", None)

    model = str(body.get("model") or "")
    if "gpt-oss-20b" in model and isinstance(body.get("max_tokens"), (int, float)):
        if body["max_tokens"] > GPT_OSS_20B_MAX_TOKENS:
            body["max_tokens"] = GPT_OSS_20B_MAX_TOKENS

    if out_path.rstrip("/").endswith("/responses"):
        out_path = "/v1/chat/completions"
    return body, out_path


def canonical_free_router_model(model: str) -> str | None:
    name = (model or "").strip()
    for prefix in ("opencode/", "free-router/", "oc/"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    if name in FREE_ROUTER_MODELS:
        return name
    return None


def canonical_nim_model(model: str) -> str:
    """Picker usa nvidia/…; a NIM ainda espera o id do catálogo."""
    name = (model or "").strip()
    if name.startswith("nvidia/openai/"):
        return "openai/" + name[len("nvidia/openai/") :]
    if name.startswith("nvidia/meta/"):
        return "meta/" + name[len("nvidia/meta/") :]
    return name


def merge_model_lists(nvidia: dict | None, free: dict | None, router_up: bool) -> dict:
    by_id: dict[str, dict] = {}
    for blob in (nvidia, free):
        if not isinstance(blob, dict):
            continue
        for item in blob.get("data") or []:
            if isinstance(item, dict) and item.get("id"):
                by_id[str(item["id"])] = item
    if router_up:
        for name in sorted(FREE_ROUTER_MODELS):
            public = "opencode/" + name
            by_id.setdefault(
                public,
                {"id": public, "object": "model", "owned_by": "opencode"},
            )
    return {"object": "list", "data": list(by_id.values())}


def _selftest() -> None:
    cursor_tool = {
        "role": "tool",
        "tool_call_id": "call_1",
        "content": [{"type": "text", "text": "18 degrees"}],
    }
    assert normalize_message(cursor_tool)["content"] == "18 degrees"

    payload = {
        "model": "openai/gpt-oss-20b",
        "max_tokens": 32000,
        "input": [
            {"role": "user", "content": [{"type": "text", "text": "hi"}]},
            {
                "type": "function_call",
                "call_id": "c1",
                "name": "read",
                "arguments": "{}",
            },
            {
                "type": "function_call_output",
                "call_id": "c1",
                "output": [{"type": "input_text", "text": "ok"}],
            },
        ],
        "tools": [
            {"type": "function", "function": {"name": "read", "parameters": {}}},
            {"type": "custom", "custom": {"name": "cursor"}},
        ],
    }
    body, path = normalize_payload(payload, "/v1/responses")
    assert path == "/v1/chat/completions"
    assert body["messages"][0]["content"] == "hi"
    assert body["messages"][1]["tool_calls"][0]["function"]["name"] == "read"
    assert body["messages"][2]["role"] == "tool"
    assert body["messages"][2]["content"] == "ok"
    assert body["max_tokens"] == GPT_OSS_20B_MAX_TOKENS
    assert all(t.get("type") == "function" for t in body["tools"])
    assert canonical_free_router_model("coder") == "coder"
    assert canonical_free_router_model("opencode/fast") == "fast"
    assert canonical_free_router_model("free-router/fast") == "fast"
    assert canonical_free_router_model("openai/gpt-oss-20b") is None
    assert canonical_nim_model("nvidia/openai/gpt-oss-20b") == "openai/gpt-oss-20b"
    assert canonical_nim_model("nvidia/nemotron-3-ultra-550b-a55b") == (
        "nvidia/nemotron-3-ultra-550b-a55b"
    )
    assert canonical_nim_model("nvidia/nemotron-3.5-super-vl-120b-a12b") == (
        "nvidia/nemotron-3.5-super-vl-120b-a12b"
    )
    merged = merge_model_lists(
        {"data": [{"id": "nvidia/nemotron-3-ultra-550b-a55b"}]},
        {"data": [{"id": "coder"}]},
        True,
    )
    ids = {m["id"] for m in merged["data"]}
    assert "opencode/coder" in ids and "opencode/fast" in ids
    assert "nvidia/nemotron-3-ultra-550b-a55b" in ids
    print("selftest ok")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

    def _forward_headers(self) -> dict[str, str]:
        return {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}

    def _json_response(self, code: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _fetch_json(self, url: str, headers: dict[str, str], timeout: int = 12):
        req = urllib.request.Request(url, headers=headers, method="GET")
        ctx = ssl.create_default_context() if url.startswith("https://") else None
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
                raw = resp.read()
            return json.loads(raw.decode("utf-8") or "{}"), True
        except Exception:  # noqa: BLE001 — catálogo é best-effort
            return None, False

    def _send_merged_models(self) -> None:
        headers = self._forward_headers()
        nvidia, _ = self._fetch_json(UPSTREAM + "/v1/models", headers)
        free_headers = dict(headers)
        key = load_litellm_key()
        if key:
            free_headers["Authorization"] = "Bearer " + key
        free, router_up = self._fetch_json(FREE_ROUTER + "/v1/models", free_headers, timeout=3)
        if not router_up:
            # /models do LiteLLM às vezes 500; o chat ainda pode responder.
            try:
                urllib.request.urlopen(FREE_ROUTER + "/", timeout=2)
                router_up = True
            except Exception:
                router_up = False
        self._json_response(200, merge_model_lists(nvidia, free, router_up))

    def _send_upstream(
        self,
        method: str,
        path: str,
        body: bytes | None,
        *,
        base: str = UPSTREAM,
        auth: str | None = None,
    ) -> None:
        url = base + path
        headers = self._forward_headers()
        if body is not None:
            headers["Content-Type"] = headers.get("Content-Type", "application/json")
        if auth:
            headers["Authorization"] = auth
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        ctx = ssl.create_default_context() if base.startswith("https://") else None
        try:
            with urllib.request.urlopen(req, timeout=600, context=ctx) as resp:
                self.send_response(resp.status)
                for key, value in resp.headers.items():
                    if key.lower() not in HOP_BY_HOP | {"content-length"}:
                        self.send_header(key, value)
                self.end_headers()
                while True:
                    chunk = resp.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except urllib.error.HTTPError as err:
            data = err.read()
            self.send_response(err.code)
            ctype = err.headers.get("Content-Type", "application/json")
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as exc:  # noqa: BLE001 — last-mile proxy
            data = json.dumps({"error": {"message": str(exc), "type": "proxy_error"}}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path.rstrip("/").endswith("/models"):
            self._send_merged_models()
            return
        self._send_upstream("GET", self.path, None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        path = self.path.split("?", 1)[0]
        if path.endswith("/chat/completions") or path.endswith("/responses"):
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                self._send_upstream(self.command, self.path, raw)
                return
            if not isinstance(payload, dict):
                self._send_upstream(self.command, self.path, raw)
                return
            body, out_path = normalize_payload(payload, path)
            free_name = canonical_free_router_model(str(body.get("model") or ""))
            if free_name:
                body["model"] = free_name
                raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
                key = load_litellm_key()
                auth = f"Bearer {key}" if key else None
                self._send_upstream("POST", out_path, raw, base=FREE_ROUTER, auth=auth)
                return
            body["model"] = canonical_nim_model(str(body.get("model") or ""))
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self._send_upstream("POST", out_path, raw)
            return
        self._send_upstream(self.command, self.path, raw)

    do_PUT = do_POST
    do_DELETE = do_GET


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
        sys.exit(0)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    print(
        f"nvidia-cursor-proxy on http://{LISTEN[0]}:{LISTEN[1]} "
        f"-> {UPSTREAM} | free-router {FREE_ROUTER}",
        flush=True,
    )
    httpd.serve_forever()
