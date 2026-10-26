#!/usr/bin/env python3
"""Espera o inspector do ngrok e grava a URL HTTPS pública do shim Cursor."""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

INSPECT = os.environ.get("NH_NGROK_INSPECT", "http://127.0.0.1:4040/api/tunnels")
OUT = Path(
    os.environ.get(
        "NH_CURSOR_PUBLIC_URL_FILE",
        Path.home() / ".config/nvidia-harness/cursor-public-url",
    )
)


def tunnels() -> list[str]:
    try:
        with urllib.request.urlopen(INSPECT, timeout=2) as resp:
            data = json.loads(resp.read().decode("utf-8") or "{}")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return []
    urls: list[str] = []
    for item in data.get("tunnels") or []:
        if not isinstance(item, dict):
            continue
        url = str(item.get("public_url") or "")
        if url.startswith("https://"):
            urls.append(url.rstrip("/") + "/v1")
    return urls


def main() -> int:
    deadline = time.monotonic() + float(os.environ.get("NH_TUNNEL_WAIT", "20"))
    found: list[str] = []
    while time.monotonic() < deadline:
        found = tunnels()
        if found:
            break
        time.sleep(0.4)
    if not found:
        print("tunnel url: (timeout)", file=sys.stderr)
        return 1
    url = found[0]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(url + "\n", encoding="utf-8")
    OUT.chmod(0o600)
    print("tunnel url:", url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
