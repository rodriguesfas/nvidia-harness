#!/usr/bin/env bash
# nvidia-harness — instalador unificado de modelos NVIDIA NIM para
# Claude Code, Cursor, OpenCode, VS Code e Antigravity.
#
#   ./install.sh                       # menu interativo
#   ./install.sh <harness> [flags…]    # direto
#   ./install.sh all [--yes]           # todos (pede confirmação por harness, salvo --yes)
#   ./install.sh diagnose              # diagnóstico de todos
#
# Variáveis: NVIDIA_NIM_API_KEY (preferível a --api-key, que aparece no ps).
# shellcheck disable=SC1090,SC1091
set -euo pipefail

NH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export NH_ROOT
# shellcheck source=lib/common.sh
source "$NH_ROOT/lib/common.sh"
# shellcheck source=lib/nvidia.sh
source "$NH_ROOT/lib/nvidia.sh"

HARNESSES=(claude cursor opencode vscode antigravity)

usage() {
  cat <<EOF
nvidia-harness — configura modelos NVIDIA NIM nos harnesses de desenvolvimento.

Uso:
  ./install.sh                       menu interativo
  ./install.sh claude|cursor|opencode|vscode|antigravity [flags do harness]
  ./install.sh all [--yes] [--no-test]
  ./install.sh diagnose
  ./install.sh --help

Flags globais (antes do harness):
  --api-key nvapi-…   chave NVIDIA (preferível: env NVIDIA_NIM_API_KEY)
  --yes, -y           confirma sobrescritas automaticamente
  --no-test           pula smoke de chat/completions
  --diagnose          só diagnóstica (também: ./install.sh diagnose)

Exemplos:
  NVIDIA_NIM_API_KEY=nvapi-… ./install.sh claude
  ./install.sh cursor --diagnose
  ./install.sh antigravity --yes
  ./install.sh all --yes --no-test

Docs: $NH_ROOT/README.md
Chave compartilhada: $NH_ENVF (chmod 600)
EOF
}

FORWARD_ARGS=()
TARGET=""
MODE_ALL=0
MODE_DIAGNOSE=0
MODE_MENU=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --api-key)
      NH_API_KEY_IN="${2:?}"
      export NH_API_KEY_IN
      FORWARD_ARGS+=(--api-key "$2")
      shift 2
      ;;
    --yes|-y) NH_YES=1; export NH_YES; FORWARD_ARGS+=(--yes); shift ;;
    --no-test) FORWARD_ARGS+=(--no-test); shift ;;
    --diagnose) MODE_DIAGNOSE=1; shift ;;
    diagnose) MODE_DIAGNOSE=1; shift ;;
    all) MODE_ALL=1; shift ;;
    claude|cursor|opencode|vscode|antigravity) TARGET="$1"; shift; FORWARD_ARGS+=("$@"); break ;;
    *)
      # flags restantes pertencem ao harness
      FORWARD_ARGS+=("$1"); shift
      ;;
  esac
done

run_harness() {
  local name="$1"; shift
  local script="$NH_ROOT/harnesses/${name}.sh"
  [ -x "$script" ] || [ -f "$script" ] || erro "módulo ausente: $script"
  chmod +x "$script" 2>/dev/null || true
  log "harness: $name"
  bash "$script" "$@"
}

menu() {
  if [ ! -t 0 ]; then
    erro "sem TTY — informe o harness: ./install.sh claude|cursor|opencode|vscode|antigravity|all|diagnose"
  fi
  echo
  echo "nvidia-harness — selecione o destino:"
  echo "  1) Claude Code  (proxy LiteLLM local)"
  echo "  2) Cursor       (OpenAI-compatible base URL)"
  echo "  3) OpenCode     (provider nvidia no opencode.json)"
  echo "  4) VS Code      (extensão NIM Provider + Copilot Chat)"
  echo "  5) Antigravity  (Cline OpenAI Compatible → NIM)"
  echo "  6) Todos"
  echo "  7) Diagnóstico"
  echo "  0) Sair"
  local choice
  printf 'Opção: '
  IFS= read -r choice || true
  case "$choice" in
    1) TARGET=claude ;;
    2) TARGET=cursor ;;
    3) TARGET=opencode ;;
    4) TARGET=vscode ;;
    5) TARGET=antigravity ;;
    6) MODE_ALL=1 ;;
    7) MODE_DIAGNOSE=1 ;;
    0) exit 0 ;;
    *) erro "opção inválida" ;;
  esac
}

if [ "$MODE_DIAGNOSE" = 0 ] && [ "$MODE_ALL" = 0 ] && [ -z "$TARGET" ]; then
  if [ "${#FORWARD_ARGS[@]}" -eq 0 ]; then
    menu
  else
    usage
    exit 1
  fi
fi

if [ "$MODE_DIAGNOSE" = 1 ] && [ -z "$TARGET" ] && [ "$MODE_ALL" = 0 ]; then
  # diagnose all (chave opcional)
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_common
  for h in "${HARNESSES[@]}"; do
    echo
    run_harness "$h" --diagnose || true
  done
  exit 0
fi

if [ "$MODE_ALL" = 1 ]; then
  for h in "${HARNESSES[@]}"; do
    echo
    if [ "${NH_YES:-0}" = 1 ] || confirm "Configurar harness '$h'?"; then
      run_harness "$h" "${FORWARD_ARGS[@]}"
    else
      aviso "pulando $h"
    fi
  done
  ok "all concluído"
  exit 0
fi

if [ "$MODE_DIAGNOSE" = 1 ]; then
  run_harness "$TARGET" --diagnose "${FORWARD_ARGS[@]}"
  exit 0
fi

[ -n "$TARGET" ] || erro "harness não informado"
run_harness "$TARGET" "${FORWARD_ARGS[@]}"
