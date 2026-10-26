#!/usr/bin/env python3
"""Grava BYOK NVIDIA no state.vscdb do Cursor quando a IDE não está aberta.

Com a janela aberta o processo reescreve a memória por cima. Este script
só altera o sqlite se o Cursor não estiver a correr (ou com --force).
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
CONFIG = Path(os.environ.get("NH_CONFIG_DIR", HOME / ".config/nvidia-harness"))
DESIRED = CONFIG / "cursor-byok.json"
ENVF = Path(os.environ.get("NH_ENVF", CONFIG / "env"))
STATE_DB = HOME / ".config/Cursor/User/globalStorage/state.vscdb"
APPUSER = (
    "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl"
    ".persistentStorage.applicationUser"
)
SECRET_KEY = "secret://cursorAuth/openAIKey"
PROXY_URL = "http://127.0.0.1:12436/v1"


def cursor_running() -> bool:
    checks = (
        ["pgrep", "-x", "cursor"],
        ["pgrep", "-f", "/usr/share/cursor/cursor"],
    )
    for cmd in checks:
        r = subprocess.run(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if r.returncode == 0:
            return True
    return False


def read_key() -> str:
    for name in ("NVIDIA_NIM_API_KEY", "NVIDIA_API_KEY", "CURSOR_API_KEY"):
        val = (os.environ.get(name) or "").strip()
        if val:
            return val
    if not ENVF.is_file():
        return ""
    prefix = "NVIDIA_NIM_API_KEY="
    for raw in ENVF.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if line.startswith("export "):
            line = line[7:].strip()
        if line.startswith(prefix):
            return line.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def desired_state() -> dict:
    data = {
        "openAIBaseUrl": PROXY_URL,
        "useOpenAIKey": True,
        "userAddedModels": [],
    }
    if DESIRED.is_file():
        blob = json.loads(DESIRED.read_text(encoding="utf-8"))
        if isinstance(blob, dict):
            data.update(blob)
    models = data.get("userAddedModels") or []
    if isinstance(models, str):
        models = models.split()
    data["userAddedModels"] = [m for m in models if m]
    data["openAIBaseUrl"] = data.get("openAIBaseUrl") or PROXY_URL
    data["useOpenAIKey"] = True
    return data


def encrypt_secret(api_key: str) -> str | None:
    try:
        import secretstorage
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    except Exception:
        return None
    pw = None
    bus = secretstorage.dbus_init()
    for col in secretstorage.get_all_collections(bus):
        for item in col.get_all_items():
            if item.get_attributes().get("application") == "Cursor":
                pw = item.get_secret()
                break
        if pw:
            break
    if not pw:
        return None
    key = PBKDF2HMAC(algorithm=hashes.SHA1(), length=16, salt=b"saltysalt", iterations=1).derive(pw)
    raw = api_key.encode()
    pad = 16 - len(raw) % 16
    raw += bytes([pad]) * pad
    enc = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
    blob = b"v11" + enc.update(raw) + enc.finalize()
    return json.dumps({"type": "Buffer", "data": list(blob)})


def apply(force: bool) -> int:
    if not force and cursor_running():
        print("skip: Cursor aberto (a IDE reverteria o sqlite)")
        return 0
    if not STATE_DB.is_file():
        print("skip: state.vscdb ausente")
        return 0
    want = desired_state()
    models = want["userAddedModels"]
    if not models:
        print("skip: cursor-byok.json sem modelos")
        return 0
    con = sqlite3.connect(str(STATE_DB), timeout=30)
    con.execute("PRAGMA busy_timeout=30000")
    row = con.execute("select value from ItemTable where key=?", (APPUSER,)).fetchone()
    data = json.loads(row[0]) if row else {}
    ai = data.setdefault("aiSettings", {})
    enabled = list(ai.get("modelOverrideEnabled") or [])
    for m in models:
        if m not in enabled:
            enabled.append(m)
    ai["userAddedModels"] = models
    ai["modelOverrideEnabled"] = enabled
    data["useOpenAIKey"] = True
    data["openAIBaseUrl"] = want["openAIBaseUrl"]
    value = json.dumps(data, ensure_ascii=False)
    if row:
        con.execute("update ItemTable set value=? where key=?", (value, APPUSER))
    else:
        con.execute("insert into ItemTable (key, value) values (?, ?)", (APPUSER, value))
    api_key = read_key()
    secret_ok = False
    if api_key:
        blob = encrypt_secret(api_key)
        if blob:
            secret_row = con.execute(
                "select 1 from ItemTable where key=?", (SECRET_KEY,)
            ).fetchone()
            if secret_row:
                con.execute(
                    "update ItemTable set value=? where key=?", (blob, SECRET_KEY)
                )
            else:
                con.execute(
                    "insert into ItemTable (key, value) values (?, ?)",
                    (SECRET_KEY, blob),
                )
            secret_ok = True
    con.commit()
    con.close()
    print(
        "applied:",
        want["openAIBaseUrl"],
        "models=",
        len(models),
        "secret_ok=",
        int(secret_ok),
    )
    return 0


if __name__ == "__main__":
    force = "--force" in sys.argv
    raise SystemExit(apply(force))
