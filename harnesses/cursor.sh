#!/usr/bin/env bash
# Harness: Cursor IDE → NVIDIA NIM (OpenAI-compatible).
# Aplica a configuração COMPLETA que sabemos funcionar nesta conta:
#   - settings.json: cursor.openai.baseUrl → https://integrate.api.nvidia.com/v1
#   - state.vscdb (reactive storage applicationUser):
#       useOpenAIKey=true, openAIBaseUrl=<base>, aiSettings.userAddedModels /
#       modelOverrideEnabled contendo SOMENTE modelos com smoke
#       chat/completions 200 nesta conta (os demais são desativados)
#   - chave no SecretStorage da IDE (secret://cursorAuth/openAIKey, OSCrypt
#     v11 com a senha "Cursor Safe Storage" do gnome-keyring, via python3)
# Modelos fora dessa lista falham na prática: 404 "Function not found for
# account" (listado em /models sem função provisionada), timeout >150s ou
# id inexistente no catálogo — verificado em 2026-10-21.
#
# Requer o Cursor FECHADO ao gravar o state.vscdb: a IDE mantém o estado em
# memória e sobrescreveria a edição externa ao sair (confirmado na prática).
# O state.vscdb do Cursor pode ter dezenas de GB — o backup é só da linha
# applicationUser (JSON), nunca uma cópia do banco inteiro.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

DO_DIAGNOSE=0
DO_TEST=1

# Únicos modelos que responderam (chat/completions 200) nesta conta em
# 2026-10-21. Não adicionar modelo sem smoke 200 — /models lista ids que
# retornam 404/timeout. Os desativados conhecidos estão em docs/TROUBLESHOOTING.md.
CURSOR_MODELS=(
  "nvidia/nemotron-3-ultra-550b-a55b"
  "nvidia/nemotron-3.5-lightning-30b-a3b"
  "openai/gpt-oss-20b"
  "meta/llama-3.2-11b-vision-instruct"
)

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

cursor_running() {
  pgrep -f "/usr/share/cursor/cursor" >/dev/null 2>&1 \
    || pgrep -x cursor >/dev/null 2>&1
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
Aplica no Cursor a configuração NVIDIA NIM validada: baseUrl em settings.json,
useOpenAIKey + somente os modelos com smoke 200 no state.vscdb e a chave no
SecretStorage da IDE. Feche o Cursor antes de rodar (ele sobrescreve o
state.vscdb ao sair).
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

SETTINGS="$(cursor_find_settings)"
STATE_DB="$(dirname "$SETTINGS")/globalStorage/state.vscdb"
APPUSER_KEY='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'

cursor_configured() {
  [ -f "$STATE_DB" ] || return 1
  python3 - "$STATE_DB" "$NVIDIA_BASE_URL" "${CURSOR_MODELS[*]}" <<'PY' >/dev/null 2>&1
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("select value from ItemTable where key='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'").fetchone()
data = json.loads(row[0]) if row else {}
want = sys.argv[3].split()
added = (data.get("aiSettings") or {}).get("userAddedModels") or []
ok = (data.get("useOpenAIKey") is True and data.get("openAIBaseUrl") == sys.argv[2]
      and bool(added) and all(m in want for m in added))
secret = con.execute("select 1 from ItemTable where key='secret://cursorAuth/openAIKey'").fetchone()
sys.exit(0 if ok and secret else 1)
PY
}

nh_diagnose_cursor() {
  nh_diagnose_common
  printf '  cursor   : %s\n' "$(has_cmd cursor && command -v cursor || echo 'não no PATH (ok se instalado via AppImage)')"
  printf '  rodando  : %s\n' "$(cursor_running && echo sim || echo não)"
  printf '  settings : %s (%s)\n' "$SETTINGS" "$([ -f "$SETTINGS" ] && echo presente || echo ausente)"
  if [ -f "$SETTINGS" ]; then
    python3 - "$SETTINGS" <<'PY'
import json,sys
try:
  d=json.load(open(sys.argv[1]))
except Exception as e:
  print('  json     : inválido', e); raise SystemExit
print('  baseUrl  :', d.get('cursor.openai.baseUrl') or '(não definido)')
PY
  fi
  printf '  state db : %s (%s)\n' "$STATE_DB" "$([ -f "$STATE_DB" ] && echo presente || echo ausente)"
  if cursor_configured; then
    printf '  nim cfg  : aplicada (useOpenAIKey + %s modelos validados + secret presente)\n' "${#CURSOR_MODELS[@]}"
  elif [ -f "$STATE_DB" ]; then
    python3 - "$STATE_DB" <<'PY' 2>/dev/null || printf '  nim cfg  : NÃO aplicada\n'
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("select value from ItemTable where key='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'").fetchone()
data = json.loads(row[0]) if row else {}
ai = data.get("aiSettings") or {}
print(f"  nim cfg  : NÃO aplicada (useOpenAIKey={data.get('useOpenAIKey')}, userAddedModels={ai.get('userAddedModels')})")
PY
  fi
  if cursor_running; then
    aviso "Cursor aberto: diagnose é leitura; para aplicar, feche o Cursor e rode de novo"
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

# Smoke em cada candidato: só entra no Cursor quem responder 200 nesta conta.
ACTIVE_MODELS=()
if [ "$DO_TEST" = 1 ]; then
  log "validando modelos candidatos (chat/completions)"
  for m in "${CURSOR_MODELS[@]}"; do
    if NH_SMOKE_STRICT=0 nh_smoke_chat "$m"; then
      ACTIVE_MODELS+=("$m")
    else
      aviso "desativando $m (sem resposta útil nesta conta)"
    fi
  done
  [ "${#ACTIVE_MODELS[@]}" -gt 0 ] || erro "nenhum modelo validado respondeu nesta conta — nada a aplicar"
  NH_KEY_VALIDATED=1; export NH_KEY_VALIDATED
else
  aviso "pulando smoke (--no-test); ativando os ${#CURSOR_MODELS[@]} modelos validados em 2026-10-21 sem prova atual"
  ACTIVE_MODELS=("${CURSOR_MODELS[@]}")
fi
ok "modelos ativos: ${ACTIVE_MODELS[*]}"

nh_save_shared_env

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

# --- Gravar modelos + chave no state.vscdb ------------------------------------
if cursor_running; then
  erro "Cursor está aberto e sobrescreveria o state.vscdb ao sair. Feche o Cursor e rode de novo (chave/modelos já validados; baseUrl já gravada)."
fi
[ -f "$STATE_DB" ] || erro "state.vscdb não encontrado: $STATE_DB (abra o Cursor ao menos uma vez)"

confirm "Gravar no Cursor somente os modelos validados (${ACTIVE_MODELS[*]}) e a chave NVIDIA?" || { aviso "state.vscdb não gravado"; exit 0; }

ensure_dir "$NH_CONFIG_DIR/backups"
CURSOR_API_KEY="$NH_API_KEY" CURSOR_BASE_URL="$NVIDIA_BASE_URL" \
CURSOR_MODELS_JOINED="${ACTIVE_MODELS[*]}" NH_BACKUP_DIR="$NH_CONFIG_DIR/backups" \
python3 - "$STATE_DB" "$APPUSER_KEY" <<'PY'
import datetime, json, os, pathlib, sqlite3, sys

db, appkey = sys.argv[1], sys.argv[2]
base_url, api_key = os.environ["CURSOR_BASE_URL"], os.environ["CURSOR_API_KEY"]
models = os.environ["CURSOR_MODELS_JOINED"].split()
con = sqlite3.connect(db, timeout=30)
con.execute("PRAGMA busy_timeout=30000")
row = con.execute("select value from ItemTable where key=?", (appkey,)).fetchone()
data = json.loads(row[0]) if row else {}
secret_row = con.execute("select value from ItemTable where key='secret://cursorAuth/openAIKey'").fetchone()

# Backup SOMENTE das linhas tocadas (o banco pode ter dezenas de GB).
bak_dir = pathlib.Path(os.environ["NH_BACKUP_DIR"]); bak_dir.mkdir(parents=True, exist_ok=True)
stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
bak = bak_dir / f"cursor-state-{stamp}.json"
bak.write_text(json.dumps({"applicationUser": row[0] if row else None,
                           "openAIKey_present": bool(secret_row)}, ensure_ascii=False))
bak.chmod(0o600)
print(f"backup das linhas: {bak}")

ai = data.setdefault("aiSettings", {})
before = list(ai.get("userAddedModels") or [])
removed = [m for m in before if m not in models]
enabled = [m for m in (ai.get("modelOverrideEnabled") or []) if m not in removed]
for m in models:
    if m not in enabled:
        enabled.append(m)
ai["userAddedModels"] = models
ai["modelOverrideEnabled"] = enabled
data["useOpenAIKey"] = True
data["openAIBaseUrl"] = base_url
value = json.dumps(data, ensure_ascii=False)
if row:
    con.execute("update ItemTable set value=? where key=?", (value, appkey))
else:
    con.execute("insert into ItemTable (key, value) values (?, ?)", (appkey, value))

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
            if item.get_attributes().get("application") == "Cursor":
                pw = item.get_secret(); break
        if pw: break
    if pw:
        key = PBKDF2HMAC(algorithm=hashes.SHA1(), length=16, salt=b"saltysalt", iterations=1).derive(pw)
        raw = api_key.encode()
        pad = 16 - len(raw) % 16
        raw += bytes([pad]) * pad
        enc = Cipher(algorithms.AES(key), modes.CBC(b" " * 16)).encryptor()
        blob = b"v11" + enc.update(raw) + enc.finalize()
        sval = json.dumps({"type": "Buffer", "data": list(blob)})
        skey = "secret://cursorAuth/openAIKey"
        if secret_row:
            con.execute("update ItemTable set value=? where key=?", (sval, skey))
        else:
            con.execute("insert into ItemTable (key, value) values (?, ?)", (skey, sval))
        secret_ok = True
except Exception as exc:  # sem keyring: modelos ficam; chave é colada 1x na UI
    print(f"aviso: SecretStorage indisponível ({type(exc).__name__}); cole a chave uma vez no Cursor", file=sys.stderr)
con.commit(); con.close()
print("desativados:", ", ".join(removed) if removed else "(nenhum)")
print("secret_ok=1" if secret_ok else "secret_ok=0")
PY

if cursor_configured; then
  ok "Cursor configurado: baseUrl + useOpenAIKey + ${#ACTIVE_MODELS[@]} modelos validados + chave no SecretStorage"
else
  aviso "state.vscdb gravado, mas a conferência falhou (se secret_ok=0, cole a chave uma vez: Ctrl+Shift+J → Models → OpenAI API Key: $(mask_key "$NH_API_KEY") — arquivo 600 em $NH_ENVF)"
fi

cat <<EOF

Pronto (Cursor). Abra a IDE e escolha um dos modelos validados em Settings → Models:

EOF
printf '  %s\n' "${ACTIVE_MODELS[@]}"
cat <<EOF

Qualquer outro id da NVIDIA está desativado de propósito (404/timeout nesta
conta). Para reativar um modelo no futuro, prove antes com chat/completions.
EOF
ok "cursor: configuração NVIDIA NIM aplicada"
echo "  diagnose: ./install.sh cursor --diagnose"
