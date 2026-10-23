#!/usr/bin/env bash
# Harness: OpenCode → provider NVIDIA NIM (openai-compatible).
# Mescla provider.nvidia em ~/.config/opencode/opencode.json sem apagar o resto.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

OC_JSON="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
PROVIDER_TMPL="$NH_ROOT/config/opencode-provider.json"
DO_DIAGNOSE=0
DO_TEST=1
DEFAULT_MODEL="nvidia/nemotron-3.5-super-vl-120b-a12b"
SET_DEFAULT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) NH_API_KEY_IN="${2:?}"; export NH_API_KEY_IN; shift 2 ;;
    --model) DEFAULT_MODEL="${2:?}"; SET_DEFAULT=1; shift 2 ;;
    --set-default) SET_DEFAULT=1; shift ;;
    --no-test) DO_TEST=0; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/opencode.sh [--api-key nvapi-…] [--model id] [--set-default]
                             [--no-test] [--diagnose] [--yes]
Mescla o provider "nvidia" no opencode.json (backup antes de gravar).
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

nh_diagnose_opencode() {
  nh_diagnose_common
  printf '  opencode : %s\n' "$(has_cmd opencode && command -v opencode || echo AUSENTE)"
  printf '  config   : %s (%s)\n' "$OC_JSON" "$([ -f "$OC_JSON" ] && echo presente || echo ausente)"
  if [ -f "$OC_JSON" ]; then
    python3 - "$OC_JSON" <<'PY'
import json,sys
try:
  d=json.load(open(sys.argv[1]))
except Exception as e:
  print('  json     : inválido', e); raise SystemExit
prov=(d.get('provider') or {}).get('nvidia')
print('  provider :', 'presente' if prov else 'ausente')
if prov:
  opts=prov.get('options') or {}
  print('  baseURL  :', opts.get('baseURL') or opts.get('baseUrl'))
  key=opts.get('apiKey') or ''
  print('  apiKey   :', (key[:7]+'…'+key[-4:]) if len(key)>10 else ('(vazia)' if not key else '***'))
  print('  models   :', len(prov.get('models') or {}))
print('  model    :', d.get('model'))
PY
  fi
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_opencode
  exit 0
fi

need_cmd python3
need_cmd curl
[ -f "$PROVIDER_TMPL" ] || erro "template ausente: $PROVIDER_TMPL"
has_cmd opencode || aviso "opencode não está no PATH; a config será gravada mesmo assim"

nh_resolve_api_key

log "listando catálogo /models"
nh_list_models >/dev/null
ok "catálogo /models OK"
if [ "$DO_TEST" = 1 ]; then
  nh_validate_key
else
  aviso "pulando validação da chave (--no-test); /models não prova autenticação"
fi

nh_save_shared_env

ensure_dir "$(dirname "$OC_JSON")"

if [ -f "$OC_JSON" ]; then
  has_nvidia="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(1 if (d.get("provider") or {}).get("nvidia") else 0)' "$OC_JSON")"
  if [ "$has_nvidia" = 1 ]; then
    confirm "Já existe provider.nvidia em $OC_JSON. Atualizar (merge, preservando outros providers)?" \
      || { aviso "nada alterado"; exit 0; }
  else
    confirm "Inserir provider.nvidia em $OC_JSON?" || erro "abortado"
  fi
  bak="$(backup_file "$OC_JSON")"
  [ -n "$bak" ] && ok "backup: $bak"
else
  confirm "Criar $OC_JSON com provider NVIDIA?" || erro "abortado"
fi

export OC_JSON PROVIDER_TMPL NH_API_KEY NVIDIA_BASE_URL DEFAULT_MODEL SET_DEFAULT
python3 <<'PY'
import json, os, pathlib

path = pathlib.Path(os.environ["OC_JSON"])
tmpl = json.loads(pathlib.Path(os.environ["PROVIDER_TMPL"]).read_text())
tmpl["options"]["apiKey"] = os.environ["NH_API_KEY"]
tmpl["options"]["baseURL"] = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")

if path.exists():
    data = json.loads(path.read_text())
else:
    data = {"$schema": "https://opencode.ai/config.json"}

providers = data.setdefault("provider", {})
existing = providers.get("nvidia") or {}
# Merge models: template defaults + keep any extra models the user already had.
merged_models = dict(tmpl.get("models") or {})
if isinstance(existing.get("models"), dict):
    for k, v in existing["models"].items():
        merged_models.setdefault(k, v)
# Hosted ids mortos: 3 Super retirou 2026-10-20 (404); Kimi K3 EOL 2026-10-15 (410).
for dead in ("nvidia/nemotron-3-super-120b-a12b", "moonshotai/kimi-k3"):
    merged_models.pop(dead, None)
tmpl["models"] = merged_models
# Preserve unrelated option keys, but always refresh apiKey/baseURL from this run.
opts = dict(existing.get("options") or {})
opts.update(tmpl["options"])
tmpl["options"] = opts
providers["nvidia"] = tmpl

new_default = f"nvidia/{os.environ['DEFAULT_MODEL']}"
dead_full = {
    "nvidia/deepseek-ai/deepseek-v4.1-flash",
    "nvidia/moonshotai/kimi-k3",
    "nvidia/nvidia/nemotron-3-super-120b-a12b",
}
if os.environ.get("SET_DEFAULT") == "1":
    data["model"] = new_default
elif not data.get("model") or str(data.get("model")) in dead_full:
    data["model"] = new_default

# Agent overrides keep the old model even after data.model muda — isso travou o Desktop
# (ProviderHeaderTimeoutError 300s no DeepSeek Flash).
for agent in (data.get("agent") or {}).values():
    if isinstance(agent, dict) and agent.get("model") in dead_full:
        agent["model"] = new_default

path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
os.chmod(path, 0o600)

agents_md = pathlib.Path.home() / ".config/opencode/AGENTS.md"
if agents_md.is_file():
    text = agents_md.read_text()
    old = "- Preferência: **Kimi K3** (`nvidia/moonshotai/kimi-k3`) com NVIDIA NIM, quando disponível."
    new = "- Preferência: **Nemotron 3.5 Super VL** (`nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b`) com NVIDIA NIM."
    if old in text:
        agents_md.write_text(text.replace(old, new, 1))

print("gravado:", path)
print("modelos nvidia:", len(tmpl["models"]))
print("model default:", data.get("model"))
PY

ok "OpenCode: provider nvidia configurado em $OC_JSON (permissão 600)"
echo "  uso: opencode   (selecione um modelo nvidia/… no seletor)"
echo "  diagnose: ./install.sh opencode --diagnose"
aviso "a chave fica em $OC_JSON — não compartilhe nem versione este arquivo"
