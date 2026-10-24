#!/usr/bin/env python3
"""Patch DeepSeek Harness (dsh) config without putting secrets in cordis YAML.

stdlib only. Upserts:
  - agent-default-model + providers.nvidia in ~/.dsh/profiles/web/cordis.patch.yml
  - refs.NVIDIA_API_KEY in ~/.dsh/.credentials.yaml (quoted; other refs kept)

The dsh credential store wins over process env. cordis.patch.yml only names
apiKeyEnv: NVIDIA_API_KEY — never the nvapi value.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

DEFAULT_ENTRY_ID = "agent-default-model"
DEFAULT_ENTRY_NAME = "@deepseek-ai/dsh-agent-default-model"
LLM_ENTRY_ID = "llm-pi-ai"
LLM_ENTRY_NAME = "@deepseek-ai/dsh-llm-pi-ai"


def _indent_of(line: str) -> int:
    if line.strip() == "":
        return -1
    return len(line) - len(line.lstrip(" "))


def render_nvidia_provider(models: list[dict[str, str]]) -> str:
    lines = [
        "      nvidia:",
        "        displayName: NVIDIA NIM",
        "        apiKeyEnv: NVIDIA_API_KEY",
        "        models:",
    ]
    for m in models:
        mid = str(m["id"]).strip()
        name = str(m.get("name") or mid).strip()
        if not mid:
            continue
        lines.append(f"          - id: {mid}")
        lines.append(f"            name: {name}")
    return "\n".join(lines) + "\n"


def render_default_entry(model_id: str) -> str:
    return (
        f"- id: {DEFAULT_ENTRY_ID}\n"
        f"  name: \"{DEFAULT_ENTRY_NAME}\"\n"
        "  config:\n"
        "    provider: nvidia\n"
        f"    model: {model_id}\n"
    )


def render_llm_entry(nvidia_block: str) -> str:
    return (
        f"- id: {LLM_ENTRY_ID}\n"
        f"  name: \"{LLM_ENTRY_NAME}\"\n"
        "  config:\n"
        "    providers:\n"
        f"{nvidia_block}"
    )


def _replace_entry(text: str, entry_id: str, new_entry: str) -> str:
    """Replace a top-level `- id: …` block, or append if missing."""
    lines = text.splitlines(keepends=True)
    start = None
    for i, line in enumerate(lines):
        if re.match(rf"^- id: {re.escape(entry_id)}\s*$", line):
            start = i
            break
    new_lines = [ln if ln.endswith("\n") else ln + "\n" for ln in new_entry.splitlines()]
    if not new_lines:
        return text
    if start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        return text + "".join(new_lines)
    end = start + 1
    while end < len(lines):
        if lines[end].startswith("- id:"):
            break
        end += 1
    return "".join(lines[:start] + new_lines + lines[end:])


def _replace_mapping(lines: list[str], start: int, key_indent: int, new_block: str) -> list[str]:
    end = start + 1
    while end < len(lines):
        raw = lines[end]
        stripped = raw.strip()
        if stripped == "" or stripped.startswith("#"):
            indent = _indent_of(raw)
            if stripped.startswith("#") and indent != -1 and indent <= key_indent:
                break
            end += 1
            continue
        if _indent_of(raw) <= key_indent:
            break
        end += 1
    new_lines = [ln if ln.endswith("\n") else ln + "\n" for ln in new_block.splitlines()]
    return lines[:start] + new_lines + lines[end:]


def upsert_nvidia_provider(text: str, nvidia_block: str) -> str:
    lines = text.splitlines(keepends=True)
    llm_start = None
    for i, line in enumerate(lines):
        if re.match(rf"^- id: {re.escape(LLM_ENTRY_ID)}\s*$", line):
            llm_start = i
            break
    if llm_start is None:
        if text and not text.endswith("\n"):
            text += "\n"
        return text + render_llm_entry(nvidia_block)

    llm_end = llm_start + 1
    while llm_end < len(lines) and not lines[llm_end].startswith("- id:"):
        llm_end += 1
    region = lines[llm_start:llm_end]

    nvidia_idx = None
    for j, line in enumerate(region):
        if re.match(r"^      nvidia:\s*$", line):
            nvidia_idx = j
            break
    if nvidia_idx is not None:
        region = _replace_mapping(region, nvidia_idx, 6, nvidia_block)
    else:
        providers_idx = None
        for j, line in enumerate(region):
            if re.match(r"^    providers:\s*$", line):
                providers_idx = j
                break
        new_lines = [ln if ln.endswith("\n") else ln + "\n" for ln in nvidia_block.splitlines()]
        if providers_idx is None:
            # append a providers: section at the end of the llm-pi-ai entry
            insert_at = len(region)
            if region and region[-1].strip() == "":
                insert_at -= 1
            extra = ["  config:\n", "    providers:\n"] if not any(
                r.startswith("  config:") for r in region
            ) else ["    providers:\n"]
            region = region[:insert_at] + extra + new_lines + region[insert_at:]
        else:
            region = region[: providers_idx + 1] + new_lines + region[providers_idx + 1 :]
    return "".join(lines[:llm_start] + region + lines[llm_end:])


def patch_cordis(text: str, default_model: str, models: list[dict[str, str]]) -> str:
    stripped = text.strip()
    # Perfil stock do dsh é um array vazio; não dá para appendar entradas ao lado.
    if stripped in ("", "[]"):
        text = (
            "# dsh profile patches (nvidia-harness)\n"
            + render_default_entry(default_model)
            + render_llm_entry(render_nvidia_provider(models))
        )
        return text if text.endswith("\n") else text + "\n"
    if not text.endswith("\n") and text:
        text += "\n"
    nvidia_block = render_nvidia_provider(models)
    text = _replace_entry(text, DEFAULT_ENTRY_ID, render_default_entry(default_model))
    text = upsert_nvidia_provider(text, nvidia_block)
    return text


def upsert_credential_ref(text: str, name: str, value: str) -> str:
    quoted = json.dumps(value, ensure_ascii=False)
    assignment = f"{name}: {quoted}"
    if not text:
        return f"version: 1\nrefs:\n  {assignment}\n"
    if not text.endswith("\n"):
        text += "\n"
    pat = re.compile(rf"(?m)^([ \t]*){re.escape(name)}:[ \t]*.*$")
    if pat.search(text):
        return pat.sub(lambda m: f"{m.group(1)}{assignment}", text, count=1)
    if re.search(r"(?m)^refs:\s*$", text):
        return re.sub(r"(?m)^refs:\s*$", f"refs:\n  {assignment}", text, count=1)
    if re.search(r"(?m)^refs:\s*\{\}\s*$", text):
        return re.sub(r"(?m)^refs:\s*\{\}\s*$", f"refs:\n  {assignment}", text, count=1)
    return text + f"refs:\n  {assignment}\n"


def write_file(path: Path, body: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body, encoding="utf-8")
    os.chmod(path, mode)


def selftest() -> None:
    sample = """# patch
- id: ui-settings-general
  name: "@deepseek-ai/dsh-client-ui-settings-general"
  config:
    welcomeNoticeVersion: 1
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: nvidia
    model: moonshotai/kimi-k3
- id: llm-pi-ai
  name: "@deepseek-ai/dsh-llm-pi-ai"
  config:
    providers:
      local-coder:
        displayName: Qwen Coder local
        api: openai-completions
        baseURL: http://127.0.0.1:12434/v1
      nvidia:
        apiKeyEnv: NVIDIA_API_KEY
        models:
          - id: moonshotai/kimi-k3
            name: Kimi K3
- id: mcp-ai-memory
  name: "@deepseek-ai/dsh-mcp-client"
  config:
    serverName: ai-memory
"""
    models = [
        {"id": "nvidia/nemotron-3.5-super-vl-120b-a12b", "name": "Nemotron 3.5 Super VL 120B"},
        {"id": "z-ai/glm-5.3", "name": "GLM-5.3"},
    ]
    out = patch_cordis(sample, "nvidia/nemotron-3.5-super-vl-120b-a12b", models)
    assert "local-coder:" in out, "preserva local-coder"
    assert "mcp-ai-memory" in out, "preserva entradas irmãs"
    assert "moonshotai/kimi-k3" not in out, "remove id morto"
    assert "nvidia/nemotron-3.5-super-vl-120b-a12b" in out
    assert "z-ai/glm-5.3" in out
    assert "displayName: NVIDIA NIM" in out
    assert "apiKeyEnv: NVIDIA_API_KEY" in out
    assert "nvapi-" not in out, "YAML sem secret"
    creds = upsert_credential_ref(
        "version: 1\nrecords: {}\nrefs:\n  DEEPSEEK_API_KEY: sk-old\n",
        "NVIDIA_API_KEY",
        "nvapi-TEST",
    )
    assert "DEEPSEEK_API_KEY: sk-old" in creds
    assert 'NVIDIA_API_KEY: "nvapi-TEST"' in creds
    empty = patch_cordis("[]\n", "z-ai/glm-5.3", models[:1])
    assert "- id: agent-default-model" in empty
    assert "- id: llm-pi-ai" in empty
    assert empty.strip() != "[]"
    print("dsh-patch selftest ok")


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--selftest":
        selftest()
        return 0
    if not argv or argv[0] not in ("cordis", "credential"):
        print(
            "uso: dsh-patch.py cordis <patch.yml> <default-id> <models.json>\n"
            "     dsh-patch.py credential <creds.yml> <REF_NAME>\n"
            "     dsh-patch.py --selftest\n"
            "credential lê o valor de NH_API_KEY (não passa na linha de comando).",
            file=sys.stderr,
        )
        return 2
    if argv[0] == "cordis":
        path = Path(argv[1])
        default_model = argv[2]
        models = json.loads(Path(argv[3]).read_text(encoding="utf-8"))
        if isinstance(models, dict):
            models = models.get("models") or []
        original = path.read_text(encoding="utf-8") if path.is_file() else ""
        write_file(path, patch_cordis(original, default_model, models), 0o644)
        return 0
    path = Path(argv[1])
    name = argv[2]
    value = os.environ.get("NH_API_KEY", "")
    if not value:
        print("dsh-patch.py: NH_API_KEY vazio", file=sys.stderr)
        return 1
    original = path.read_text(encoding="utf-8") if path.is_file() else ""
    write_file(path, upsert_credential_ref(original, name, value), 0o600)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
