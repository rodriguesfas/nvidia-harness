#!/usr/bin/env bash
# Harness: DeepSeek Harness (dsh web) → NVIDIA NIM via pi-ai.
#
# O catálogo pi-ai do dsh lista ids hosted que 404/504 nesta conta. Este
# módulo faz smoke chat/completions (com conteúdo) e grava só quem responde
# em ~/.dsh/profiles/web/cordis.patch.yml. A chave vai para
# ~/.dsh/.credentials.yaml (refs.NVIDIA_API_KEY); o YAML só cita apiKeyEnv.
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
DSH_PATCH="${DSH_PATCH:-$DSH_HOME/profiles/web/cordis.patch.yml}"
DSH_CREDS="${DSH_CREDS:-$DSH_HOME/.credentials.yaml}"
DSH_LAUNCHER="${DSH_LAUNCHER:-$HOME/.local/bin/deepseek-harness}"
MODELS_JSON="$NH_ROOT/config/dsh-models.json"
PATCH_PY="$NH_ROOT/lib/dsh-patch.py"
DO_DIAGNOSE=0
DO_TEST=1
DEFAULT_MODEL="nvidia/nemotron-3.5-super-vl-120b-a12b"
MODEL_EXPLICIT=0

# Candidatos (ids NIM). Smoke decide quem entra no picker.
# Nome amigável vem de config/dsh-models.json.
DSH_NIM_MODELS=(
  "nvidia/nemotron-3.5-super-vl-120b-a12b"
  "nvidia/nemotron-3-ultra-550b-a55b"
  "nvidia/nemotron-3.5-lightning-30b-a3b"
  "z-ai/glm-5.3"
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
  "openai/gpt-oss-20b"
  "meta/muse-glimmer-30b"
  "meta/llama-3.2-11b-vision-instruct"
)

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key)
      [ -n "${2:-}" ] || erro "--api-key exige o valor nvapi-…"
      NH_API_KEY_IN="$2"
      export NH_API_KEY_IN
      shift 2
      ;;
    --model) DEFAULT_MODEL="${2:?}"; MODEL_EXPLICIT=1; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/deepseek.sh [--api-key nvapi-…] [--model id]
                             [--no-test] [--diagnose] [--yes]
Smoke nos candidatos NIM e grava o provider nvidia no cordis.patch.yml
do DeepSeek Harness (dsh). Chave em ~/.dsh/.credentials.yaml (600).
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

dsh_running() {
  ss -ltn '( sport = :3080 )' 2>/dev/null | grep -q '127.0.0.1:3080'
}

launcher_has_nvidia_env() {
  [ -f "$DSH_LAUNCHER" ] || return 1
  grep -q 'nvidia-harness/env' "$DSH_LAUNCHER"
}

nh_diagnose_deepseek() {
  nh_diagnose_common
  printf '  dsh home : %s (%s)\n' "$DSH_HOME" "$([ -d "$DSH_HOME" ] && echo presente || echo ausente)"
  printf '  patch    : %s (%s)\n' "$DSH_PATCH" "$([ -f "$DSH_PATCH" ] && echo presente || echo ausente)"
  printf '  creds    : %s (%s)\n' "$DSH_CREDS" "$([ -f "$DSH_CREDS" ] && echo presente || echo ausente)"
  printf '  launcher : %s (%s)\n' "$DSH_LAUNCHER" "$([ -x "$DSH_LAUNCHER" ] && echo executável || echo ausente)"
  printf '  :3080    : %s\n' "$(dsh_running && echo escuta || echo parado)"
  printf '  launchNV : %s\n' "$(launcher_has_nvidia_env && echo 'carrega nvidia-harness/env' || echo 'não carrega env compartilhado')"
  if [ -f "$DSH_PATCH" ]; then
    python3 - "$DSH_PATCH" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"(?m)^    model:\s*(\S+)", text)
print("  default  :", m.group(1) if m else "(não definido)")
block = re.search(r"(?m)^      nvidia:\n((?:        .*\n)*)", text)
ids = re.findall(r"(?m)^          - id:\s*(\S+)", block.group(1) if block else "")
print("  picker   :", ", ".join(ids) or "(nenhum)")
PY
  fi
  if [ -f "$DSH_CREDS" ]; then
    if grep -q '^[[:space:]]*NVIDIA_API_KEY:' "$DSH_CREDS"; then
      printf '  cred NV  : NVIDIA_API_KEY presente (valor oculto)\n'
    else
      printf '  cred NV  : NVIDIA_API_KEY ausente\n'
    fi
  fi
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_deepseek
  exit 0
fi

need_cmd python3
need_cmd curl
[ -f "$MODELS_JSON" ] || erro "template ausente: $MODELS_JSON"
[ -f "$PATCH_PY" ] || erro "helper ausente: $PATCH_PY"
python3 "$PATCH_PY" --selftest >/dev/null

if [ ! -d "$DSH_HOME/profiles/web" ]; then
  erro "perfil dsh ausente ($DSH_HOME/profiles/web). Abra o DeepSeek Harness uma vez (dsh web) e rode de novo."
fi

nh_resolve_api_key

ACTIVE_IDS=()
ACTIVE_JSON=""
if [ "$DO_TEST" = 1 ]; then
  log "validando candidatos dsh (chat/completions, exige conteúdo)"
  NH_SMOKE_REQUIRE_CONTENT=1
  export NH_SMOKE_REQUIRE_CONTENT
  if [ "$MODEL_EXPLICIT" = 1 ]; then
    NH_SMOKE_STRICT=1 nh_smoke_chat "$DEFAULT_MODEL" \
      || erro "modelo pedido não respondeu: $DEFAULT_MODEL"
    ACTIVE_IDS=("$DEFAULT_MODEL")
  else
    for m in "${DSH_NIM_MODELS[@]}"; do
      if NH_SMOKE_STRICT=0 nh_smoke_chat "$m"; then
        ACTIVE_IDS+=("$m")
      else
        aviso "desativando $m (NIM sem resposta útil nesta conta)"
      fi
    done
  fi
  [ "${#ACTIVE_IDS[@]}" -gt 0 ] || erro "nenhum modelo dsh respondeu nesta conta — nada a aplicar"
  NH_KEY_VALIDATED=1
  export NH_KEY_VALIDATED
else
  aviso "pulando smoke (--no-test); ativando candidatos sem prova atual"
  if [ "$MODEL_EXPLICIT" = 1 ]; then
    ACTIVE_IDS=("$DEFAULT_MODEL")
  else
    ACTIVE_IDS=("${DSH_NIM_MODELS[@]}")
  fi
fi

# Default = pedido explícito se passou, senão o primeiro candidato que sobreviveu.
CHOSEN="$DEFAULT_MODEL"
_found=0
for m in "${ACTIVE_IDS[@]}"; do
  if [ "$m" = "$DEFAULT_MODEL" ]; then
    _found=1
    break
  fi
done
if [ "$_found" != 1 ]; then
  CHOSEN="${ACTIVE_IDS[0]}"
  aviso "padrão $DEFAULT_MODEL não passou smoke; usando $CHOSEN"
fi
ok "modelos dsh ativos: ${ACTIVE_IDS[*]}"
ok "default dsh: nvidia / $CHOSEN"

nh_save_shared_env

# Recorte do catálogo JSON só com os ids que passaram.
ACTIVE_JSON="$(mktemp)"
export ACTIVE_JSON MODELS_JSON
python3 - "${ACTIVE_IDS[@]}" <<'PY'
import json, os, sys
ids = sys.argv[1:]
catalog = json.loads(open(os.environ["MODELS_JSON"], encoding="utf-8").read())
by_id = {m["id"]: m for m in catalog.get("models") or []}
out = []
for i in ids:
    rec = by_id.get(i) or {"id": i, "name": i}
    out.append({"id": rec["id"], "name": rec.get("name") or i})
json.dump(out, open(os.environ["ACTIVE_JSON"], "w", encoding="utf-8"))
PY

confirm "Gravar NVIDIA NIM no DeepSeek Harness ($CHOSEN, ${#ACTIVE_IDS[@]} modelos + chave em credentials)?" \
  || { rm -f "$ACTIVE_JSON"; aviso "nada alterado"; exit 0; }

if [ -f "$DSH_PATCH" ]; then
  bak="$(backup_file "$DSH_PATCH")"
  [ -n "$bak" ] && ok "backup: $bak"
fi
python3 "$PATCH_PY" cordis "$DSH_PATCH" "$CHOSEN" "$ACTIVE_JSON"
rm -f "$ACTIVE_JSON"
ok "picker nvidia em $DSH_PATCH"

if [ -f "$DSH_CREDS" ]; then
  bak="$(backup_file "$DSH_CREDS")"
  [ -n "$bak" ] && ok "backup: $bak"
fi
NH_API_KEY="$NH_API_KEY" python3 "$PATCH_PY" credential "$DSH_CREDS" NVIDIA_API_KEY
ok "credencial NVIDIA_API_KEY em $DSH_CREDS ($(mask_key "$NH_API_KEY"))"

if [ -f "$DSH_LAUNCHER" ] && ! launcher_has_nvidia_env; then
  if confirm "Inserir source de $NH_ENVF no launcher $DSH_LAUNCHER (fallback se a credencial faltar)?"; then
    bak="$(backup_file "$DSH_LAUNCHER")"
    [ -n "$bak" ] && ok "backup: $bak"
    python3 - "$DSH_LAUNCHER" "$NH_ENVF" <<'PY'
from pathlib import Path
import sys
path, envf = Path(sys.argv[1]), sys.argv[2]
text = path.read_text(encoding="utf-8")
snippet = f'''
# Fallback da chave NVIDIA: o dsh resolve NVIDIA_API_KEY via
# ~/.dsh/.credentials.yaml (ganha do ambiente). Sem esse ficheiro, o env
# compartilhado do nvidia-harness cobre o processo.
NH_ENV="{envf}"
if [[ -f "$NH_ENV" ]]; then
  # shellcheck disable=SC1090
  set -a
  source "$NH_ENV"
  set +a
fi
'''
needle = 'export PATH="$NODE_BIN:$PATH"\n'
if needle in text:
    text = text.replace(needle, needle + snippet, 1)
else:
    text = text.rstrip() + "\n" + snippet
path.write_text(text, encoding="utf-8")
PY
    ok "launcher passa a carregar $NH_ENVF"
  fi
elif launcher_has_nvidia_env; then
  ok "launcher já carrega nvidia-harness/env"
fi

echo "  uso: reabra o DeepSeek Harness (dock / dsh web) — sessão nova, não Kimi K3"
echo "  diagnose: ./install.sh deepseek --diagnose"
if dsh_running; then
  aviso "dsh já escuta em :3080; o HMR local costuma falhar (EMFILE) — reabra a janela para o picker novo"
fi
