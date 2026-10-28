#!/usr/bin/env python3
"""Injeta Funnel URL + NH_COLAB_REGISTER_TOKEN no notebook .ready.ipynb (local).

Uso:
  python3 bin/prepare-colab-notebook.py
  # abre notebooks/colab_cursor_coder.ready.ipynb → Kernel Colab (GPU) → Run All
"""
from __future__ import annotations

import json
import re
import secrets
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "notebooks" / "colab_cursor_coder.ipynb"
DST = ROOT / "notebooks" / "colab_cursor_coder.ready.ipynb"
PROXY_ENV = Path.home() / ".config/nvidia-harness/proxy.env"


def funnel_base() -> str:
    try:
        out = subprocess.check_output(
            ["tailscale", "funnel", "status"],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        out = ""
    m = re.search(r"https://[a-zA-Z0-9.-]+\.ts\.net", out)
    if m:
        return m.group(0).rstrip("/")
    tun = Path.home() / ".config/nvidia-harness/bin/cursor-tunnel-url.py"
    if tun.is_file():
        try:
            u = subprocess.check_output(
                ["python3", str(tun)],
                text=True,
                stderr=subprocess.DEVNULL,
                timeout=5,
            ).strip()
            return u.rstrip("/").removesuffix("/v1")
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass
    return ""


def ensure_token() -> str:
    lines: list[str] = []
    if PROXY_ENV.is_file():
        lines = PROXY_ENV.read_text(encoding="utf-8", errors="replace").splitlines()
    for line in lines:
        if line.startswith("NH_COLAB_REGISTER_TOKEN=") and line.split("=", 1)[1].strip():
            return line.split("=", 1)[1].strip()
    tok = secrets.token_urlsafe(24)
    lines = [ln for ln in lines if not ln.startswith("NH_COLAB_REGISTER_TOKEN=")]
    lines.append(f"NH_COLAB_REGISTER_TOKEN={tok}")
    PROXY_ENV.parent.mkdir(parents=True, exist_ok=True)
    PROXY_ENV.write_text("\n".join(lines) + "\n", encoding="utf-8")
    PROXY_ENV.chmod(0o600)
    return tok


def main() -> int:
    if not SRC.is_file():
        print(f"ausente: {SRC}", file=sys.stderr)
        return 1
    base = funnel_base()
    if not base:
        print("Funnel/túnel Cursor ausente — ./install.sh cursor --yes primeiro", file=sys.stderr)
        return 1
    token = ensure_token()
    nb = json.loads(SRC.read_text(encoding="utf-8"))
    config_src = (
        "# @nh-register-config — gerado por bin/prepare-colab-notebook.py (não commits)\n"
        f'REGISTER_BASE = "{base}"\n'
        f'REGISTER_TOKEN = "{token}"\n'
        'MODEL = "Qwen/Qwen2.5-Coder-3B-Instruct"\n'
        "PORT = 8001\n"
        "print(\"REGISTER_BASE\", REGISTER_BASE)\n"
        "print(\"MODEL\", MODEL, \"PORT\", PORT)\n"
    )
    # Substitui célula MODEL/PORT (índice 2 no template) por config+model.
    cells = nb.get("cells") or []
    if len(cells) < 3:
        print("notebook inesperado", file=sys.stderr)
        return 1
    cells[2]["source"] = [ln + "\n" for ln in config_src.splitlines()]
    cells[2]["outputs"] = []
    cells[2]["execution_count"] = None

    DST.write_text(json.dumps(nb, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"ok: {DST}")
    print(f"  Funnel : {base}")
    print(f"  picker : google-colab-qwen2.5-coder-3b (após Run All no Colab)")
    print("Abre o .ready.ipynb → Select Kernel → Colab (GPU) → Run All")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
