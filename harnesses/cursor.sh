#!/usr/bin/env bash
# Harness: Cursor IDE → proxy local → NVIDIA NIM (+ pool grátis OpenCode se :4000).
#
# Sem passo manual na UI: instala o shim (flatten Harmony + rota coder/fast),
# sobe systemd --user, grava settings.json, useOpenAIKey, modelos com smoke
# 200+conteúdo e a chave no SecretStorage. Feche o Cursor antes de gravar o
# state.vscdb — a IDE reverte edição externa ao sair.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"
# shellcheck source=../lib/cursor-proxy.sh
source "$_HDIR/../lib/cursor-proxy.sh"

DO_DIAGNOSE=0
DO_TEST=1
FORCE_OPEN=0

# NIM: ids da conta NVIDIA. FREE: pool LiteLLM do OpenCode via proxy :12436.
# Prefixo no picker: nvidia/… = NIM; opencode/… = pool grátis. Sem prefixo = Cursor nativo.
CURSOR_NIM_MODELS=(
  "nvidia/nemotron-3.5-super-vl-120b-a12b"
  "nvidia/nemotron-3-ultra-550b-a55b"
  "nvidia/nemotron-3.5-lightning-30b-a3b"
  "nvidia/openai/gpt-oss-20b"
  "nvidia/meta/llama-3.2-11b-vision-instruct"
)
CURSOR_FREE_MODELS=(
  "opencode/coder"
  "opencode/fast"
  "opencode/gemini-flash"
  "opencode/gemini-lite"
  "opencode/mistral-medium"
  "opencode/mistral-small"
  "opencode/codestral"
  "opencode/openrouter-free"
  "opencode/groq-gpt-oss-20b"
  "opencode/groq-qwen3.8-27b"
  "opencode/local-qwen7b"
)

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
    --api-key)
      [ -n "${2:-}" ] || erro "--api-key exige o valor nvapi-…"
      NH_API_KEY_IN="$2"
      export NH_API_KEY_IN
      shift 2
      ;;
    --no-test) DO_TEST=0; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    --force-open) FORCE_OPEN=1; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/cursor.sh [--api-key nvapi-…] [--no-test] [--diagnose] [--yes] [--force-open]
Instala o proxy local (:12436), valida modelos e grava a config no Cursor
(baseUrl, useOpenAIKey, modelos com smoke, chave). Feche o Cursor antes
(ou --force-open). Pool OpenCode (coder/fast/…) só entra se o LiteLLM :4000
estiver no ar.
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
  local want="${1:-}"
  [ -f "$STATE_DB" ] || return 1
  python3 - "$STATE_DB" "${CURSOR_BASE_URL:-$CURSOR_PROXY_URL}" "$want" <<'PY' >/dev/null 2>&1
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("select value from ItemTable where key='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'").fetchone()
data = json.loads(row[0]) if row else {}
proxy, want = sys.argv[2], sys.argv[3].split()
added = (data.get("aiSettings") or {}).get("userAddedModels") or []
ok = (data.get("useOpenAIKey") is True
      and data.get("openAIBaseUrl") == proxy
      and bool(added)
      and (not want or added == want))
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
  printf '  proxy    : %s (%s)\n' "$CURSOR_PROXY_URL" "$(cursor_proxy_up && echo ativo || echo ausente)"
  printf '  public   : %s\n' "$(nh_cursor_public_base_url 2>/dev/null || echo '(ausente — Agent 403 em 127.0.0.1)')"
  if has_cmd systemctl; then
    printf '  unit     : %s (%s)\n' "$NH_PROXY_UNIT_NAME" \
      "$(systemctl --user is-active "$NH_PROXY_UNIT_NAME" 2>/dev/null || echo inativo)"
    printf '  enabled  : %s\n' \
      "$(systemctl --user is-enabled "$NH_PROXY_UNIT_NAME" 2>/dev/null || echo disabled)"
  fi
  if has_cmd loginctl; then
    printf '  linger   : %s\n' \
      "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo desconhecido)"
  fi
  printf '  free-rtr : %s (%s)\n' "$NH_FREE_ROUTER_URL" "$(nh_free_router_up && echo ativo || echo ausente)"
  printf '  state db : %s (%s)\n' "$STATE_DB" "$([ -f "$STATE_DB" ] && echo presente || echo ausente)"
  if [ -f "$STATE_DB" ]; then
    python3 - "$STATE_DB" <<'PY'
import json, sqlite3, sys

def bucket(m):
    if m.startswith("opencode/") or m.startswith("free-router/"):
        return "opencode"
    if m.startswith("nvidia/") or m.startswith("meta/") or m.startswith("openai/"):
        return "nvidia"
    return "cursor"

con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = con.execute("select value from ItemTable where key='src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser'").fetchone()
data = json.loads(row[0]) if row else {}
ai = data.get("aiSettings") or {}
added = ai.get("userAddedModels") or []
print(f"  useKey   : {data.get('useOpenAIKey')}")
print(f"  stateUrl : {data.get('openAIBaseUrl')}")
secret = con.execute("select 1 from ItemTable where key='secret://cursorAuth/openAIKey'").fetchone()
print(f"  secret   : {'presente' if secret else 'ausente'}")
groups = {"nvidia": [], "opencode": [], "cursor": []}
for m in added:
    groups[bucket(m)].append(m)
print("  nvidia   :", ", ".join(groups["nvidia"]) or "(nenhum)")
print("  opencode :", ", ".join(groups["opencode"]) or "(nenhum — feche o Cursor e rode ./install.sh cursor --yes)")
print("  cursor   :", "(nativos da IDE, fora desta lista)")
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
nh_ensure_cursor_proxy || aviso "seguindo sem proxy local — Agent do Cursor pode falhar no flatten Harmony"

CURSOR_BASE_URL="$NVIDIA_BASE_URL"
SMOKE_URL="$NVIDIA_BASE_URL"
FREE_ON=0
if cursor_proxy_up; then
  SMOKE_URL="$CURSOR_PROXY_URL"
  CURSOR_BASE_URL="$CURSOR_PROXY_URL"
  public="$(nh_cursor_public_base_url || true)"
  if [ -n "$public" ]; then
    CURSOR_BASE_URL="$public"
    ok "BYOK Cursor via URL pública: $CURSOR_BASE_URL"
  else
    aviso "sem URL pública — o Agent do Cursor recusa 127.0.0.1 (SSRF 403)"
  fi
  if nh_free_router_up; then
    FREE_ON=1
    ok "proxy + pool OpenCode (:4000) — NIM e coder/fast/…"
  else
    ok "proxy Cursor ativo — só NIM neste host (LiteLLM :4000 ausente)"
  fi
else
  aviso "proxy $CURSOR_PROXY_URL ausente — Base URL NVIDIA direta (sem flatten, sem coder/fast)"
fi

ACTIVE_MODELS=()
if [ "$DO_TEST" = 1 ]; then
  log "validando modelos candidatos (chat/completions, exige conteúdo)"
  NVIDIA_BASE_URL_ORIG="$NVIDIA_BASE_URL"
  NVIDIA_BASE_URL="$SMOKE_URL" NH_SMOKE_REQUIRE_CONTENT=1
  export NVIDIA_BASE_URL NH_SMOKE_REQUIRE_CONTENT
  for m in "${CURSOR_NIM_MODELS[@]}"; do
    if NH_SMOKE_STRICT=0 nh_smoke_chat "$m"; then
      ACTIVE_MODELS+=("$m")
    else
      aviso "desativando $m (NIM sem resposta útil nesta conta)"
    fi
  done
  if [ "$FREE_ON" = 1 ]; then
    for m in "${CURSOR_FREE_MODELS[@]}"; do
      if NH_SMOKE_STRICT=0 nh_smoke_chat "$m"; then
        ACTIVE_MODELS+=("$m")
      else
        aviso "desativando $m (pool OpenCode sem conteúdo útil agora)"
      fi
    done
  fi
  NVIDIA_BASE_URL="$NVIDIA_BASE_URL_ORIG"
  export NVIDIA_BASE_URL
  [ "${#ACTIVE_MODELS[@]}" -gt 0 ] || erro "nenhum modelo validado respondeu nesta conta — nada a aplicar"
  NH_KEY_VALIDATED=1; export NH_KEY_VALIDATED
else
  aviso "pulando smoke (--no-test); ativando candidatos sem prova atual"
  ACTIVE_MODELS=("${CURSOR_NIM_MODELS[@]}")
  if [ "$FREE_ON" = 1 ]; then
    ACTIVE_MODELS+=("${CURSOR_FREE_MODELS[@]}")
  fi
fi
ok "modelos ativos: ${ACTIVE_MODELS[*]}"

nh_save_shared_env
nh_write_proxy_env
nh_write_cursor_byok_json "${ACTIVE_MODELS[*]}"
nh_install_cursor_byok_timer

cursor_write_settings() {
  local current=""
  ensure_dir "$(dirname "$SETTINGS")"
  if [ -f "$SETTINGS" ]; then
    current="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("cursor.openai.baseUrl") or "")' "$SETTINGS" 2>/dev/null || true)"
  fi
  if [ "$current" = "$CURSOR_BASE_URL" ]; then
    ok "baseUrl já está correta"
    return 0
  fi
  case "$current" in
    ""|"$NVIDIA_BASE_URL"|"$CURSOR_PROXY_URL"|"$SMOKE_URL"|"http://127.0.0.1:12436/v1"|"https://integrate.api.nvidia.com/v1")
      ;;
    *)
      confirm "Substituir cursor.openai.baseUrl ($current → $CURSOR_BASE_URL)?" || {
        aviso "mantendo settings intacto"
        return 0
      }
      ;;
  esac
  if [ -f "$SETTINGS" ]; then
    bak="$(backup_file "$SETTINGS")"
    [ -n "$bak" ] && ok "backup: $bak"
  fi
  CURSOR_BASE_URL="$CURSOR_BASE_URL" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os, pathlib
p = pathlib.Path(os.environ["SETTINGS"])
data = json.loads(p.read_text()) if p.exists() else {}
data["cursor.openai.baseUrl"] = os.environ["CURSOR_BASE_URL"]
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print("gravado:", p)
PY
  ok "cursor.openai.baseUrl = $CURSOR_BASE_URL"
}

cursor_write_settings

if cursor_running; then
  if [ "$FORCE_OPEN" = 1 ]; then
    aviso "Cursor aberto (--force-open): gravando state.vscdb; a IDE pode reverter ao sair"
  else
    aviso "proxy e settings prontos. Feche o Cursor e rode de novo para gravar modelos/chave no state.vscdb:"
    echo "  NVIDIA_NIM_API_KEY=… ./install.sh cursor --yes"
    exit 0
  fi
fi
[ -f "$STATE_DB" ] || erro "state.vscdb não encontrado: $STATE_DB (abra o Cursor ao menos uma vez, feche, e rode de novo)"

if ! python3 -c 'import secretstorage, cryptography' >/dev/null 2>&1; then
  aviso "instalando secretstorage+cryptography (pip --user) para gravar a chave no Cursor"
  python3 -m pip install --user -q secretstorage cryptography >/dev/null 2>&1 \
    || aviso "pip --user falhou; se a chave não gravar, cole uma vez em Settings → Models"
fi

log "gravando modelos validados e chave no Cursor"
ensure_dir "$NH_CONFIG_DIR/backups"
CURSOR_API_KEY="$NH_API_KEY" CURSOR_BASE_URL="$CURSOR_BASE_URL" \
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
except Exception as exc:
    print(f"aviso: SecretStorage indisponível ({type(exc).__name__}); cole a chave uma vez no Cursor", file=sys.stderr)
con.commit(); con.close()
print("desativados:", ", ".join(removed) if removed else "(nenhum)")
print("secret_ok=1" if secret_ok else "secret_ok=0")
PY

if cursor_configured "${ACTIVE_MODELS[*]}"; then
  ok "Cursor configurado: proxy + ${#ACTIVE_MODELS[@]} modelos validados + chave"
else
  aviso "state.vscdb gravado; se a chave não aparecer, cole uma vez em Settings → Models ($(mask_key "$NH_API_KEY"))"
fi

cat <<EOF

Pronto (Cursor). No picker, o prefixo diz a origem:

  nvidia/…     NIM (conta NVIDIA)
  opencode/…   pool grátis do OpenCode (LiteLLM :4000)
  sem prefixo  nativos do Cursor (claude-*, gpt-5*, composer-*)

EOF
echo "NVIDIA NIM:"
printf '  %s\n' "${ACTIVE_MODELS[@]}" | grep '^  nvidia/' || echo "  (nenhum)"
echo "OpenCode:"
printf '  %s\n' "${ACTIVE_MODELS[@]}" | grep '^  opencode/' || echo "  (nenhum — LiteLLM :4000 ausente ou Cursor estava aberto)"
if [ "$FREE_ON" != 1 ]; then
  echo
  echo "Pool OpenCode não entrou: LiteLLM em $NH_FREE_ROUTER_URL ausente."
  echo "Com o free-router no ar: ./install.sh cursor --yes"
fi
ok "cursor: proxy + NVIDIA NIM aplicados"
echo "  diagnose: ./install.sh cursor --diagnose"
