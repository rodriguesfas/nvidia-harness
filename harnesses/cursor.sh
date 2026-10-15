#!/usr/bin/env bash
# Harness: Cursor IDE → NVIDIA NIM (OpenAI-compatible base URL).
# O Cursor não expõe CLI estável para cadastrar Model Names; o script grava a
# baseUrl, valida a API e imprime os ids para colar em Settings → Models.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

MODELS_FILE="$NH_ROOT/config/models.default.txt"
DO_DIAGNOSE=0
DO_TEST=1

# Possíveis caminhos do settings.json (AppImage / .deb / flatpak-ish).
cursor_settings_candidates() {
  cat <<EOF
$HOME/.config/Cursor/User/settings.json
$HOME/.config/cursor/User/settings.json
EOF
}

cursor_find_settings() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p" ] || [ -d "$(dirname "$p")" ]; then
      printf '%s' "$p"
      return 0
    fi
  done < <(cursor_settings_candidates)
  printf '%s' "$HOME/.config/Cursor/User/settings.json"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) NH_API_KEY_IN="${2:?}"; export NH_API_KEY_IN; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/cursor.sh [--api-key nvapi-…] [--no-test] [--diagnose] [--yes]
Configura cursor.openai.baseUrl → \$NVIDIA_BASE_URL e valida a API NIM.
A chave OpenAI do Cursor deve ser colada na UI (não gravamos a chave no settings.json).
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

SETTINGS="$(cursor_find_settings)"

nh_diagnose_cursor() {
  nh_diagnose_common
  printf '  cursor   : %s\n' "$(has_cmd cursor && command -v cursor || echo 'não no PATH (ok se instalado via AppImage)')"
  printf '  settings : %s (%s)\n' "$SETTINGS" "$([ -f "$SETTINGS" ] && echo presente || echo ausente)"
  if [ -f "$SETTINGS" ]; then
    python3 - "$SETTINGS" <<'PY'
import json,sys
p=sys.argv[1]
try:
  d=json.load(open(p))
except Exception as e:
  print('  json     : inválido', e); raise SystemExit
print('  baseUrl  :', d.get('cursor.openai.baseUrl') or d.get('cursor.openai.baseURL') or '(não definido)')
PY
  fi
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_cursor
  exit 0
fi

need_cmd python3
need_cmd curl
nh_resolve_api_key

log "listando catálogo público /models"
_models_tmp="$(mktemp)"
nh_list_models > "$_models_tmp"
mapfile -t LIVE_MODELS < <(head -n 40 "$_models_tmp")
rm -f "$_models_tmp"
ok "catálogo OK (mostrando até 40 ids)"
printf '  %s\n' "${LIVE_MODELS[@]:0:15}"
if [ "${#LIVE_MODELS[@]}" -gt 15 ]; then
  printf '  … (+%s)\n' "$((${#LIVE_MODELS[@]} - 15))"
fi

# /models não autentica de fato — a chave só é comprovada no chat.
if [ "$DO_TEST" = 1 ]; then
  nh_validate_key
else
  aviso "pulando validação da chave (--no-test); /models não prova autenticação"
fi

nh_save_shared_env

# Modelos recomendados (interseção com defaults, se possível).
RECOMMENDED=()
if [ -f "$MODELS_FILE" ]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    RECOMMENDED+=("$line")
  done < "$MODELS_FILE"
fi

log "configurando $SETTINGS"
ensure_dir "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
  current="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("cursor.openai.baseUrl") or "")' "$SETTINGS" 2>/dev/null || true)"
  if [ "$current" = "$NVIDIA_BASE_URL" ]; then
    ok "baseUrl já está correta — nada a gravar"
  else
    if [ -n "$current" ]; then
      confirm "Substituir cursor.openai.baseUrl ($current → $NVIDIA_BASE_URL)?" || {
        aviso "mantendo settings intacto"
        current_skip=1
      }
    fi
    if [ "${current_skip:-0}" != 1 ]; then
      bak="$(backup_file "$SETTINGS")"
      [ -n "$bak" ] && ok "backup: $bak"
      NVIDIA_BASE_URL="$NVIDIA_BASE_URL" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["SETTINGS"])
data = json.loads(p.read_text()) if p.exists() else {}
data["cursor.openai.baseUrl"] = os.environ["NVIDIA_BASE_URL"]
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("gravado:", p)
PY
      ok "cursor.openai.baseUrl = $NVIDIA_BASE_URL"
    fi
  fi
else
  confirm "Criar $SETTINGS com baseUrl NVIDIA?" || erro "abortado"
  NVIDIA_BASE_URL="$NVIDIA_BASE_URL" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["SETTINGS"])
p.parent.mkdir(parents=True, exist_ok=True)
data = {"cursor.openai.baseUrl": os.environ["NVIDIA_BASE_URL"]}
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("criado:", p)
PY
  ok "settings criado"
fi

cat <<EOF

Pronto (Cursor). Passos manuais restantes — a IDE não permite cadastrar Model Names via CLI:

  1. Ctrl+Shift+J → Models
  2. OpenAI API Key: cole a chave ($(mask_key "$NH_API_KEY")) — não fica no settings.json
  3. Override OpenAI Base URL já aponta para: $NVIDIA_BASE_URL
  4. + Add custom model e cole (recomendados):

EOF
if [ "${#RECOMMENDED[@]}" -gt 0 ]; then
  printf '     %s\n' "${RECOMMENDED[@]}"
else
  printf '     %s\n' "${LIVE_MODELS[@]:0:10}"
fi
echo
ok "cursor: configuração base concluída"
echo "  diagnose: ./install.sh cursor --diagnose"
