#!/usr/bin/env bash
# nvidia-harness — instalador unificado de modelos NVIDIA NIM para
# Claude Code, Cursor, OpenCode, VS Code e Antigravity.
#
#   ./install.sh                       # menu interativo
#   ./install.sh <harness> [flags…]    # direto
#   ./install.sh all [--yes]           # todos (pede confirmação por harness, salvo --yes)
#   ./install.sh diagnose              # diagnóstico de todos
#   ./install.sh --self-test           # regressão: array vazio + set -u
#
# Variáveis: NVIDIA_NIM_API_KEY (preferível a --api-key, que aparece no ps).
# shellcheck disable=SC1090,SC1091
if [ -z "${BASH_VERSION:-}" ]; then
  printf 'erro: precisa de bash (não sh/dash). Tente: bash %s\n' "$0" >&2
  exit 1
fi
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
  ./install.sh --self-test
  ./install.sh --help

Flags globais (antes do harness):
  --api-key nvapi-…   chave NVIDIA (preferível: env NVIDIA_NIM_API_KEY)
  --yes, -y           confirma sobrescritas automaticamente
  --no-test           pula smoke de chat/completions
  --diagnose          só diagnóstica (também: ./install.sh diagnose)
  --self-test         prova o crash de array vazio (não toca configs)

Exemplos:
  NVIDIA_NIM_API_KEY=nvapi-… ./install.sh claude
  ./install.sh cursor --diagnose
  ./install.sh antigravity --yes
  ./install.sh all --yes --no-test

Docs: $NH_ROOT/README.md
Chave compartilhada: $NH_ENVF (chmod 600)
EOF
}

# Sempre array definido: "${FORWARD_ARGS[@]}" vazio + set -u aborta no bash < 4.4.
declare -a FORWARD_ARGS=()
TARGET=""
MODE_ALL=0
MODE_DIAGNOSE=0
MODE_SELF_TEST=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --self-test) MODE_SELF_TEST=1; shift ;;
    --api-key)
      if [ -z "${2:-}" ]; then
        erro "--api-key exige o valor nvapi-… (prefira NVIDIA_NIM_API_KEY=… no ambiente)"
      fi
      NH_API_KEY_IN="$2"
      export NH_API_KEY_IN
      FORWARD_ARGS+=(--api-key "$2")
      shift 2
      ;;
    --yes|-y) NH_YES=1; export NH_YES; FORWARD_ARGS+=(--yes); shift ;;
    --no-test) FORWARD_ARGS+=(--no-test); shift ;;
    --diagnose) MODE_DIAGNOSE=1; shift ;;
    diagnose) MODE_DIAGNOSE=1; shift ;;
    all) MODE_ALL=1; shift ;;
    claude|cursor|opencode|vscode|antigravity)
      TARGET="$1"
      shift
      # "$@" vazio é seguro; o array FORWARD_ARGS é que não era.
      while [ $# -gt 0 ]; do
        FORWARD_ARGS+=("$1")
        shift
      done
      break
      ;;
    *)
      FORWARD_ARGS+=("$1")
      shift
      ;;
  esac
done

run_harness() {
  local name="${1:-}"
  shift || true
  [ -n "$name" ] || erro "harness não informado"
  local script="$NH_ROOT/harnesses/${name}.sh"
  [ -f "$script" ] || erro "módulo ausente: $script"
  chmod +x "$script" 2>/dev/null || true
  log "harness: $name"
  # "$@" vazio é seguro com set -u (parâmetros posicionais); array é que não era.
  bash "$script" "$@"
}

# Encaminha FORWARD_ARGS (vazio ou unset) sem unbound variable.
run_harness_fwd() {
  local name="${1:-}"
  shift || true
  [ -n "$name" ] || erro "harness não informado"
  nh_call_a FORWARD_ARGS run_harness "$name" "$@"
}

self_test() {
  log "self-test: array vazio / unset + set -u"
  local out
  # shellcheck disable=SC2317  # invocadas via nh_call_a/eval
  _probe() { printf 'argc=%s' "$#"; local a; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; }

  # Arrays globais: nh_call_a faz eval noutro scope — `local` não serviria.
  _NH_ST_EMPTY=()
  out="$(nh_call_a _NH_ST_EMPTY _probe cursor)"
  [ "$out" = "argc=1 [cursor]" ] || erro "self-test vazio: got '$out'"

  out="$(nh_call_a _NH_ST_EMPTY _probe cursor --diagnose)"
  [ "$out" = "argc=2 [cursor] [--diagnose]" ] || erro "self-test vazio+diag: got '$out'"

  _NH_ST_FULL=(--yes --no-test)
  out="$(nh_call_a _NH_ST_FULL _probe cursor --diagnose)"
  [ "$out" = "argc=4 [cursor] [--diagnose] [--yes] [--no-test]" ] || erro "self-test flags: got '$out'"

  unset _NH_ST_UNSET || true
  out="$(nh_call_a _NH_ST_UNSET _probe cursor)"
  [ "$out" = "argc=1 [cursor]" ] || erro "self-test unset: got '$out'"

  # Caminho real do menu: FORWARD_ARGS vazio → run_harness_fwd.
  FORWARD_ARGS=()
  # shellcheck disable=SC2317
  run_harness() { printf 'run name=%s argc=%s\n' "$1" "$#"; }
  out="$(run_harness_fwd cursor)"
  [ "$out" = "run name=cursor argc=1" ] || erro "self-test fwd vazio: got '$out'"
  out="$(run_harness_fwd cursor --diagnose)"
  [ "$out" = "run name=cursor argc=2" ] || erro "self-test fwd diag: got '$out'"
  FORWARD_ARGS=(--yes)
  out="$(run_harness_fwd cursor)"
  [ "$out" = "run name=cursor argc=2" ] || erro "self-test fwd flags: got '$out'"

  unset FORWARD_ARGS || true
  out="$(run_harness_fwd cursor --diagnose)"
  [ "$out" = "run name=cursor argc=2" ] || erro "self-test fwd FORWARD_ARGS unset: got '$out'"

  python3 "$NH_ROOT/proxy/nvidia-cursor-proxy.py" --selftest >/dev/null \
    || erro "self-test do proxy Cursor falhou"

  bash -n "$NH_ROOT/lib/claude-proxy.sh" || erro "sintaxe de lib/claude-proxy.sh"
  bash -n "$NH_ROOT/harnesses/claude.sh" || erro "sintaxe de harnesses/claude.sh"
  grep -q 'nvidia-harness-claude-proxy.service' "$NH_ROOT/lib/claude-proxy.sh" \
    || erro "self-test: unidade Claude ausente em claude-proxy.sh"
  grep -q 'ANTHROPIC_BASE_URL' "$NH_ROOT/harnesses/claude.sh" \
    || erro "self-test: settings.env ANTHROPIC_BASE_URL ausente em claude.sh"

  ok "self-test ok (array vazio/unset + proxy Cursor + Claude persistente)"
  exit 0
}

menu() {
  if [ ! -t 0 ]; then
    erro "sem TTY — informe o harness: ./install.sh claude|cursor|opencode|vscode|antigravity|all|diagnose"
  fi
  local choice
  while :; do
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
    printf 'Opção: '
    IFS= read -r choice || true
    choice="$(nh_trim "$choice")"
    choice="$(nh_lower "$choice")"
    case "$choice" in
      1|claude) TARGET=claude; return 0 ;;
      2|cursor) TARGET=cursor; return 0 ;;
      3|opencode) TARGET=opencode; return 0 ;;
      4|vscode|vs|code) TARGET=vscode; return 0 ;;
      5|antigravity|agy) TARGET=antigravity; return 0 ;;
      6|all|todos) MODE_ALL=1; return 0 ;;
      7|diagnose|diagnostico|diagnóstico) MODE_DIAGNOSE=1; return 0 ;;
      0|q|sair|exit) exit 0 ;;
      *) aviso "opção inválida — tente 0-7" ;;
    esac
  done
}

if [ "$MODE_SELF_TEST" = 1 ]; then
  self_test
fi

if [ "$MODE_DIAGNOSE" = 0 ] && [ "$MODE_ALL" = 0 ] && [ -z "$TARGET" ]; then
  if [ "${#FORWARD_ARGS[@]}" -eq 0 ]; then
    menu
  else
    usage
    exit 1
  fi
fi

if [ "$MODE_DIAGNOSE" = 1 ] && [ -z "$TARGET" ] && [ "$MODE_ALL" = 0 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_common
  for h in "${HARNESSES[@]}"; do
    echo
    run_harness "$h" --diagnose || true
  done
  exit 0
fi

if [ "$MODE_ALL" = 1 ]; then
  local_fail=0
  fail_list=""
  for h in "${HARNESSES[@]}"; do
    echo
    if [ "${NH_YES:-0}" = 1 ] || confirm "Configurar harness '$h'?"; then
      if run_harness_fwd "$h"; then
        :
      else
        aviso "harness '$h' falhou — seguindo os demais"
        local_fail=1
        fail_list="${fail_list:+$fail_list }$h"
      fi
    else
      aviso "pulando $h"
    fi
  done
  if [ "$local_fail" = 1 ]; then
    erro "all concluído com falha: $fail_list"
  fi
  ok "all concluído"
  exit 0
fi

if [ "$MODE_DIAGNOSE" = 1 ]; then
  run_harness_fwd "$TARGET" --diagnose
  exit 0
fi

[ -n "$TARGET" ] || erro "harness não informado"
run_harness_fwd "$TARGET"
