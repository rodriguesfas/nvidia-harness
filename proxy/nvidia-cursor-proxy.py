#!/usr/bin/env python3
"""Shim Cursor Agent → NVIDIA NIM + pool grátis do OpenCode (LiteLLM) + Colab.

Cursor envia content em lista de partes ({type,text}) e, em modelos openai/*,
às vezes o formato Responses API. A NIM (Harmony/vLLM) exige content string
e /v1/chat/completions. Sem este shim o Agent devolve 400 Pydantic.

Ids curtos do free-router (coder, fast, …) vão para NH_FREE_ROUTER_URL
(default http://127.0.0.1:4000). Prefixo colab/… (ou ids em COLAB_MODELS)
vai para NH_COLAB_URL (vLLM/llama.cpp no Google Colab via túnel HTTPS).
O resto continua na NVIDIA.
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
COLAB = (os.environ.get("NH_COLAB_URL") or "").rstrip("/")
COLAB_MODEL = (
    os.environ.get("NH_COLAB_MODEL") or "Qwen/Qwen2.5-Coder-3B-Instruct"
).strip()
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
        "cloudflare-llama31-8b",
        "cloudflare-gpt-oss-20b",
        "local-qwen7b",
        "local-qwen3b",
    }
)
# Atalhos no picker Cursor → reescritos para NH_COLAB_MODEL no upstream Colab.
COLAB_ALIASES = frozenset({"coder", "qwen-coder", "colab-coder"})
GPT_OSS_20B_MAX_TOKENS = 4096
PROXY_ENV_PATH = Path.home() / ".config/nvidia-harness/proxy.env"
BYOK_JSON_PATH = Path.home() / ".config/nvidia-harness/cursor-byok.json"
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


def load_colab_key() -> str:
    return (os.environ.get("NH_COLAB_API_KEY") or "").strip() or _key_from_files(
        "NH_COLAB_API_KEY"
    )


def colab_base() -> str:
    return (os.environ.get("NH_COLAB_URL") or COLAB or "").rstrip("/")


def colab_upstream_model() -> str:
    return (
        os.environ.get("NH_COLAB_MODEL") or COLAB_MODEL or "Qwen/Qwen2.5-Coder-3B-Instruct"
    ).strip()


def colab_picker_id(hf_model: str | None = None) -> str:
    """Qwen/Qwen2.5-Coder-3B-Instruct → google-colab-qwen2.5-coder-3b."""
    raw = (hf_model or colab_upstream_model()).strip()
    name = raw.split("/")[-1] if raw else "coder"
    # Mantém pontos (2.5); só troca o resto de não-alfanumérico por '-'.
    slug = "".join(ch.lower() if (ch.isalnum() or ch == ".") else "-" for ch in name)
    while "--" in slug:
        slug = slug.replace("--", "-")
    slug = slug.strip("-.") or "coder"
    for suf in ("-instruct", "-chat", "-it"):
        if slug.endswith(suf):
            slug = slug[: -len(suf)]
            break
    return f"google-colab-{slug}"


def load_register_token() -> str:
    return (os.environ.get("NH_COLAB_REGISTER_TOKEN") or "").strip() or _key_from_files(
        "NH_COLAB_REGISTER_TOKEN"
    )


def _upsert_env_file(path: Path, updates: dict[str, str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    if path.is_file():
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        if not line or line.lstrip().startswith("#") or "=" not in line:
            out.append(line)
            continue
        key = line.split("=", 1)[0].strip()
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)
    for key, val in updates.items():
        if key not in seen:
            out.append(f"{key}={val}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    path.chmod(0o600)


def persist_colab_registration(url: str, model: str) -> str:
    """Atualiza env em memória + proxy.env + cursor-byok.json. Devolve picker id."""
    global COLAB, COLAB_MODEL
    url = url.rstrip("/").removesuffix("/v1")
    model = (model or colab_upstream_model()).strip()
    os.environ["NH_COLAB_URL"] = url
    os.environ["NH_COLAB_MODEL"] = model
    COLAB = url
    COLAB_MODEL = model
    _upsert_env_file(
        PROXY_ENV_PATH,
        {"NH_COLAB_URL": url, "NH_COLAB_MODEL": model},
    )
    picker = colab_picker_id(model)
    models: list[str] = []
    if BYOK_JSON_PATH.is_file():
        try:
            blob = json.loads(BYOK_JSON_PATH.read_text(encoding="utf-8"))
            if isinstance(blob, dict):
                raw = blob.get("userAddedModels") or []
                if isinstance(raw, str):
                    raw = raw.split()
                models = [str(m) for m in raw if m]
        except (OSError, json.JSONDecodeError):
            models = []
    for alias in (picker, "colab/coder", f"google-colab/{model}"):
        if alias not in models:
            models.append(alias)
    public = ""
    try:
        import subprocess

        tun = Path.home() / ".config/nvidia-harness/bin/cursor-tunnel-url.py"
        if tun.is_file():
            public = subprocess.check_output(
                ["python3", str(tun)], text=True, stderr=subprocess.DEVNULL, timeout=5
            ).strip()
    except Exception:
        public = ""
    payload = {
        "openAIBaseUrl": public or "http://127.0.0.1:12436/v1",
        "useOpenAIKey": True,
        "userAddedModels": models,
    }
    BYOK_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
    BYOK_JSON_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    BYOK_JSON_PATH.chmod(0o600)
    return picker


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


def canonical_colab_model(model: str) -> str | None:
    """Picker google-colab-* / colab/coder → id HF no vLLM (NH_COLAB_MODEL)."""
    if not colab_base():
        return None
    name = (model or "").strip()
    picker = colab_picker_id()
    if name == picker or name in {f"google-colab-{a}" for a in COLAB_ALIASES}:
        return colab_upstream_model()
    for prefix in ("colab/", "google-colab/", "gc/"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
            break
    else:
        if name not in COLAB_ALIASES and name != "colab-coder":
            return None
    if not name or name in COLAB_ALIASES:
        return colab_upstream_model()
    return name


def canonical_nim_model(model: str) -> str:
    """Picker usa nvidia/…; a NIM ainda espera o id do catálogo."""
    name = (model or "").strip()
    if name.startswith("nvidia/openai/"):
        return "openai/" + name[len("nvidia/openai/") :]
    if name.startswith("nvidia/meta/"):
        return "meta/" + name[len("nvidia/meta/") :]
    return name


def merge_model_lists(
    nvidia: dict | None,
    free: dict | None,
    router_up: bool,
    *,
    colab_up: bool = False,
) -> dict:
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
    if colab_up:
        picker = colab_picker_id()
        by_id.setdefault(
            picker,
            {"id": picker, "object": "model", "owned_by": "google-colab"},
        )
        by_id.setdefault(
            "colab/coder",
            {"id": "colab/coder", "object": "model", "owned_by": "colab"},
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
    os.environ["NH_COLAB_URL"] = "http://127.0.0.1:9"
    os.environ["NH_COLAB_MODEL"] = "Qwen/Qwen2.5-Coder-3B-Instruct"
    assert colab_picker_id("Qwen/Qwen2.5-Coder-3B-Instruct") == (
        "google-colab-qwen2.5-coder-3b"
    )
    assert canonical_colab_model("colab/coder") == "Qwen/Qwen2.5-Coder-3B-Instruct"
    assert canonical_colab_model("google-colab-qwen2.5-coder-3b") == (
        "Qwen/Qwen2.5-Coder-3B-Instruct"
    )
    assert (
        canonical_colab_model("colab/Qwen/Qwen2.5-Coder-7B-Instruct")
        == "Qwen/Qwen2.5-Coder-7B-Instruct"
    )
    assert canonical_colab_model("opencode/fast") is None
    os.environ.pop("NH_COLAB_URL", None)
    assert canonical_colab_model("colab/coder") is None
    os.environ["NH_COLAB_URL"] = "http://127.0.0.1:9"
    merged = merge_model_lists(
        {"data": [{"id": "nvidia/nemotron-3-ultra-550b-a55b"}]},
        {"data": [{"id": "coder"}]},
        True,
        colab_up=True,
    )
    ids = {m["id"] for m in merged["data"]}
    assert "opencode/coder" in ids and "opencode/fast" in ids
    assert "colab/coder" in ids
    assert "google-colab-qwen2.5-coder-3b" in ids
    assert "nvidia/nemotron-3-ultra-550b-a55b" in ids
    os.environ.pop("NH_COLAB_URL", None)
    print("selftest ok")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args), flush=True)

    def _forward_headers(self) -> dict[str, str]:
        return {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}

    def _json_response(self, code: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            return

    def _bearer_ok(self) -> bool:
        raw = (self.headers.get("Authorization") or self.headers.get("authorization") or "").strip()
        if not raw.lower().startswith("bearer "):
            return False
        return bool(raw.split(None, 1)[-1].strip())

    def _reject_unauthorized(self) -> None:
        self._json_response(
            401,
            {
                "error": {
                    "message": "Missing Authorization bearer token",
                    "type": "invalid_request_error",
                    "code": "unauthorized",
                }
            },
        )

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
        colab_up = False
        base = colab_base()
        if base:
            colab_headers = dict(headers)
            ckey = load_colab_key()
            if ckey:
                colab_headers["Authorization"] = "Bearer " + ckey
            _, colab_up = self._fetch_json(base + "/v1/models", colab_headers, timeout=4)
            if not colab_up:
                try:
                    ctx = ssl.create_default_context() if base.startswith("https://") else None
                    urllib.request.urlopen(base + "/health", timeout=2, context=ctx)
                    colab_up = True
                except Exception:
                    colab_up = bool(base)
        self._json_response(
            200, merge_model_lists(nvidia, free, router_up, colab_up=colab_up)
        )

    def _send_upstream(
        self,
        method: str,
        path: str,
        body: bytes | None,
        *,
        base: str | None = None,
        auth: str | None = None,
    ) -> None:
        # UPSTREAM/FREE_ROUTER no momento da chamada (self-test troca os globais).
        base = (base or UPSTREAM).rstrip("/")
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
        except (BrokenPipeError, ConnectionResetError):
            return
        except urllib.error.HTTPError as err:
            data = err.read()
            try:
                self.send_response(err.code)
                ctype = err.headers.get("Content-Type", "application/json")
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                return
        except Exception as exc:  # noqa: BLE001 — last-mile proxy
            data = json.dumps({"error": {"message": str(exc), "type": "proxy_error"}}).encode()
            try:
                self.send_response(502)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                return

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path in {"/health", "/v1/health", "/healthz"}:
            self._json_response(
                200,
                {
                    "ok": True,
                    "upstream": UPSTREAM,
                    "free_router": FREE_ROUTER,
                    "colab": colab_base() or None,
                    "colab_model": colab_upstream_model() if colab_base() else None,
                },
            )
            return
        if path.endswith("/models"):
            self._send_merged_models()
            return
        self._send_upstream("GET", self.path, None)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        path = self.path.split("?", 1)[0]
        clean = path.rstrip("/")
        if clean.endswith("/colab/register") or clean.endswith("/v1/colab/register"):
            want = load_register_token()
            if not want:
                self._json_response(
                    503,
                    {
                        "error": {
                            "message": "NH_COLAB_REGISTER_TOKEN ausente no proxy.env",
                            "type": "proxy_error",
                            "code": "colab_register_unconfigured",
                        }
                    },
                )
                return
            auth = (self.headers.get("Authorization") or "").strip()
            got = auth.split(None, 1)[-1].strip() if auth.lower().startswith("bearer ") else ""
            if got != want:
                self._reject_unauthorized()
                return
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except json.JSONDecodeError:
                self._json_response(
                    400,
                    {"error": {"message": "JSON inválido", "type": "invalid_request_error"}},
                )
                return
            url = str((payload or {}).get("url") or "").strip()
            model = str(
                (payload or {}).get("model") or colab_upstream_model()
            ).strip()
            if not url.startswith("https://"):
                self._json_response(
                    400,
                    {
                        "error": {
                            "message": "url tem de ser https://… (trycloudflare/ngrok)",
                            "type": "invalid_request_error",
                        }
                    },
                )
                return
            host = url.split("://", 1)[-1].split("/", 1)[0].lower()
            allowed = (
                host.endswith(".trycloudflare.com")
                or host.endswith(".ngrok-free.app")
                or host.endswith(".ngrok.io")
                or host.endswith(".ngrok.app")
            )
            if not allowed:
                self._json_response(
                    400,
                    {
                        "error": {
                            "message": f"host não permitido: {host}",
                            "type": "invalid_request_error",
                        }
                    },
                )
                return
            picker = persist_colab_registration(url, model)
            self._json_response(
                200,
                {
                    "ok": True,
                    "colab": colab_base(),
                    "colab_model": colab_upstream_model(),
                    "picker": picker,
                    "hint": "Fecha o Cursor uns segundos (timer BYOK) ou: ./install.sh cursor --yes",
                },
            )
            return
        if path.endswith("/chat/completions") or path.endswith("/responses"):
            if not self._bearer_ok():
                self._reject_unauthorized()
                return
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
            colab_name = canonical_colab_model(str(body.get("model") or ""))
            if colab_name:
                base = colab_base()
                if not base:
                    self._json_response(
                        502,
                        {
                            "error": {
                                "message": "NH_COLAB_URL não configurado no proxy",
                                "type": "proxy_error",
                                "code": "colab_unconfigured",
                            }
                        },
                    )
                    return
                body["model"] = colab_name
                raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
                ckey = load_colab_key()
                auth = f"Bearer {ckey}" if ckey else "Bearer sk-colab"
                self._send_upstream("POST", out_path, raw, base=base, auth=auth)
                return
            body["model"] = canonical_nim_model(str(body.get("model") or ""))
            raw = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self._send_upstream("POST", out_path, raw)
            return
        self._send_upstream(self.command, self.path, raw)

    do_PUT = do_POST
    do_DELETE = do_GET


def _http_selftest() -> None:
    """Sobe o shim e dois upstreams mock numa porta efémera. Sem rede NVIDIA."""
    import threading
    import time

    nvidia_posts: list[dict] = []
    free_posts: list[dict] = []
    colab_posts: list[dict] = []
    nvidia_gets: list[str] = []

    class _Mock(BaseHTTPRequestHandler):
        bucket: list
        gets: list

        def log_message(self, *_args):
            return

        def do_GET(self):
            self.gets.append(self.path)
            data = json.dumps(
                {"object": "list", "data": [{"id": "openai/gpt-oss-20b"}]}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            self.bucket.append(json.loads(raw.decode("utf-8") or "{}"))
            data = json.dumps(
                {"choices": [{"message": {"role": "assistant", "content": "ok"}}]}
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    def _spawn(bucket: list, gets: list) -> ThreadingHTTPServer:
        class Bound(_Mock):
            pass

        Bound.bucket = bucket
        Bound.gets = gets
        httpd = ThreadingHTTPServer(("127.0.0.1", 0), Bound)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        return httpd

    nvidia = _spawn(nvidia_posts, nvidia_gets)
    free = _spawn(free_posts, [])
    colab = _spawn(colab_posts, [])
    nvidia_url = f"http://127.0.0.1:{nvidia.server_address[1]}"
    free_url = f"http://127.0.0.1:{free.server_address[1]}"
    colab_url = f"http://127.0.0.1:{colab.server_address[1]}"

    global UPSTREAM, FREE_ROUTER
    old_up, old_free = UPSTREAM, FREE_ROUTER
    old_colab = os.environ.get("NH_COLAB_URL")
    old_colab_model = os.environ.get("NH_COLAB_MODEL")
    old_log = Handler.log_message
    UPSTREAM, FREE_ROUTER = nvidia_url, free_url
    os.environ["NH_COLAB_URL"] = colab_url
    os.environ["NH_COLAB_MODEL"] = "Qwen/Qwen2.5-Coder-3B-Instruct"
    Handler.log_message = lambda *_a, **_k: None  # noqa: ARG005 — silêncio no teste
    proxy = None
    try:
        proxy = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{proxy.server_address[1]}"
        time.sleep(0.05)

        started = time.monotonic()
        for path in ("/health", "/v1/health", "/healthz"):
            with urllib.request.urlopen(base + path, timeout=2) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
            assert resp.status == 200
            assert payload.get("ok") is True
            assert payload.get("upstream") == nvidia_url
            assert payload.get("colab") == colab_url
        assert time.monotonic() - started < 1.0
        assert nvidia_gets == [], "GET /health não pode falar com a NVIDIA"

        unauth = urllib.request.Request(
            base + "/v1/chat/completions",
            data=b'{"model":"x","messages":[]}',
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(unauth, timeout=5)
            raise AssertionError("POST sem Bearer tinha de ser 401")
        except urllib.error.HTTPError as err:
            assert err.code == 401
            denied = json.loads(err.read().decode("utf-8"))
            assert denied["error"]["code"] == "unauthorized"
        assert nvidia_posts == [], "401 não pode chegar à NIM"

        harmony = {
            "model": "nvidia/openai/gpt-oss-20b",
            "max_tokens": 8,
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "hi"}]}
            ],
        }
        req = urllib.request.Request(
            base + "/v1/chat/completions",
            data=json.dumps(harmony).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            out = json.loads(resp.read().decode("utf-8"))
        assert out["choices"][0]["message"]["content"] == "ok"
        assert nvidia_posts, "mock NIM não recebeu POST"
        assert nvidia_posts[0]["model"] == "openai/gpt-oss-20b"
        assert nvidia_posts[0]["messages"][0]["content"] == "hi"
        assert free_posts == []

        free_body = {
            "model": "opencode/fast",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "yo"}]}
            ],
        }
        req = urllib.request.Request(
            base + "/v1/chat/completions",
            data=json.dumps(free_body).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            json.loads(resp.read().decode("utf-8"))
        assert free_posts, "mock free-router não recebeu POST"
        assert free_posts[0]["model"] == "fast"
        assert free_posts[0]["messages"][0]["content"] == "yo"
        assert len(nvidia_posts) == 1

        colab_body = {
            "model": "colab/coder",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "gpu"}]}
            ],
        }
        req = urllib.request.Request(
            base + "/v1/chat/completions",
            data=json.dumps(colab_body).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Authorization": "Bearer test",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            json.loads(resp.read().decode("utf-8"))
        assert colab_posts, "mock Colab não recebeu POST"
        assert colab_posts[0]["model"] == "Qwen/Qwen2.5-Coder-3B-Instruct"
        assert colab_posts[0]["messages"][0]["content"] == "gpu"
        assert len(nvidia_posts) == 1
        assert len(free_posts) == 1
    finally:
        UPSTREAM, FREE_ROUTER = old_up, old_free
        if old_colab is None:
            os.environ.pop("NH_COLAB_URL", None)
        else:
            os.environ["NH_COLAB_URL"] = old_colab
        if old_colab_model is None:
            os.environ.pop("NH_COLAB_MODEL", None)
        else:
            os.environ["NH_COLAB_MODEL"] = old_colab_model
        Handler.log_message = old_log
        for srv in (proxy, nvidia, free, colab):
            if srv is None:
                continue
            srv.shutdown()
            srv.server_close()
    print("http selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
        _http_selftest()
        sys.exit(0)
    httpd = ThreadingHTTPServer(LISTEN, Handler)
    colab_info = colab_base() or "(off)"
    print(
        f"nvidia-cursor-proxy on http://{LISTEN[0]}:{LISTEN[1]} "
        f"-> {UPSTREAM} | free-router {FREE_ROUTER} | colab {colab_info}",
        flush=True,
    )
    httpd.serve_forever()
