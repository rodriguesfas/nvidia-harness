#!/usr/bin/env bash
# Instala e sobe o shim Cursor → NVIDIA NIM (+ pool OpenCode se :4000 estiver no ar).
# shellcheck shell=bash

NH_CURSOR_PROXY_PORT="${NH_CURSOR_PROXY_PORT:-12436}"
NH_CURSOR_PROXY_HOST="${NH_CURSOR_PROXY_HOST:-127.0.0.1}"
CURSOR_PROXY_URL="${CURSOR_PROXY_URL:-http://${NH_CURSOR_PROXY_HOST}:${NH_CURSOR_PROXY_PORT}/v1}"
NH_FREE_ROUTER_URL="${NH_FREE_ROUTER_URL:-http://127.0.0.1:4000}"
NH_CURSOR_PUBLIC_URL_FILE="${NH_CURSOR_PUBLIC_URL_FILE:-$NH_CONFIG_DIR/cursor-public-url}"
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
  local base="http://${NH_CURSOR_PROXY_HOST}:${NH_CURSOR_PROXY_PORT}"
  # /health é instantâneo. /v1/models espera o catálogo NVIDIA e falha o
  # diagnose com timeout de 2s mesmo com o shim no ar.
  nh_http_up "${base}/health" \
    || nh_http_up "${base}/v1/health" \
    || nh_http_up "${CURSOR_PROXY_URL%/}/models"
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

nh_normalize_colab_url() {
  # Aceita host ngrok/cloudflare com ou sem /v1; o proxy junta /v1/… sozinho.
  local u="${1:-}"
  u="${u%/}"
  u="${u%/v1}"
  printf '%s' "$u"
}

nh_load_colab_env() {
  local u m
  if [ -z "${NH_COLAB_URL:-}" ] && [ -f "$NH_PROXY_ENVF" ]; then
    u="$(nh_read_env_key "$NH_PROXY_ENVF" NH_COLAB_URL || true)"
    [ -n "$u" ] && NH_COLAB_URL="$u" && export NH_COLAB_URL
  fi
  if [ -z "${NH_COLAB_MODEL:-}" ] && [ -f "$NH_PROXY_ENVF" ]; then
    m="$(nh_read_env_key "$NH_PROXY_ENVF" NH_COLAB_MODEL || true)"
    [ -n "$m" ] && NH_COLAB_MODEL="$m" && export NH_COLAB_MODEL
  fi
  NH_COLAB_MODEL="${NH_COLAB_MODEL:-Qwen/Qwen2.5-Coder-3B-Instruct}"
  export NH_COLAB_MODEL
  if [ -n "${NH_COLAB_URL:-}" ]; then
    NH_COLAB_URL="$(nh_normalize_colab_url "$NH_COLAB_URL")"
    export NH_COLAB_URL
  fi
}

nh_colab_up() {
  [ -n "${NH_COLAB_URL:-}" ] || return 1
  nh_http_up "${NH_COLAB_URL%/}/v1/models" \
    || nh_http_up "${NH_COLAB_URL%/}/models" \
    || nh_http_up "${NH_COLAB_URL%/}/health" \
    || nh_http_up "${NH_COLAB_URL%/}/"
}

nh_write_proxy_env() {
  ensure_dir "$NH_CONFIG_DIR"
  umask 077
  nh_load_colab_env
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
    if [ -n "${NH_COLAB_URL:-}" ]; then
      printf 'NH_COLAB_URL=%s\n' "$NH_COLAB_URL"
      printf 'NH_COLAB_MODEL=%s\n' "${NH_COLAB_MODEL:-Qwen/Qwen2.5-Coder-3B-Instruct}"
    fi
    if [ -n "${NH_COLAB_API_KEY:-}" ]; then
      printf 'NH_COLAB_API_KEY=%s\n' "$NH_COLAB_API_KEY"
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
Description=nvidia-harness Cursor proxy (NVIDIA NIM + OpenCode free-router + Colab)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 $NH_PROXY_BIN
EnvironmentFile=-$NH_PROXY_ENVF
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
EOF
  ok "proxy instalado em $NH_PROXY_BIN"
}

# systemd --user só sobrevive a reboot/desligar com linger. Sem isso o
# proxy só volta depois do login gráfico.
nh_enable_user_linger() {
  has_cmd loginctl || return 0
  local linger
  linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)"
  if [ "$linger" = "yes" ]; then
    ok "linger já ativo — proxy sobe no boot"
    return 0
  fi
  if loginctl enable-linger "$USER" >/dev/null 2>&1; then
    ok "linger ativo para $USER (systemd --user no boot)"
    return 0
  fi
  aviso "não deu para activar linger (loginctl enable-linger $USER). Sem isso o proxy só sobe após o login."
}

# Unidade antiga (local-ai) ocupava :12436 e o harness achava que já estava ok.
nh_retire_legacy_cursor_proxy() {
  has_cmd systemctl || return 0
  local legacy="nvidia-cursor-proxy.service"
  if systemctl --user is-active "$legacy" >/dev/null 2>&1 \
    || systemctl --user is-enabled "$legacy" >/dev/null 2>&1; then
    log "desligando unidade legado $legacy (porta ${NH_CURSOR_PROXY_PORT})"
    systemctl --user disable --now "$legacy" >/dev/null 2>&1 || true
    systemctl --user stop "$legacy" >/dev/null 2>&1 || true
  fi
}

nh_wait_cursor_proxy() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if cursor_proxy_up; then
      ok "proxy ativo em $CURSOR_PROXY_URL"
      return 0
    fi
    sleep 0.3
  done
  aviso "proxy ainda não responde em $CURSOR_PROXY_URL"
  return 1
}

nh_start_cursor_proxy() {
  nh_enable_user_linger
  nh_retire_legacy_cursor_proxy
  if has_cmd systemctl && [ -d "$HOME/.config/systemd/user" ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable --now "$NH_PROXY_UNIT_NAME" >/dev/null 2>&1; then
      systemctl --user restart "$NH_PROXY_UNIT_NAME" >/dev/null 2>&1 || true
    else
      aviso "systemd --user não subiu o proxy; tentando processo em background"
      nh_start_cursor_proxy_bg || return 1
    fi
  else
    nh_start_cursor_proxy_bg || return 1
  fi
  nh_wait_cursor_proxy
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

NH_BYOK_JSON="${NH_BYOK_JSON:-$NH_CONFIG_DIR/cursor-byok.json}"
NH_BYOK_BIN="${NH_BYOK_BIN:-$NH_CONFIG_DIR/bin/cursor-byok-apply.py}"
NH_BYOK_SRC="${NH_BYOK_SRC:-$NH_ROOT/proxy/cursor-byok-apply.py}"
NH_BYOK_UNIT_NAME="nvidia-harness-cursor-byok.service"
NH_BYOK_TIMER_NAME="nvidia-harness-cursor-byok.timer"
NH_BYOK_UNIT="${NH_BYOK_UNIT:-$HOME/.config/systemd/user/$NH_BYOK_UNIT_NAME}"
NH_BYOK_TIMER="${NH_BYOK_TIMER:-$HOME/.config/systemd/user/$NH_BYOK_TIMER_NAME}"

# O Agent do Cursor não chama 127.0.0.1: o cloud da IDE recusa RFC1918
# ("Access to private networks is forbidden"). Base URL na IDE tem de ser
# HTTPS público. O Funnel do Tailscale aponta para o shim local.
nh_tailscale_dns_name() {
  has_cmd tailscale || return 1
  tailscale status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
name = ((d.get("Self") or {}).get("DNSName") or "").strip().rstrip(".")
if not name:
    raise SystemExit(1)
print(name)
' 2>/dev/null
}

nh_cursor_public_base_url() {
  local url host
  if [ -n "${CURSOR_PUBLIC_URL:-}" ]; then
    url="${CURSOR_PUBLIC_URL%/}"
    printf '%s' "$url"
    return 0
  fi
  if [ -f "$NH_CURSOR_PUBLIC_URL_FILE" ]; then
    url="$(tr -d '[:space:]' < "$NH_CURSOR_PUBLIC_URL_FILE" || true)"
    if [ -n "$url" ]; then
      printf '%s' "${url%/}"
      return 0
    fi
  fi
  host="$(nh_tailscale_dns_name || true)"
  if [ -n "$host" ]; then
    printf 'https://%s/v1' "$host"
    return 0
  fi
  return 1
}

nh_write_cursor_public_url() {
  local url="${1:-}"
  [ -n "$url" ] || return 1
  ensure_dir "$NH_CONFIG_DIR"
  umask 077
  printf '%s\n' "${url%/}" > "$NH_CURSOR_PUBLIC_URL_FILE"
  chmod 600 "$NH_CURSOR_PUBLIC_URL_FILE"
}

nh_enable_cursor_funnel() {
  local host url
  has_cmd tailscale || return 1
  if ! tailscale funnel --bg --yes "$NH_CURSOR_PROXY_PORT" >/dev/null 2>&1; then
    return 1
  fi
  host="$(nh_tailscale_dns_name || true)"
  [ -n "$host" ] || return 1
  url="https://${host}/v1"
  nh_write_cursor_public_url "$url"
  CURSOR_PUBLIC_URL="$url"
  export CURSOR_PUBLIC_URL
  ok "Funnel Cursor: $url → 127.0.0.1:${NH_CURSOR_PROXY_PORT}"
}

NH_TUNNEL_BIN="${NH_TUNNEL_BIN:-$NH_CONFIG_DIR/bin/cursor-tunnel-url.py}"
NH_TUNNEL_SRC="${NH_TUNNEL_SRC:-$NH_ROOT/proxy/cursor-tunnel-url.py}"
NH_TUNNEL_UNIT_NAME="nvidia-harness-cursor-tunnel.service"
NH_TUNNEL_UNIT="${NH_TUNNEL_UNIT:-$HOME/.config/systemd/user/$NH_TUNNEL_UNIT_NAME}"

nh_enable_cursor_ngrok() {
  local ngrok url
  ngrok="$(command -v ngrok || true)"
  [ -n "$ngrok" ] || {
    aviso "sem ngrok e sem Funnel — o Agent recusa 127.0.0.1. Instale ngrok ou sudo tailscale set --operator=\$USER"
    return 1
  }
  [ -f "$NH_TUNNEL_SRC" ] || return 1
  ensure_dir "$(dirname "$NH_TUNNEL_BIN")"
  cp -a "$NH_TUNNEL_SRC" "$NH_TUNNEL_BIN"
  chmod 755 "$NH_TUNNEL_BIN"
  ensure_dir "$(dirname "$NH_TUNNEL_UNIT")"
  cat > "$NH_TUNNEL_UNIT" <<EOF
[Unit]
Description=nvidia-harness Cursor public tunnel (ngrok → :${NH_CURSOR_PROXY_PORT})
After=network-online.target nvidia-harness-cursor-proxy.service
Wants=network-online.target nvidia-harness-cursor-proxy.service

[Service]
Type=simple
ExecStart=$ngrok http 127.0.0.1:${NH_CURSOR_PROXY_PORT} --log stdout
ExecStartPost=-/usr/bin/python3 $NH_TUNNEL_BIN
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  has_cmd systemctl || return 1
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "$NH_TUNNEL_UNIT_NAME" >/dev/null 2>&1 || {
    aviso "não subiu $NH_TUNNEL_UNIT_NAME"
    return 1
  }
  NH_TUNNEL_WAIT=20 python3 "$NH_TUNNEL_BIN" >/dev/null || true
  url="$(nh_cursor_public_base_url || true)"
  if [ -z "$url" ]; then
    aviso "ngrok no ar mas URL pública ainda vazia"
    return 1
  fi
  CURSOR_PUBLIC_URL="$url"
  export CURSOR_PUBLIC_URL
  ok "túnel Cursor: $url → 127.0.0.1:${NH_CURSOR_PROXY_PORT}"
}

nh_enable_cursor_public_url() {
  local url
  if [ -n "${CURSOR_PUBLIC_URL:-}" ]; then
    nh_write_cursor_public_url "$CURSOR_PUBLIC_URL"
    ok "CURSOR_PUBLIC_URL=$CURSOR_PUBLIC_URL"
    return 0
  fi
  if nh_enable_cursor_funnel; then
    return 0
  fi
  if nh_enable_cursor_ngrok; then
    return 0
  fi
  url="$(nh_cursor_public_base_url || true)"
  if [ -n "$url" ]; then
    CURSOR_PUBLIC_URL="$url"
    export CURSOR_PUBLIC_URL
    return 0
  fi
  aviso "sem URL pública — o Agent do Cursor recusa 127.0.0.1 (SSRF 403)"
  return 1
}

nh_write_cursor_byok_json() {
  local models="${1:-}" public
  public="$(nh_cursor_public_base_url || true)"
  if [ -z "$public" ]; then
    public="$CURSOR_PROXY_URL"
  fi
  ensure_dir "$NH_CONFIG_DIR"
  umask 077
  CURSOR_PROXY_URL="$public" NH_BYOK_JSON="$NH_BYOK_JSON" \
  CURSOR_MODELS_JOINED="$models" python3 <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["NH_BYOK_JSON"])
models = os.environ.get("CURSOR_MODELS_JOINED", "").split()
p.write_text(json.dumps({
    "openAIBaseUrl": os.environ["CURSOR_PROXY_URL"],
    "useOpenAIKey": True,
    "userAddedModels": models,
}, indent=2, ensure_ascii=False) + "\n")
p.chmod(0o600)
print("byok json:", p)
PY
}

nh_install_cursor_byok_timer() {
  [ -f "$NH_BYOK_SRC" ] || return 0
  ensure_dir "$(dirname "$NH_BYOK_BIN")"
  cp -a "$NH_BYOK_SRC" "$NH_BYOK_BIN"
  chmod 755 "$NH_BYOK_BIN"
  ensure_dir "$(dirname "$NH_BYOK_UNIT")"
  cat > "$NH_BYOK_UNIT" <<EOF
[Unit]
Description=nvidia-harness apply Cursor BYOK when the IDE is idle
After=nvidia-harness-cursor-proxy.service

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 $NH_BYOK_BIN
EnvironmentFile=-$NH_PROXY_ENVF
EOF
  cat > "$NH_BYOK_TIMER" <<EOF
[Unit]
Description=nvidia-harness Cursor BYOK idle apply

[Timer]
OnBootSec=20
OnUnitActiveSec=20
AccuracySec=5

[Install]
WantedBy=timers.target
EOF
  has_cmd systemctl || return 0
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now "$NH_BYOK_TIMER_NAME" >/dev/null 2>&1 || true
  ok "timer BYOK: aplica o proxy quando o Cursor não está aberto"
}

nh_ensure_cursor_proxy() {
  nh_detect_free_router_env
  nh_try_start_free_router || true
  nh_install_cursor_proxy_files
  nh_start_cursor_proxy
  nh_enable_cursor_public_url || true
}
