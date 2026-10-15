#!/usr/bin/env bash
# Funções compartilhadas do nvidia-harness (logging, backup, confirmação).
# shellcheck shell=bash

NH_ROOT="${NH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
NH_CONFIG_DIR="${NH_CONFIG_DIR:-$HOME/.config/nvidia-harness}"
NH_ENVF="${NH_ENVF:-$NH_CONFIG_DIR/env}"
export NH_MARKER="# gerado por nvidia-harness"

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
aviso() { printf '\033[1;33maviso:\033[0m %s\n' "$*" >&2; }
erro()  { printf '\033[1;31merro:\033[0m %s\n' "$*" >&2; exit 1; }

# Mascarar chave em mensagens (nunca imprime o valor completo).
mask_key() {
  local k="${1:-}"
  if [ "${#k}" -lt 10 ]; then
    printf '***'
  else
    printf '%s…%s' "${k:0:7}" "${k: -4}"
  fi
}

confirm() {
  # confirm "mensagem" → 0 se sim. NH_YES=1 (ou --yes) aceita tudo.
  local msg="${1:-Continuar?}"
  if [ "${NH_YES:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    aviso "stdin não é TTY; use --yes para confirmar automaticamente: $msg"
    return 1
  fi
  local ans
  printf '%s [s/N] ' "$msg"
  IFS= read -r ans || true
  case "${ans,,}" in
    s|sim|y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

backup_file() {
  # backup_file <path> → imprime caminho do backup (ou vazio se arquivo não existe)
  local path="$1"
  [ -f "$path" ] || { printf ''; return 0; }
  local bak="${path}.bak-nvidia-harness-$(date +%Y%m%d-%H%M%S)"
  cp -a "$path" "$bak"
  printf '%s' "$bak"
}

ensure_dir() {
  mkdir -p "$1"
  chmod 700 "$1" 2>/dev/null || true
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || erro "precisa de '$1' no PATH"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}
