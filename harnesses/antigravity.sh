#!/usr/bin/env bash
# Harness: Google Antigravity IDE → NVIDIA NIM (via Cline OpenAI Compatible).
#
# STATUS (2026-10-21): AGUARDANDO BYOK NATIVO LIBERADO PELA GOOGLE.
# O agente Cascade/Agent nativo ainda não aceita endpoint OpenAI-compatible /
# BYOK para usuário final: sem setting de modelo/Base URL/API key na IDE, e a
# inferência é feita no backend da Google (cloudcode-pa.googleapis.com). O
# `CustomModels` do language server é config enterprise/eval sincronizada do
# servidor — não é cadastro local. Quando a Google liberar BYOK no Agent
# nativo, este harness deve passar a gravar direto lá e o Cline vira legado.
# Até lá, o caminho suportado é o Cline dentro do Antigravity → API NIM.
# Este script CONFIGURA o Cline de verdade (não só orienta):
#   - globalState do Cline em ~/.config/Antigravity/User/globalStorage/state.vscdb
#     (apiProvider=openai, openAiBaseUrl, openAiModelId + plan/act mode)
#   - chave no SecretStorage da IDE (secret://…/openAiApiKey, OSCrypt v11 com a
#     senha "Antigravity Safe Storage" do gnome-keyring, via python3)
# O CLI `agy` só aceita endpoints Gemini-compatíveis — NIM não se aplica a ele.
#
# Requer o Antigravity FECHADO ao gravar o state.vscdb: a IDE mantém o estado
# em memória e sobrescreveria a edição externa ao sair.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

CLINE_EXT_ID="saoudrizwan.claude-dev"
STATE_DB="$HOME/.config/Antigravity/User/globalStorage/state.vscdb"
DO_DIAGNOSE=0
DO_TEST=1
SKIP_EXT=0
MODEL_EXPLICIT=0
DEFAULT_MODEL="z-ai/glm-5.3"
# Ordem de preferência; todos precisam passar no smoke chat/completions.
FALLBACK_MODELS=("z-ai/glm-5.3" "nvidia/nemotron-3.5-super-vl-120b-a12b" "nvidia/nemotron-3-ultra-550b-a55b" "openai/gpt-oss-20b")

antigravity_running() {
  pgrep -f "/usr/share/antigravity/antigravity" >/dev/null 2>&1 \
    || pgrep -x antigravity >/dev/null 2>&1
}

ext_installed() {
  antigravity --list-extensions 2>/dev/null | grep -qi "^${CLINE_EXT_ID}$"
}

cline_configured() {
  [ -f "$STATE_DB" ] || return 1
  python3 - "$STATE_DB" <<'PY' >/dev/null 2>&1
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("select value from ItemTable where key='saoudrizwan.claude-dev'").fetchone()
state = json.loads(row[0]) if row else {}
ok = state.get("apiProvider") == "openai" and bool(state.get("openAiBaseUrl")) and bool(state.get("openAiModelId"))
secret = con.execute("select 1 from ItemTable where key like 'secret://%saoudrizwan.claude-dev%openAiApiKey%'").fetchone()
sys.exit(0 if ok and secret else 1)
PY
}

nh_diagnose_antigravity() {
  nh_diagnose_common
  printf '  antigravity : %s\n' "$(has_cmd antigravity && command -v antigravity || echo AUSENTE)"
  printf '  agy         : %s\n' "$(has_cmd agy && command -v agy || echo AUSENTE)"
  printf '  rodando     : %s\n' "$(antigravity_running && echo sim || echo não)"
  printf '  state.vscdb : %s (%s)\n' "$STATE_DB" "$([ -f "$STATE_DB" ] && echo presente || echo ausente)"
  if has_cmd antigravity; then
    if ext_installed; then printf '  cline       : %s instalada\n' "$CLINE_EXT_ID"
    else printf '  cline       : %s AUSENTE\n' "$CLINE_EXT_ID"; fi
  fi
  if cline_configured; then
    python3 - "$STATE_DB" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
state = json.loads(con.execute("select value from ItemTable where key='saoudrizwan.claude-dev'").fetchone()[0])
print(f"  cline cfg   : provider={state.get('apiProvider')} baseUrl={state.get('openAiBaseUrl')} model={state.get('openAiModelId')} (secret openAiApiKey presente)")
PY
  else
    printf '  cline cfg   : NÃO configurado para NVIDIA NIM\n'
  fi
  aviso "Cascade (agente nativo) sem BYOK — aguardando liberação da Google (2026-10-21); use o Cline para NIM"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) NH_API_KEY_IN="${2:?}"; export NH_API_KEY_IN; shift 2 ;;
    --model) DEFAULT_MODEL="${2:?}"; MODEL_EXPLICIT=1; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --skip-extension) SKIP_EXT=1; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/antigravity.sh [--api-key nvapi-…] [--model id]
                                [--no-test] [--skip-extension] [--diagnose] [--yes]
Valida a API NIM, escolhe um modelo que responde (smoke chat/completions),
instala o Cline e GRAVA provider/baseUrl/modelo/chave no Antigravity.
Feche o Antigravity antes de rodar (ele sobrescreve o state.vscdb ao sair).
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_antigravity
  exit 0
fi

need_cmd curl
need_cmd python3
nh_resolve_api_key

# Catálogo: o modelo precisa existir E responder nesta conta (404/410 são
# comuns: modelo listado sem função provisionada, ou end-of-life).
log "listando catálogo /models"
_models_tmp="$(mktemp)"
nh_list_models > "$_models_tmp"

pick_model() {
  local m
  if [ "$MODEL_EXPLICIT" = 1 ]; then
    grep -qx "$DEFAULT_MODEL" "$_models_tmp" || erro "modelo fora do catálogo NIM: $DEFAULT_MODEL"
    NH_SMOKE_STRICT=1 nh_smoke_chat "$DEFAULT_MODEL" >&2
    printf '%s' "$DEFAULT_MODEL"; return 0
  fi
  for m in "${FALLBACK_MODELS[@]}"; do
    grep -qx "$m" "$_models_tmp" || continue
    if NH_SMOKE_STRICT=0 nh_smoke_chat "$m" >&2; then printf '%s' "$m"; return 0; fi
  done
  erro "nenhum modelo candidato respondeu nesta conta (veja config/models.default.txt)"
}

if [ "$DO_TEST" = 1 ]; then
  CHOSEN_MODEL="$(pick_model)"
else
  aviso "pulando smoke (--no-test); usando $DEFAULT_MODEL sem prova de resposta"
  CHOSEN_MODEL="$DEFAULT_MODEL"
fi
rm -f "$_models_tmp"
ok "modelo escolhido: $CHOSEN_MODEL"
NH_KEY_VALIDATED=1; export NH_KEY_VALIDATED
nh_save_shared_env

if [ "$SKIP_EXT" = 0 ]; then
  if has_cmd antigravity; then
    if ext_installed; then
      ok "extensão já instalada: $CLINE_EXT_ID"
    elif confirm "Instalar Cline ($CLINE_EXT_ID) via antigravity?"; then
      log "instalando $CLINE_EXT_ID"
      antigravity --install-extension "$CLINE_EXT_ID" || aviso "falha via marketplace — instale 'Cline' nas Extensions (Open VSX)"
    else
      aviso "Cline não instalado — instale manualmente: $CLINE_EXT_ID"
    fi
  else
    aviso "CLI 'antigravity' não encontrada — instale o Cline manualmente: $CLINE_EXT_ID"
  fi
fi

# --- Gravar a configuração no Cline -------------------------------------------
if antigravity_running; then
  erro "Antigravity está aberto e sobrescreveria o state.vscdb ao sair. Feche o Antigravity e rode de novo (a chave/modelo já estão validados)."
fi
[ -f "$STATE_DB" ] || erro "state.vscdb não encontrado: $STATE_DB (abra o Antigravity ao menos uma vez)"
ext_installed || erro "Cline ausente ($CLINE_EXT_ID) — sem ele não há onde gravar a config NIM"

confirm "Gravar Cline → NVIDIA NIM ($CHOSEN_MODEL) em $STATE_DB?" || { aviso "config não gravada"; exit 0; }
_bak="$(backup_file "$STATE_DB")"
[ -n "$_bak" ] && log "backup: $_bak"

CLINE_API_KEY="$NH_API_KEY" CLINE_BASE_URL="$NVIDIA_BASE_URL" CLINE_MODEL="$CHOSEN_MODEL" \
python3 - "$STATE_DB" <<'PY'
import json, os, sqlite3, sys

db, base_url, model = sys.argv[1], os.environ["CLINE_BASE_URL"], os.environ["CLINE_MODEL"]
api_key = os.environ["CLINE_API_KEY"]
info = {"maxTokens": 16384, "contextWindow": 131072, "supportsImages": False,
        "supportsPromptCache": False, "inputPrice": 0, "outputPrice": 0,
        "description": "NVIDIA NIM via nvidia-harness"}
patch = {
    "apiProvider": "openai", "openAiBaseUrl": base_url.rstrip("/"),
    "openAiModelId": model, "openAiModelInfo": info, "openAiHeaders": {},
    "__openAiBaseUrlV1Migrated": True,
    "planModeApiProvider": "openai", "planModeOpenAiModelId": model, "planModeOpenAiModelInfo": info,
    "actModeApiProvider": "openai", "actModeOpenAiModelId": model, "actModeOpenAiModelInfo": info,
    "welcomeViewCompleted": True,
}
con = sqlite3.connect(db)
row = con.execute("select value from ItemTable where key='saoudrizwan.claude-dev'").fetchone()
state = json.loads(row[0]) if row else {}
state.update(patch)
value = json.dumps(state)
if row:
    con.execute("update ItemTable set value=? where key='saoudrizwan.claude-dev'", (value,))
else:
    con.execute("insert into ItemTable (key, value) values ('saoudrizwan.claude-dev', ?)", (value,))

# Chave no SecretStorage (OSCrypt v11: PBKDF2-SHA1(saltysalt,1,16) + AES-128-CBC, IV=16 espaços)
secret_ok = False
try:
    import secretstorage
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC

    pw = None
    bus = secretstorage.dbus_init()
    for col in secretstorage.get_all_collections(bus):
        for item in col.get_all_items():
            if item.get_attributes().get("application") == "Antigravity":
                pw = item.get_secret(); break
        if pw: break
    if pw:
        key = PBKDF2HMAC(algorithm=hashes.SHA1(), length=16, salt=b"saltysalt", iterations=1).derive(pw)
        raw = api_key.encode()
        pad = 16 - len(raw) % 16
        raw += bytes([pad]) * pad
        enc = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
        blob = b"v11" + enc.update(raw) + enc.finalize()
        skey = 'secret://{"extensionId":"saoudrizwan.claude-dev","key":"openAiApiKey"}'
        sval = json.dumps({"type": "Buffer", "data": list(blob)})
        if con.execute("select 1 from ItemTable where key=?", (skey,)).fetchone():
            con.execute("update ItemTable set value=? where key=?", (sval, skey))
        else:
            con.execute("insert into ItemTable (key, value) values (?, ?)", (skey, sval))
        secret_ok = True
except Exception as exc:  # sem keyring: provider/modelo ficam; chave é colada 1x na UI
    print(f"aviso: SecretStorage indisponível ({type(exc).__name__}); cole a chave uma vez no Cline", file=sys.stderr)
con.commit(); con.close()
print("secret_ok=1" if secret_ok else "secret_ok=0")
PY

if cline_configured; then
  ok "Cline configurado: OpenAI Compatible → $NVIDIA_BASE_URL · $CHOSEN_MODEL"
else
  aviso "globalState gravado, mas confira no Cline (se secret_ok=0, cole a chave uma vez: $(mask_key "$NH_API_KEY") — arquivo 600 em $NH_ENVF)"
fi

cat <<EOF

Pronto (Antigravity). Abra a IDE e use o painel do Cline (não o Cascade):

  provider : OpenAI Compatible
  base URL : $NVIDIA_BASE_URL
  model    : $CHOSEN_MODEL
  chave    : SecretStorage da IDE (compartilhada também em $NH_ENVF, chmod 600)

Limitações que continuam: Cascade nativo e o CLI agy não aceitam a API NIM.
Trocar de modelo: ./install.sh antigravity --model <id-do-catálogo> (com a IDE fechada).
EOF
ok "antigravity: NVIDIA NIM configurado no Cline"
