#!/usr/bin/env bash
# Harness: VS Code + extensão NVIDIA NIM Provider (Copilot Chat).
# Instala a extensão, valida a API e orienta o cadastro seguro da chave
# (SecretStorage / Manage Models — nunca grava nvapi no settings.json).
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

EXT_ID="hidenobunagai.nvidia-nim-provider"
DO_DIAGNOSE=0
DO_TEST=1
SKIP_EXT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) NH_API_KEY_IN="${2:?}"; export NH_API_KEY_IN; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --skip-extension) SKIP_EXT=1; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/vscode.sh [--api-key nvapi-…] [--no-test] [--skip-extension]
                           [--diagnose] [--yes]
Instala $EXT_ID (se code/cursor CLI disponível) e valida a API NIM.
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

vscode_cli() {
  if has_cmd code; then printf 'code'; return 0; fi
  if has_cmd code-insiders; then printf 'code-insiders'; return 0; fi
  return 1
}

ext_installed() {
  local cli="$1"
  "$cli" --list-extensions 2>/dev/null | grep -qi "^${EXT_ID}$"
}

nh_diagnose_vscode() {
  nh_diagnose_common
  local cli
  if cli="$(vscode_cli)"; then
    printf '  vscode   : %s\n' "$(command -v "$cli")"
    if ext_installed "$cli"; then
      printf '  extension: %s instalada\n' "$EXT_ID"
    else
      printf '  extension: %s AUSENTE\n' "$EXT_ID"
    fi
    if "$cli" --list-extensions 2>/dev/null | grep -qi 'github.copilot'; then
      printf '  copilot  : presente\n'
    else
      printf '  copilot  : AUSENTE (necessário para o picker do NIM Provider)\n'
    fi
  else
    printf '  vscode   : CLI code não encontrada no PATH\n'
  fi
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_vscode
  exit 0
fi

need_cmd curl
need_cmd python3
nh_resolve_api_key

log "listando catálogo /models"
nh_list_models >/dev/null
ok "catálogo /models OK"
nh_validate_key

nh_save_shared_env

if [ "$SKIP_EXT" = 0 ]; then
  if CLI="$(vscode_cli)"; then
    if ext_installed "$CLI"; then
      ok "extensão já instalada: $EXT_ID"
    elif confirm "Instalar extensão $EXT_ID via $CLI?"; then
      log "instalando $EXT_ID"
      "$CLI" --install-extension "$EXT_ID"
      ok "extensão instalada"
    else
      aviso "extensão não instalada — instale manualmente no marketplace: $EXT_ID"
    fi
    if ! "$CLI" --list-extensions 2>/dev/null | grep -qi 'github.copilot'; then
      aviso "GitHub Copilot não detectado; o NIM Provider usa o Copilot Chat como hospedeiro"
    fi
  else
    aviso "CLI 'code' não encontrada — instale a extensão manualmente: $EXT_ID"
  fi
fi

cat <<EOF

Pronto (VS Code). Cadastro da chave (seguro — SecretStorage da IDE):

  1. Abra o VS Code / Copilot Chat
  2. Command Palette → "NVIDIA NIM: Manage NVIDIA NIM API Key"
     (ou Model picker → Manage Models → NVIDIA NIM)
  3. Cole a chave ($(mask_key "$NH_API_KEY"))
  4. Selecione um modelo NIM no picker do chat

Não gravamos a chave em settings.json de propósito.

  extensão : $EXT_ID
  docs     : https://github.com/hidenobunagai/nvidia-nim-provider
  diagnose : ./install.sh vscode --diagnose

EOF
ok "vscode: validação e orientação concluídas"
