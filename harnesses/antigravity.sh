#!/usr/bin/env bash
# Harness: Google Antigravity IDE → NVIDIA NIM (via Cline OpenAI Compatible).
#
# O agente Cascade nativo da IDE ainda não aceita endpoint OpenAI-compatible /
# BYOK (sem Base URL oficial). O caminho suportável é instalar o Cline dentro
# do Antigravity e apontar Base URL + chave + Model ID para a API NIM.
# O CLI `agy` só aceita endpoints Gemini-compatíveis (GOOGLE_GEMINI_BASE_URL),
# não a API OpenAI da NVIDIA.
#
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

MODELS_FILE="$NH_ROOT/config/models.default.txt"
CLINE_EXT_ID="saoudrizwan.claude-dev"
DO_DIAGNOSE=0
DO_TEST=1
SKIP_EXT=0
DEFAULT_MODEL="nvidia/nemotron-3-super-120b-a12b"

antigravity_cli() {
  if has_cmd antigravity; then
    printf 'antigravity'
    return 0
  fi
  return 1
}

ext_installed() {
  local cli="$1"
  "$cli" --list-extensions 2>/dev/null | grep -qi "^${CLINE_EXT_ID}$"
}

ag_settings_candidates() {
  cat <<EOF
$HOME/.config/Antigravity/User/settings.json
EOF
}

ag_find_settings() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p" ] || [ -d "$(dirname "$p")" ]; then
      printf '%s' "$p"
      return 0
    fi
  done < <(ag_settings_candidates)
  printf '%s' "$HOME/.config/Antigravity/User/settings.json"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) NH_API_KEY_IN="${2:?}"; export NH_API_KEY_IN; shift 2 ;;
    --model) DEFAULT_MODEL="${2:?}"; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --skip-extension) SKIP_EXT=1; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/antigravity.sh [--api-key nvapi-…] [--model id]
                                [--no-test] [--skip-extension] [--diagnose] [--yes]
Valida a API NIM, instala o Cline no Antigravity e orienta Base URL / Model ID.
O agente Cascade nativo não recebe endpoint OpenAI-compatible.
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

SETTINGS="$(ag_find_settings)"

nh_diagnose_antigravity() {
  nh_diagnose_common
  printf '  antigravity : %s\n' "$(has_cmd antigravity && command -v antigravity || echo AUSENTE)"
  printf '  agy         : %s\n' "$(has_cmd agy && command -v agy || echo AUSENTE)"
  printf '  settings    : %s (%s)\n' "$SETTINGS" "$([ -f "$SETTINGS" ] && echo presente || echo ausente)"
  printf '  cli settings: %s (%s)\n' \
    "$HOME/.gemini/antigravity-cli/settings.json" \
    "$([ -f "$HOME/.gemini/antigravity-cli/settings.json" ] && echo presente || echo ausente)"
  local cli
  if cli="$(antigravity_cli)"; then
    if ext_installed "$cli"; then
      printf '  cline       : %s instalada\n' "$CLINE_EXT_ID"
    else
      printf '  cline       : %s AUSENTE\n' "$CLINE_EXT_ID"
    fi
  fi
  aviso "Cascade (agente nativo) não usa custom OpenAI Base URL — use o Cline para NIM"
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_antigravity
  exit 0
fi

need_cmd curl
need_cmd python3
nh_resolve_api_key

log "listando catálogo /models"
_models_tmp="$(mktemp)"
nh_list_models > "$_models_tmp"
mapfile -t LIVE_MODELS < <(head -n 40 "$_models_tmp")
rm -f "$_models_tmp"
ok "catálogo OK (mostrando até 40 ids)"
printf '  %s\n' "${LIVE_MODELS[@]:0:15}"
if [ "${#LIVE_MODELS[@]}" -gt 15 ]; then
  printf '  … (+%s)\n' "$((${#LIVE_MODELS[@]} - 15))"
fi

if [ "$DO_TEST" = 1 ]; then
  nh_validate_key
else
  aviso "pulando validação da chave (--no-test); /models não prova autenticação"
fi

nh_save_shared_env

RECOMMENDED=()
if [ -f "$MODELS_FILE" ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    RECOMMENDED+=("$line")
  done < "$MODELS_FILE"
fi

if [ "$SKIP_EXT" = 0 ]; then
  if CLI="$(antigravity_cli)"; then
    if ext_installed "$CLI"; then
      ok "extensão já instalada: $CLINE_EXT_ID"
    elif confirm "Instalar Cline ($CLINE_EXT_ID) via $CLI? (caminho BYOK no Antigravity)"; then
      log "instalando $CLINE_EXT_ID"
      if "$CLI" --install-extension "$CLINE_EXT_ID"; then
        ok "extensão instalada"
      else
        aviso "falha ao instalar via marketplace — no Antigravity: Extensions → busque 'Cline' (Open VSX)"
      fi
    else
      aviso "Cline não instalado — instale manualmente: $CLINE_EXT_ID"
    fi
  else
    aviso "CLI 'antigravity' não encontrada — instale o Cline manualmente na IDE: $CLINE_EXT_ID"
  fi
fi

has_cmd agy || aviso "agy (Antigravity CLI) não está no PATH; NIM não se aplica a ele (só Gemini-compatible)"

cat <<EOF

Pronto (Antigravity). Limitações importantes:

  • Cascade (agente nativo da IDE): sem BYOK / sem Base URL OpenAI-compatible.
    Não grave chaves inventadas tipo antigravity.openai-compatible.* no settings.json.
  • agy (CLI): só Gemini-compatible via GOOGLE_GEMINI_BASE_URL + GEMINI_API_KEY —
    não aponta para https://integrate.api.nvidia.com/v1.

Caminho suportado — Cline dentro do Antigravity:

  1. Abra o Antigravity e o painel do Cline
  2. Settings (⚙️) → API Provider → OpenAI Compatible
  3. Base URL : $NVIDIA_BASE_URL
  4. API Key  : cole a chave ($(mask_key "$NH_API_KEY"))
  5. Model ID : $DEFAULT_MODEL
     (ou outro id exato da lista abaixo)

Modelos recomendados:

EOF
if [ "${#RECOMMENDED[@]}" -gt 0 ]; then
  printf '  %s\n' "${RECOMMENDED[@]}"
else
  printf '  %s\n' "${LIVE_MODELS[@]:0:10}"
fi

cat <<EOF

  extensão : $CLINE_EXT_ID
  chave    : $NH_ENVF (compartilhada, chmod 600)
  diagnose : ./install.sh antigravity --diagnose

EOF
ok "antigravity: validação e orientação concluídas"
