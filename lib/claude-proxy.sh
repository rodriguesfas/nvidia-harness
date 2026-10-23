#!/usr/bin/env bash
# Proxy LiteLLM persistente do Claude Code (NVIDIA NIM + pool OpenCode se :4000).
# Sem isto, o wrapper mata o LiteLLM ao sair e a extensão Cursor/VS Code
# fica com ANTHROPIC_BASE_URL=http://127.0.0.1:4310 e ECONNREFUSED.
# shellcheck shell=bash

NH_CLAUDE_CONFIG_DIR="${NH_CLAUDE_CONFIG_DIR:-$HOME/.config/claude-nvidia}"
NH_CLAUDE_VENV_DIR="${NH_CLAUDE_VENV_DIR:-$HOME/.claude-nvidia/venv}"
NH_CLAUDE_PROXY_PORT="${NH_CLAUDE_PROXY_PORT:-4310}"
NH_CLAUDE_PROXY_HOST="${NH_CLAUDE_PROXY_HOST:-127.0.0.1}"
NH_CLAUDE_PROXY_UNIT_NAME="${NH_CLAUDE_PROXY_UNIT_NAME:-nvidia-harness-claude-proxy.service}"
NH_CLAUDE_PROXY_UNIT="${NH_CLAUDE_PROXY_UNIT:-$HOME/.config/systemd/user/$NH_CLAUDE_PROXY_UNIT_NAME}"
NH_CLAUDE_PROXY_ENVF="${NH_CLAUDE_PROXY_ENVF:-$NH_CLAUDE_CONFIG_DIR/proxy.env}"
NH_CLAUDE_PROXY_URL="${NH_CLAUDE_PROXY_URL:-http://${NH_CLAUDE_PROXY_HOST}:${NH_CLAUDE_PROXY_PORT}}"

nh_claude_proxy_up() {
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
    "$NH_CLAUDE_PROXY_URL/health/liveliness" || true)"
  [ "$code" = "200" ]
}

# EnvironmentFile do systemd: KEY=value, sem `export`, valores já resolvidos.
nh_write_claude_proxy_env() {
  ensure_dir "$NH_CLAUDE_CONFIG_DIR"
  umask 077
  {
    printf 'NVIDIA_NIM_API_KEY=%s\n' "${NVIDIA_NIM_API_KEY:-${NH_API_KEY:-}}"
    printf 'NVIDIA_API_KEY=%s\n' "${NVIDIA_API_KEY:-${NVIDIA_NIM_API_KEY:-${NH_API_KEY:-}}}"
    printf 'LITELLM_MASTER_KEY=%s\n' "${LITELLM_MASTER_KEY:-}"
    printf 'NV_MODEL=%s\n' "${NV_MODEL:-}"
    printf 'NV_SMALL_MODEL=%s\n' "${NV_SMALL_MODEL:-}"
    printf 'NH_FREE_ROUTER_URL=%s\n' "${NH_FREE_ROUTER_URL:-http://127.0.0.1:4000}"
    if [ -n "${NH_FREE_ROUTER_KEY:-}" ]; then
      printf 'NH_FREE_ROUTER_KEY=%s\n' "$NH_FREE_ROUTER_KEY"
    fi
    printf 'LITELLM_TELEMETRY=False\n'
  } > "$NH_CLAUDE_PROXY_ENVF"
  chmod 600 "$NH_CLAUDE_PROXY_ENVF"
}

nh_install_claude_proxy_unit() {
  local litellm conf
  litellm="$NH_CLAUDE_VENV_DIR/bin/litellm"
  conf="$NH_CLAUDE_CONFIG_DIR/config.yaml"
  [ -x "$litellm" ] || erro "LiteLLM ausente em $litellm"
  [ -f "$conf" ] || erro "config ausente: $conf"
  nh_write_claude_proxy_env
  ensure_dir "$(dirname "$NH_CLAUDE_PROXY_UNIT")"
  cat > "$NH_CLAUDE_PROXY_UNIT" <<EOF
[Unit]
Description=nvidia-harness Claude Code proxy (LiteLLM → NVIDIA NIM)
After=network-online.target

[Service]
Type=simple
EnvironmentFile=-$NH_CLAUDE_PROXY_ENVF
Environment=LITELLM_TELEMETRY=False
ExecStart=$litellm --config $conf --host $NH_CLAUDE_PROXY_HOST --port $NH_CLAUDE_PROXY_PORT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
  ok "unidade systemd $NH_CLAUDE_PROXY_UNIT_NAME"
}

nh_start_claude_proxy_bg() {
  local logf="$NH_CLAUDE_CONFIG_DIR/litellm-$NH_CLAUDE_PROXY_PORT.log"
  local pidf="$NH_CLAUDE_CONFIG_DIR/claude-proxy.pid"
  local litellm="$NH_CLAUDE_VENV_DIR/bin/litellm"
  if [ -f "$pidf" ]; then
    local old
    old="$(cat "$pidf" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      return 0
    fi
  fi
  set -a
  # shellcheck disable=SC1090
  [ -f "$NH_CLAUDE_PROXY_ENVF" ] && . "$NH_CLAUDE_PROXY_ENVF"
  set +a
  : >"$logf"
  nohup "$litellm" --config "$NH_CLAUDE_CONFIG_DIR/config.yaml" \
    --host "$NH_CLAUDE_PROXY_HOST" --port "$NH_CLAUDE_PROXY_PORT" \
    >>"$logf" 2>&1 &
  echo $! > "$pidf"
}

# LiteLLM órfão do wrapper antigo na mesma porta (o nosso processo, não um app).
nh_stop_orphan_claude_litellm() {
  command -v ss >/dev/null 2>&1 || return 0
  local pid
  pid="$(ss -H -ltnp "sport = :$NH_CLAUDE_PROXY_PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2)"
  [ -n "$pid" ] || return 0
  grep -qF -- "$NH_CLAUDE_VENV_DIR/bin/litellm" "/proc/$pid/cmdline" 2>/dev/null || return 0
  grep -qF -- "$NH_CLAUDE_CONFIG_DIR/config.yaml" "/proc/$pid/cmdline" 2>/dev/null || return 0
  if has_cmd systemctl && systemctl --user is-active "$NH_CLAUDE_PROXY_UNIT_NAME" >/dev/null 2>&1; then
    return 0
  fi
  log "substituindo LiteLLM órfão na porta $NH_CLAUDE_PROXY_PORT (pid $pid) pelo systemd"
  kill "$pid" 2>/dev/null || true
  sleep 1
  kill -9 "$pid" 2>/dev/null || true
}

# Reinicia para carregar config.yaml novo. Não mata processo alheio na porta.
nh_start_claude_proxy() {
  nh_stop_orphan_claude_litellm
  if has_cmd systemctl && [ -d "$HOME/.config/systemd/user" ]; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    if systemctl --user enable --now "$NH_CLAUDE_PROXY_UNIT_NAME" >/dev/null 2>&1; then
      systemctl --user restart "$NH_CLAUDE_PROXY_UNIT_NAME" >/dev/null 2>&1 || true
    else
      aviso "systemd --user não subiu o proxy Claude; tentando processo em background"
      nh_start_claude_proxy_bg || return 1
    fi
  else
    nh_start_claude_proxy_bg || return 1
  fi
  local i
  for i in $(seq 1 60); do
    if nh_claude_proxy_up; then
      ok "proxy Claude ativo em $NH_CLAUDE_PROXY_URL (${i}s)"
      return 0
    fi
    if [ $((i % 5)) -eq 0 ]; then
      echo "  aguardando o proxy Claude... ${i}s" >&2
    fi
    sleep 1
  done
  aviso "proxy Claude ainda não responde em $NH_CLAUDE_PROXY_URL"
  return 1
}

nh_ensure_claude_proxy() {
  # shellcheck disable=SC1090
  if [ -f "$NH_CLAUDE_CONFIG_DIR/env" ]; then
    set +e
    # shellcheck source=/dev/null
    source "$NH_CLAUDE_CONFIG_DIR/env" >/dev/null 2>&1
    set -e
  fi
  nh_try_start_free_router || true
  nh_install_claude_proxy_unit
  nh_start_claude_proxy
}

nh_diagnose_claude_proxy() {
  printf '  proxy    : %s (%s)\n' "$NH_CLAUDE_PROXY_URL" \
    "$(nh_claude_proxy_up && echo ativo || echo ausente)"
  if has_cmd systemctl; then
    printf '  unit     : %s\n' \
      "$(systemctl --user is-active "$NH_CLAUDE_PROXY_UNIT_NAME" 2>/dev/null || echo inativo)"
  fi
}
