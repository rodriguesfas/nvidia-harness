#!/usr/bin/env bash
# Instala e sobe o shim Cursor → NVIDIA NIM (+ pool OpenCode se :4000 estiver no ar).
# shellcheck shell=bash

NH_CURSOR_PROXY_PORT="${NH_CURSOR_PROXY_PORT:-12436}"
NH_CURSOR_PROXY_HOST="${NH_CURSOR_PROXY_HOST:-127.0.0.1}"
CURSOR_PROXY_URL="${CURSOR_PROXY_URL:-http://${NH_CURSOR_PROXY_HOST}:${NH_CURSOR_PROXY_PORT}/v1}"
NH_FREE_ROUTER_URL="${NH_FREE_ROUTER_URL:-http://127.0.0.1:4000}"
NH_PROXY_BIN="${NH_PROXY_BIN:-$NH_CONFIG_DIR/bin/nvidia-cursor-proxy.py}"
NH_PROXY_ENVF="${NH_PROXY_ENVF:-$NH_CONFIG_DIR/proxy.env}"
NH_PROXY_UNIT_NAME="nvidia-harness-cursor-proxy.service"
NH_PROXY_UNIT="${NH_PROXY_UNIT:-$HOME/.config/systemd/user/$NH_PROXY_UNIT_NAME}"
NH_PROXY_SRC="${NH_PROXY_SRC:-$NH_ROOT/proxy/nvidia-cursor-proxy.py}"

nh_cursor_proxy_url() {
  printf '%s' "$CURSOR_PROXY_URL"
}

nh_http_up() {
  local url="$1"
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "$url" || true)"
  case "$code" in
    200|401|404|405|500) return 0 ;;
    *) return 1 ;;
  esac
}

cursor_proxy_up() {
  nh_http_up "${CURSOR_PROXY_URL%/}/models"
}

nh_free_router_up() {
  nh_http_up "${NH_FREE_ROUTER_URL%/}/v1/models" \
    || nh_http_up "${NH_FREE_ROUTER_URL%/}/models" \
    || nh_http_up "${NH_FREE_ROUTER_URL%/}/"
}

# Lê KEY= de um env file (aceita `export KEY=`). Não imprime o arquivo inteiro.
nh_read_env_key() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 0
  python3 - "$file" "$name" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
prefix = name + "="
try:
    lines = open(path, encoding="utf-8", errors="replace")
except OSError:
    raise SystemExit(0)
for raw in lines:
    line = raw.strip()
    if line.startswith("export "):
        line = line[7:].strip()
    if line.startswith(prefix):
        print(line.split("=", 1)[1].strip().strip('"').strip("'"))
        break
PY
}

nh_detect_free_router_env() {
  local f key
  if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
    return 0
  fi
  for f in \
    "${NH_FREE_ROUTER_ENV:-}" \
    "$NH_ENVF" \
    "$NH_CONFIG_DIR/proxy.env" \
    "$HOME/.config/opencode-free-router/.env" \
    "$HOME/.config/nvidia-harness/free-router/.env"
  do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    key="$(nh_read_env_key "$f" LITELLM_MASTER_KEY || true)"
    if [ -n "$key" ]; then
      LITELLM_MASTER_KEY="$key"
      export LITELLM_MASTER_KEY
      NH_FREE_ROUTER_ENV="$f"
      export NH_FREE_ROUTER_ENV
      return 0
    fi
  done
  if has_cmd systemctl; then
    f="$(systemctl --user show -p EnvironmentFiles --value free-router.service 2>/dev/null | awk '{print $1}' | head -1 || true)"
    f="${f#-}"; f="${f%% *}"
    if [ -n "$f" ] && [ -f "$f" ]; then
      key="$(nh_read_env_key "$f" LITELLM_MASTER_KEY || true)"
      if [ -n "$key" ]; then
        LITELLM_MASTER_KEY="$key"
        export LITELLM_MASTER_KEY
        NH_FREE_ROUTER_ENV="$f"
        export NH_FREE_ROUTER_ENV
      fi
    fi
  fi
}

nh_try_start_free_router() {
  nh_free_router_up && return 0
  has_cmd systemctl || return 1
  systemctl --user is-enabled free-router.service >/dev/null 2>&1 \
    || systemctl --user list-unit-files free-router.service >/dev/null 2>&1 \
    || return 1
  log "tentando subir free-router.service (pool OpenCode)"
  systemctl --user start free-router.service >/dev/null 2>&1 || return 1
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    nh_free_router_up && return 0
    sleep 0.5
  done
  return 1
}

nh_write_proxy_env() {
  ensure_dir "$NH_CONFIG_DIR"
  umask 077
  {
    printf 'NVIDIA_NIM_API_KEY=%s\n' "${NH_API_KEY:-${NVIDIA_NIM_API_KEY:-}}"
    printf 'NVIDIA_API_KEY=%s\n' "${NH_API_KEY:-${NVIDIA_API_KEY:-}}"
    printf 'NVIDIA_ORIGIN=%s\n' "${NVIDIA_ORIGIN:-https://integrate.api.nvidia.com}"
    printf 'NH_FREE_ROUTER_URL=%s\n' "$NH_FREE_ROUTER_URL"
    printf 'NH_CURSOR_PROXY_HOST=%s\n' "$NH_CURSOR_PROXY_HOST"
    printf 'NH_CURSOR_PROXY_PORT=%s\n' "$NH_CURSOR_PROXY_PORT"
    printf 'NH_ENVF=%s\n' "$NH_ENVF"
    if [ -n "${LITELLM_MASTER_KEY:-}" ]; then
      printf 'LITELLM_MASTER_KEY=%s\n' "$LITELLM_MASTER_KEY"
    fi
    if [ -n "${NH_FREE_ROUTER_ENV:-}" ]; then
      printf 'NH_FREE_ROUTER_ENV=%s\n' "$NH_FREE_ROUTER_ENV"
    fi
  } > "$NH_PROXY_ENVF"
  chmod 600 "$NH_PROXY_ENVF"
}

nh_install_cursor_proxy_files() {
  [ -f "$NH_PROXY_SRC" ] || erro "proxy ausente: $NH_PROXY_SRC"
  ensure_dir "$(dirname "$NH_PROXY_BIN")"
  cp -a "$NH_PROXY_SRC" "$NH_PROXY_BIN"
  chmod 755 "$NH_PROXY_BIN"
  nh_write_proxy_env
  ensure_dir "$(dirname "$NH_PROXY_UNIT")"
  cat > "$NH_PROXY_UNIT" <<EOF
[Unit]
Description=nvidia-harness Cursor proxy (NVIDIA NIM + OpenCode free-router)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $NH_PROXY_BIN
EnvironmentFile=-$NH_PROXY_ENVF
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  ok "proxy instalado em $NH_PROXY_BIN"
}

nh_start_cursor_proxy() {
  if cursor_proxy_up; then
    ok "proxy já escuta $CURSOR_PROXY_URL"
    return 0
  fi
  if has_cmd systemctl && [ -d "$HOME/.config/systemd/user" ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable --now "$NH_PROXY_UNIT_NAME" >/dev/null 2>&1; then
      :
    else
      aviso "systemd --user não subiu o proxy; tentando processo em background"
      nh_start_cursor_proxy_bg || return 1
    fi
  else
    nh_start_cursor_proxy_bg || return 1
  fi
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if cursor_proxy_up; then
      ok "proxy ativo em $CURSOR_PROXY_URL"
      return 0
    fi
    sleep 0.3
  done
  aviso "proxy ainda não responde em $CURSOR_PROXY_URL"
  return 1
}

nh_start_cursor_proxy_bg() {
  need_cmd python3
  local logf="$NH_CONFIG_DIR/cursor-proxy.log" pidf="$NH_CONFIG_DIR/cursor-proxy.pid"
  if [ -f "$pidf" ]; then
    local old
    old="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      return 0
    fi
  fi
  set -a
  # shellcheck disable=SC1090
  [ -f "$NH_PROXY_ENVF" ] && . "$NH_PROXY_ENVF"
  set +a
  nohup python3 "$NH_PROXY_BIN" >>"$logf" 2>&1 &
  echo $! > "$pidf"
}

nh_ensure_cursor_proxy() {
  nh_detect_free_router_env
  nh_try_start_free_router || true
  nh_install_cursor_proxy_files
  nh_start_cursor_proxy
}
