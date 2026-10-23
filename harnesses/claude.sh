#!/usr/bin/env bash
# Harness: Claude Code + proxy LiteLLM → NVIDIA NIM (+ pool OpenCode se :4000).
# Pode ser chamado via ./install.sh claude ou diretamente.
# Idempotente: preserva chave, master key e o restante do settings.json.
#
#   ./harnesses/claude.sh [--api-key nvapi-xxx] [--model nvidia_nim/...]
#                         [--small-model nvidia_nim/...] [--no-test] [--e2e] [--diagnose]
# shellcheck disable=SC1090,SC1091
set -euo pipefail

_HDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_HDIR/../lib/common.sh"
# shellcheck source=../lib/nvidia.sh
source "$_HDIR/../lib/nvidia.sh"
# shellcheck source=../lib/claude-proxy.sh
source "$_HDIR/../lib/claude-proxy.sh"

PREFIX="$HOME"
BIN_DIR="$PREFIX/.local/bin"
VENV_DIR="$PREFIX/.claude-nvidia/venv"
CONFIG_DIR="$PREFIX/.config/claude-nvidia"
ENVF="$CONFIG_DIR/env"
CONF="$CONFIG_DIR/config.yaml"
WRAPPER="$BIN_DIR/claude-nvidia"
SETTINGS="$PREFIX/.claude/settings.json"
MODELS_JSON="$NH_ROOT/config/claude-models.json"
LITELLM_SPEC="litellm[proxy]==1.104.0"
MARKER="# gerado por install-nvidia-claude-code.sh / nvidia-harness"

NV_MODEL_DEFAULT="nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b"
NV_SMALL_DEFAULT="nvidia_nim/openai/gpt-oss-20b"
API_KEY_IN="${NH_API_KEY_IN:-${NVIDIA_NIM_API_KEY:-}}"
MODEL_FROM_FLAG=0
SMALL_FROM_FLAG=0
DO_TEST=1
DO_E2E=0
DO_DIAGNOSE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --api-key) API_KEY_IN="${2:?}"; NH_API_KEY_IN="$API_KEY_IN"; shift 2 ;;
    --model) NV_MODEL_DEFAULT="${2:?}"; MODEL_FROM_FLAG=1; shift 2 ;;
    --small-model) NV_SMALL_DEFAULT="${2:?}"; SMALL_FROM_FLAG=1; shift 2 ;;
    --no-test) DO_TEST=0; shift ;;
    --e2e) DO_E2E=1; shift ;;
    --diagnose) DO_DIAGNOSE=1; shift ;;
    --yes|-y) NH_YES=1; export NH_YES; shift ;;
    -h|--help)
      cat <<EOF
Uso: ./harnesses/claude.sh [--api-key nvapi-…] [--model id] [--small-model id]
                           [--no-test] [--e2e] [--diagnose] [--yes]
Instala proxy LiteLLM + wrapper claude-nvidia (NVIDIA NIM).
Pool OpenCode (opencode-coder/fast/…) entra se o LiteLLM :4000 estiver no ar.
Prefira NVIDIA_NIM_API_KEY=… no ambiente em vez de --api-key.
EOF
      exit 0
      ;;
    *) erro "argumento desconhecido: $1" ;;
  esac
done

nh_diagnose_claude() {
  nh_diagnose_common
  printf '  claude   : %s\n' "$(has_cmd claude && command -v claude || echo AUSENTE)"
  printf '  wrapper  : %s\n' "$([ -x "$WRAPPER" ] && echo "$WRAPPER" || echo ausente)"
  printf '  venv     : %s\n' "$([ -x "$VENV_DIR/bin/litellm" ] && echo "$VENV_DIR" || echo ausente)"
  printf '  config   : %s\n' "$([ -f "$CONF" ] && echo "$CONF" || echo ausente)"
  printf '  settings : %s\n' "$([ -f "$SETTINGS" ] && echo "$SETTINGS" || echo ausente)"
  if [ -f "$ENVF" ]; then
    # shellcheck disable=SC1090
    set +e; source "$ENVF" >/dev/null 2>&1; set -e
    printf '  NV_MODEL : %s\n' "${NV_MODEL:-}"
    printf '  key file : %s\n' "$(mask_key "${NVIDIA_NIM_API_KEY:-}")"
    printf '  oc key   : %s\n' "$( [ -n "${NH_FREE_ROUTER_KEY:-}" ] && mask_key "$NH_FREE_ROUTER_KEY" || echo ausente )"
  fi
  if [ -f "$CONF" ]; then
    _names="$(grep -E '^[[:space:]]*-[[:space:]]*model_name:' "$CONF" | sed -E 's/.*model_name:[[:space:]]*//' || true)"
    printf '  nvidia   : %s\n' "$(printf '%s\n' "$_names" | grep '^nvidia-' | paste -sd', ' - || echo '(nenhum)')"
    printf '  opencode : %s\n' "$(printf '%s\n' "$_names" | grep '^opencode-' | paste -sd', ' - || echo '(nenhum — LiteLLM :4000 ausente na instalação)')"
  fi
  NH_CLAUDE_CONFIG_DIR="$CONFIG_DIR" NH_CLAUDE_VENV_DIR="$VENV_DIR" nh_diagnose_claude_proxy
  if [ -f "$SETTINGS" ]; then
    python3 - "$SETTINGS" <<'PY' || true
import json, sys
d = json.load(open(sys.argv[1]))
env = d.get("env") or {}
print("  base URL : %s" % (env.get("ANTHROPIC_BASE_URL") or "(não gravado em settings.json)"))
print("  default  : %s" % (d.get("model") or "(sem model)"))
PY
  fi
}

if [ "$DO_DIAGNOSE" = 1 ]; then
  NH_SOFT_KEY=1 nh_resolve_api_key || true
  nh_diagnose_claude
  exit 0
fi

# ---------------------------------------------------------------- dependências
for c in python3 curl; do
  command -v "$c" >/dev/null 2>&1 || erro "precisa de '$c' no PATH"
done
command -v claude >/dev/null 2>&1 \
  || aviso "Claude Code não encontrado (npm i -g @anthropic-ai/claude-code); o wrapper instala, mas não roda."

# ------------------------------------------------------------------- venv + litellm
if [ -x "$VENV_DIR/bin/litellm" ] && "$VENV_DIR/bin/litellm" --version >/dev/null 2>&1; then
  ok "venv já existe: $VENV_DIR ($("$VENV_DIR/bin/pip" show litellm 2>/dev/null | awk '/^Version:/{print $2}'))"
else
  log "criando venv e instalando $LITELLM_SPEC (pode demorar)"
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip -q
  "$VENV_DIR/bin/pip" install -q "$LITELLM_SPEC"
  ok "LiteLLM instalado em $VENV_DIR"
fi

# ------------------------------------------------------------------------ env
mkdir -p "$CONFIG_DIR" "$BIN_DIR"
chmod 700 "$CONFIG_DIR" 2>/dev/null || true

# Preserva o que já está instalado (chave, master key e modelos) antes de reescrever.
OLD_API_KEY=""
OLD_MASTER=""
OLD_MODEL=""
OLD_SMALL=""
if [ -f "$ENVF" ]; then
  mapfile -t _old < <(set +e; source "$ENVF" >/dev/null 2>&1
    printf '%s\n%s\n%s\n%s\n' "${NVIDIA_NIM_API_KEY:-}" "${LITELLM_MASTER_KEY:-}" \
      "${NV_MODEL:-}" "${NV_SMALL_MODEL:-}")
  OLD_API_KEY="${_old[0]:-}"
  OLD_MASTER="${_old[1]:-}"
  OLD_MODEL="${_old[2]:-}"
  OLD_SMALL="${_old[3]:-}"
  if [ "$MODEL_FROM_FLAG" = 0 ] && [ -n "$OLD_MODEL" ]; then NV_MODEL_DEFAULT="$OLD_MODEL"; fi
  if [ "$SMALL_FROM_FLAG" = 0 ] && [ -n "$OLD_SMALL" ]; then NV_SMALL_DEFAULT="$OLD_SMALL"; fi
fi

# Hosted Nemotron 3 Super retirou em 2026-10-20 (404 Function not found).
# Reinstalar sem --model não deve regravar o id morto a partir do env antigo.
if [ "$MODEL_FROM_FLAG" = 0 ]; then
  case "$NV_MODEL_DEFAULT" in
    *nemotron-3-super-120b-a12b)
      aviso "NV_MODEL $NV_MODEL_DEFAULT foi retirado pela NVIDIA em 2026-10-20; usando nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b"
      NV_MODEL_DEFAULT="nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b"
      ;;
  esac
fi

if [ -z "$API_KEY_IN" ] && [ -z "$OLD_API_KEY" ]; then
  NH_API_KEY_IN=""
  nh_resolve_api_key
  API_KEY_IN="$NH_API_KEY"
elif [ -z "$API_KEY_IN" ] && [ -n "$OLD_API_KEY" ]; then
  API_KEY_IN="$OLD_API_KEY"
fi
API_KEY="$API_KEY_IN"
[ -n "$API_KEY" ] || erro "chave NVIDIA ausente (use --api-key ou NVIDIA_NIM_API_KEY)"

MASTER_KEY="${OLD_MASTER:-}"
if [ -z "$MASTER_KEY" ]; then
  MASTER_KEY="sk-$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  log "gerando LITELLM_MASTER_KEY novo"
fi

NH_API_KEY="$API_KEY"
export NVIDIA_NIM_API_KEY="$API_KEY"
[ -f "$MODELS_JSON" ] || erro "template ausente: $MODELS_JSON"

nh_detect_free_router_key || true
nh_try_start_free_router || true
FREE_ON=0
if [ -n "${NH_FREE_ROUTER_KEY:-}" ] && nh_free_router_up; then
  FREE_ON=1
  ok "pool OpenCode ativo em $NH_FREE_ROUTER_URL"
else
  aviso "LiteLLM :4000 ausente — Claude Code fica só com NVIDIA NIM (opencode-* não entram)"
fi

ACTIVE_NIM=()
ACTIVE_OC=()
if [ "$DO_TEST" = 1 ]; then
  log "validando atalhos NVIDIA (chat/completions, exige conteúdo)"
  while IFS= read -r name && IFS= read -r smoke; do
    [ -n "$name" ] || continue
    if NH_SMOKE_STRICT=0 NH_SMOKE_REQUIRE_CONTENT=1 nh_smoke_chat "$smoke"; then
      ACTIVE_NIM+=("$name")
    else
      aviso "desativando $name (NIM sem resposta útil nesta conta: $smoke)"
    fi
  done < <(python3 - "$MODELS_JSON" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])).get("nvidia_aliases") or []:
    print(a["model_name"]); print(a["smoke_id"])
PY
)
  if [ "$FREE_ON" = 1 ]; then
    log "validando pool OpenCode em $NH_FREE_ROUTER_URL"
    NVIDIA_BASE_URL_ORIG="$NVIDIA_BASE_URL"
    NH_API_KEY_ORIG="$NH_API_KEY"
    NVIDIA_BASE_URL="${NH_FREE_ROUTER_URL%/}/v1"
    NH_API_KEY="$NH_FREE_ROUTER_KEY"
    export NVIDIA_BASE_URL NH_API_KEY
    while IFS= read -r name && IFS= read -r smoke; do
      [ -n "$name" ] || continue
      if NH_SMOKE_STRICT=0 NH_SMOKE_REQUIRE_CONTENT=1 nh_smoke_chat "$smoke"; then
        ACTIVE_OC+=("$name")
      else
        aviso "desativando $name (pool OpenCode sem conteúdo útil agora: $smoke)"
      fi
    done < <(python3 - "$MODELS_JSON" <<'PY'
import json, sys
for a in json.load(open(sys.argv[1])).get("opencode_aliases") or []:
    print(a["model_name"]); print(a["smoke_id"])
PY
)
    NVIDIA_BASE_URL="$NVIDIA_BASE_URL_ORIG"
    NH_API_KEY="$NH_API_KEY_ORIG"
    export NVIDIA_BASE_URL NH_API_KEY
  fi
else
  aviso "pulando smoke (--no-test); ativando candidatos sem prova atual"
  mapfile -t ACTIVE_NIM < <(python3 -c 'import json,sys; print("\n".join(a["model_name"] for a in json.load(open(sys.argv[1])).get("nvidia_aliases") or []))' "$MODELS_JSON")
  if [ "$FREE_ON" = 1 ]; then
    mapfile -t ACTIVE_OC < <(python3 -c 'import json,sys; print("\n".join(a["model_name"] for a in json.load(open(sys.argv[1])).get("opencode_aliases") or []))' "$MODELS_JSON")
  fi
fi
ok "nvidia atalhos: $([ ${#ACTIVE_NIM[@]} -gt 0 ] && printf '%s' "${ACTIVE_NIM[*]}" || printf '(nenhum)')"
ok "opencode: $([ ${#ACTIVE_OC[@]} -gt 0 ] && printf '%s' "${ACTIVE_OC[*]}" || printf '(nenhum)')"

umask 077
if [ -n "$OLD_API_KEY" ]; then KEY_MSG="chave instalada preservada"
elif [ -n "$API_KEY_IN" ]; then KEY_MSG="chave via --api-key/\$NVIDIA_NIM_API_KEY"
else KEY_MSG="chave digitada"; fi
{
  cat <<EOF
$MARKER
export NVIDIA_NIM_API_KEY="$API_KEY"

# Master key do proxy LiteLLM do Claude Code (exigido pela versao 1.104+)
export LITELLM_MASTER_KEY="$MASTER_KEY"

# Modelo principal do Claude Code (id da NVIDIA, com prefixo do provider).
# Lista: GET https://integrate.api.nvidia.com/v1/models
export NV_MODEL="\${NV_MODEL:-$NV_MODEL_DEFAULT}"

# Modelo pequeno/rapido (tarefas de fundo do Claude Code).
export NV_SMALL_MODEL="\${NV_SMALL_MODEL:-$NV_SMALL_DEFAULT}"

# Pool OpenCode (LiteLLM :4000). Vazio se o free-router não estiver no ar.
export NH_FREE_ROUTER_URL="${NH_FREE_ROUTER_URL}"
EOF
  if [ -n "${NH_FREE_ROUTER_KEY:-}" ]; then
    printf 'export NH_FREE_ROUTER_KEY="%s"\n' "$NH_FREE_ROUTER_KEY"
  fi
} > "$ENVF"
chmod 600 "$ENVF"
ok "env em $ENVF ($KEY_MSG $(mask_key "$API_KEY"); $([ -n "$OLD_MASTER" ] && echo 'master key preservada' || echo 'master key nova'))"

# ------------------------------------------------------------------- config.yaml
if [ -f "$CONF" ] && ! head -1 "$CONF" | grep -q "install-nvidia-claude-code"; then
  aviso "$CONF não é do instalador; mantendo (remova para regenerar)."
else
  CONF="$CONF" MODELS_JSON="$MODELS_JSON" \
  ACTIVE_NIM="${ACTIVE_NIM[*]-}" ACTIVE_OC="${ACTIVE_OC[*]-}" \
  NH_FREE_ROUTER_URL="$NH_FREE_ROUTER_URL" \
  "$VENV_DIR/bin/python" <<'PY'
import json, os, yaml

spec = json.load(open(os.environ["MODELS_JSON"]))
active_nim = set(os.environ.get("ACTIVE_NIM", "").split())
active_oc = set(os.environ.get("ACTIVE_OC", "").split())
free_url = os.environ.get("NH_FREE_ROUTER_URL", "http://127.0.0.1:4000").rstrip("/")

model_list = [{
    "model_name": "nvidia-model",
    "litellm_params": {
        "model": "os.environ/NV_MODEL",
        "api_key": "os.environ/NVIDIA_NIM_API_KEY",
        "temperature": 1.0,
        "top_p": 0.95,
    },
}]
for a in spec.get("nvidia_aliases") or []:
    if a["model_name"] not in active_nim:
        continue
    params = {
        "model": a["litellm_model"],
        "api_key": "os.environ/NVIDIA_NIM_API_KEY",
    }
    if a.get("temperature") is not None:
        params["temperature"] = a["temperature"]
    if a.get("top_p") is not None:
        params["top_p"] = a["top_p"]
    model_list.append({"model_name": a["model_name"], "litellm_params": params})

model_list.append({
    "model_name": "nvidia-small",
    "litellm_params": {
        "model": "os.environ/NV_SMALL_MODEL",
        "api_key": "os.environ/NVIDIA_NIM_API_KEY",
    },
})
for a in spec.get("opencode_aliases") or []:
    if a["model_name"] not in active_oc:
        continue
    model_list.append({
        "model_name": a["model_name"],
        "litellm_params": {
            "model": "openai/" + a["smoke_id"],
            "api_base": free_url + "/v1",
            "api_key": "os.environ/NH_FREE_ROUTER_KEY",
        },
    })

doc = {"model_list": model_list, "litellm_settings": {"drop_params": True, "num_retries": 2}}
header = (
    "# gerado por install-nvidia-claude-code.sh\n"
    "# NVIDIA: NV_MODEL + atalhos com smoke 200. OpenCode: LiteLLM :4000 se no ar.\n"
    "# Nemotron 3 Super (120b-a12b) retirou em 2026-10-20 (HTTP 404 Function not found).\n"
)
open(os.environ["CONF"], "w").write(header + yaml.safe_dump(doc, sort_keys=False, allow_unicode=True))
print("modelos:", ", ".join(m["model_name"] for m in model_list))
PY
  ok "config em $CONF"
fi

# ----------------------------------------------------------------------- wrapper
umask 022
cat > "$WRAPPER" <<'WRAP'
#!/usr/bin/env bash
# Sobe o proxy LiteLLM (NVIDIA NIM), roda o Claude Code apontando pra ele e
# encerra o proxy ao sair.
set -euo pipefail

CONFIG_DIR="@HOME@/.config/claude-nvidia"
VENV_DIR="@HOME@/.claude-nvidia/venv"
MODEL="nvidia-model"
SMALL_MODEL="nvidia-small"

# shellcheck disable=SC1091
source "$CONFIG_DIR/env"

[ -n "${LITELLM_MASTER_KEY:-}" ] || { echo "LITELLM_MASTER_KEY ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NVIDIA_NIM_API_KEY:-}" ] || { echo "NVIDIA_NIM_API_KEY ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NV_MODEL:-}" ] || { echo "NV_MODEL ausente em $CONFIG_DIR/env" >&2; exit 1; }
[ -n "${NV_SMALL_MODEL:-}" ] || { echo "NV_SMALL_MODEL ausente em $CONFIG_DIR/env" >&2; exit 1; }

echo "Modelo principal: $MODEL -> ${NV_MODEL#nvidia_nim/} | pequeno: ${NV_SMALL_MODEL#nvidia_nim/}"

# Sem isto o modo interativo fala com api.anthropic.com (ECONNREFUSED se
# essa rota estiver bloqueada) e ignora o proxy LiteLLM.
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-1}"
export CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS="${CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS:-1}"
unset ANTHROPIC_API_KEY || true

proxy_pid=""

# O LiteLLM fica preso em "Waiting for background tasks to complete"; então
# TERM e, se ainda vivo em 5s, KILL — senão vira processo zumbi.
encerra_proxy() {
  [ -n "$proxy_pid" ] || return 0
  kill "$proxy_pid" 2>/dev/null || return 0
  for _ in 1 2 3 4 5; do
    kill -0 "$proxy_pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "$proxy_pid" 2>/dev/null || true
}
trap encerra_proxy EXIT

# Algo está LISTEN na porta? (TCP: pega até proxy PARADO/travado, que não
# responde HTTP e faria o wrapper achar a porta "livre" e falhar no bind)
porta_tem_listener() {
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
  else
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$1/" || true)"
    [ "$code" != "000" ]
  fi
}

# Responde HTTP no /health dentro de $2 segundos? (padrão 2)
http_ok() {
  local code t="${2:-2}"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$t" \
    "http://127.0.0.1:$1/health/liveliness" || true)"
  [ "$code" = "200" ]
}

# pid que está escutando a porta (vazio se não der pra saber)
pid_na_porta() {
  ss -H -ltnp "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -n1 | cut -d= -f2
}

# É UM proxy claude-nvidia (o nosso venv + config), travado ou não?
eh_nosso_proxy() {
  [ -n "${1:-}" ] || return 1
  grep -qF -- "$VENV_DIR/bin/litellm" "/proc/$1/cmdline" 2>/dev/null || return 1
  grep -qF -- "$CONFIG_DIR/config.yaml" "/proc/$1/cmdline" 2>/dev/null
}

# É um proxy claude-nvidia JÁ com a config atual? Exige todos os model_name do
# config.yaml (atualizados no proxy rodando) + os upstreams atuais do env.
proxy_compativel() {
  local info n
  info="$(curl -fs --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    "http://127.0.0.1:$1/v1/model/info" 2>/dev/null)" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s' "$info" | grep -q "\"model_name\":\"$n\"" || return 1
  done < <(grep -E '^[[:space:]]*-[[:space:]]*model_name:' "$CONFIG_DIR/config.yaml" | sed -E 's/.*model_name:[[:space:]]*//')
  # upstream do principal e do pequeno precisam bater com o env ATUAL
  printf '%s' "$info" | NV_MODEL="$NV_MODEL" NV_SMALL_MODEL="$NV_SMALL_MODEL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
data = d.get("data") if isinstance(d, dict) else d
up = {e.get("model_name"): (e.get("litellm_params") or {}).get("model") for e in data}
ok = up.get("nvidia-model") == os.environ["NV_MODEL"] and up.get("nvidia-small") == os.environ["NV_SMALL_MODEL"]
sys.exit(0 if ok else 1)'
}

# Porta: livre -> usar; proxy nosso com a mesma config -> reusar; proxy nosso
# TRAVADO (escuta mas não responde: Ctrl+Z, incidente) -> reinicia; ocupada por
# outro serviço -> próxima porta. Assim a sessão antiga nunca derruba a nova.
if [ -n "${CLAUDE_NVIDIA_PORT:-}" ]; then
  candidatas=("$CLAUDE_NVIDIA_PORT")
else
  candidatas=(4310 4311 4312 4313)
fi

PORT=""
reusando=0
# Serviço persistente: reusa :4310 e não mata ao sair (senão a extensão
# Cursor/VS Code fica com ECONNREFUSED na ANTHROPIC_BASE_URL morta).
if command -v systemctl >/dev/null 2>&1 \
  && systemctl --user is-active nvidia-harness-claude-proxy.service >/dev/null 2>&1 \
  && http_ok 4310 5; then
  PORT=4310
  reusando=1
fi
for p in "${candidatas[@]}"; do
  [ -z "$PORT" ] || break
  if ! porta_tem_listener "$p"; then PORT="$p"; break; fi
  if proxy_compativel "$p"; then PORT="$p"; reusando=1; break; fi

  pid="$(pid_na_porta "$p")"
  if eh_nosso_proxy "$pid" && ! http_ok "$p" 5; then
    echo "Proxy claude-nvidia TRAVADO na porta $p (pid $pid não responde) — reiniciando..." >&2
    kill -9 "$pid" 2>/dev/null || true   # SIGKILL: nem sinal comum age sobre processo parado
    sleep 1
    if ! porta_tem_listener "$p"; then PORT="$p"; break; fi
    echo "  a porta $p não liberou; testando a próxima..." >&2
    continue
  fi
  echo "Porta $p ocupada por outro serviço (pid ${pid:-desconhecido}); testando a próxima..." >&2
done

if [ -z "$PORT" ]; then
  echo "Nenhuma porta utilizável em: ${candidatas[*]}" >&2
  echo "Feche a outra sessão do claude-nvidia ou rode com CLAUDE_NVIDIA_PORT=<porta>." >&2
  exit 1
fi

LOG="$CONFIG_DIR/litellm-$PORT.log"

if [ "$reusando" = 1 ]; then
  echo "Reusando proxy LiteLLM já rodando na porta $PORT (mesma config)."
else
  : >"$LOG"
  "$VENV_DIR/bin/litellm" --config "$CONFIG_DIR/config.yaml" --port "$PORT" >>"$LOG" 2>&1 &
  proxy_pid=$!

  echo "Iniciando proxy LiteLLM (porta $PORT)..."
  espera=0
  until curl -fs --max-time 2 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1; do
    espera=$((espera + 1))
    if [ "$espera" -gt 60 ]; then
      echo "O proxy não ficou pronto em 60s. Log: $LOG" >&2
      tail -n 20 "$LOG" >&2
      exit 1
    fi
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
      echo "O proxy caiu. Veja o log: $LOG" >&2
      tail -n 20 "$LOG" >&2
      exit 1
    fi
    if [ $((espera % 5)) -eq 0 ]; then
      echo "  aguardando o proxy subir... ${espera}s" >&2
    fi
    sleep 1
  done
  echo "  proxy pronto em ${espera}s"

  if ! proxy_compativel "$PORT"; then
    echo "Proxy subiu mas não registrou $NV_MODEL. Log: $LOG" >&2
    tail -n 20 "$LOG" >&2
    exit 1
  fi
fi

# Smoke test com a NVIDIA: erro de configuração (chave/modelo) aborta;
# lentidão/instabilidade do endpoint hosted só gera aviso (o Claude Code retenta).
if [ "${CLAUDE_NVIDIA_SKIP_SMOKE:-0}" != "1" ]; then
  echo "Testando o endpoint da NVIDIA (até 45s, pode ser lento)..." >&2
  smoke_body="$(mktemp)"
  smoke_code="$(curl -sS --max-time 45 -o "$smoke_body" -w '%{http_code}' -X POST \
    "http://127.0.0.1:$PORT/v1/messages" \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"responda: ok\"}]}" 2>/dev/null)" || true
  case "$smoke_code" in
    200) ;;
    400|401|403|404)
      echo "Erro de configuração ao falar com a NVIDIA (HTTP $smoke_code):" >&2
      head -c 800 "$smoke_body" >&2; echo >&2
      echo "Log: $LOG" >&2
      rm -f "$smoke_body"
      exit 1
      ;;
    *)
      echo "Aviso: a NVIDIA não respondeu em 45s (HTTP ${smoke_code:-000})." >&2
      echo "O endpoint hosted está lento/instável agora; o Claude Code vai retentar." >&2
      ;;
  esac
  rm -f "$smoke_body"
fi

export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$SMALL_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SMALL_MODEL"
# Janela de contexto assumida pelo Claude Code (o modelo não está no catálogo dele).
export CLAUDE_CODE_MAX_CONTEXT_TOKENS="${CLAUDE_NVIDIA_CONTEXT_TOKENS:-200000}"

claude "$@"
WRAP
sed -i "s|@HOME@|$PREFIX|g" "$WRAPPER"
chmod 755 "$WRAPPER"
ok "wrapper em $WRAPPER"

# ----------------------------------------------------------------- settings.json
# Só mexe em modelPicker.options das linhas nvidia-/opencode-;
# hooks e o resto do arquivo ficam intactos. Atalhos sem smoke saem do picker.
SETTINGS_FILE="$SETTINGS" MODELS_JSON="$MODELS_JSON" \
ACTIVE_NIM="${ACTIVE_NIM[*]-}" ACTIVE_OC="${ACTIVE_OC[*]-}" \
MASTER_KEY="$MASTER_KEY" CLAUDE_PROXY_PORT="${NH_CLAUDE_PROXY_PORT:-4310}" \
python3 <<'PY'
import json, os

spec = json.load(open(os.environ["MODELS_JSON"]))
active_nim = set(os.environ.get("ACTIVE_NIM", "").split())
active_oc = set(os.environ.get("ACTIVE_OC", "").split())
rows = [
    {
        "model": "nvidia-model",
        "label": "NVIDIA principal (NV_MODEL)",
        "description": "Modelo padrão do claude-nvidia (Nemotron 3.5 Super VL 120B)",
        "behavesAs": "claude-sonnet-4-6",
    }
]
for a in spec.get("nvidia_aliases") or []:
    if a["model_name"] not in active_nim:
        continue
    rows.append({
        "model": a["model_name"],
        "label": a["label"],
        "description": a["description"],
        "behavesAs": a.get("behavesAs") or "claude-sonnet-4-6",
    })
rows.append({
    "model": "nvidia-small",
    "label": "NVIDIA GPT-OSS 20B",
    "description": "openai/gpt-oss-20b — tarefas de fundo",
    "behavesAs": "claude-haiku-4-5",
})
for a in spec.get("opencode_aliases") or []:
    if a["model_name"] not in active_oc:
        continue
    rows.append({
        "model": a["model_name"],
        "label": a["label"],
        "description": a["description"],
        "behavesAs": a.get("behavesAs") or "claude-sonnet-4-6",
    })

path = os.environ["SETTINGS_FILE"]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except json.JSONDecodeError:
        raise SystemExit("settings.json invalido; abortando")
opts = data.setdefault("modelPicker", {}).setdefault("options", [])
ours = {r["model"] for r in rows}
opts = [
    o for o in opts
    if not str(o.get("model") or "").startswith(("nvidia-", "opencode-"))
    or o.get("model") in ours
]
idx = {o.get("model"): i for i, o in enumerate(opts)}
for r in rows:
    if r["model"] in idx:
        opts[idx[r["model"]]] = r
    else:
        opts.append(r)
data["modelPicker"]["options"] = opts
data["model"] = "nvidia-model"
# Extensão Cursor/VS Code não passa pelo wrapper: sem isto aponta para
# api.anthropic.com ou para :4310 morto (ECONNREFUSED).
port = os.environ.get("CLAUDE_PROXY_PORT") or "4310"
master = os.environ.get("MASTER_KEY") or ""
env = data.get("env")
if not isinstance(env, dict):
    env = {}
env["ANTHROPIC_BASE_URL"] = "http://127.0.0.1:%s" % port
if master:
    env["ANTHROPIC_AUTH_TOKEN"] = master
env["ANTHROPIC_MODEL"] = "nvidia-model"
env["ANTHROPIC_SMALL_FAST_MODEL"] = "nvidia-small"
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = "nvidia-model"
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = "nvidia-model"
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = "nvidia-small"
env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = os.environ.get("CLAUDE_NVIDIA_CONTEXT_TOKENS") or "200000"
env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
env["CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS"] = "1"
env.pop("ANTHROPIC_API_KEY", None)
data["env"] = env
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(data, open(path, "w"), indent=2, ensure_ascii=False)
open(path, "a").write("\n")
print(len(opts))
PY
ok "modelPicker em $SETTINGS ($(SETTINGS_FILE="$SETTINGS" python3 -c 'import json,os;print(len(json.load(open(os.environ["SETTINGS_FILE"]))["modelPicker"]["options"]))') opções)"

NH_CLAUDE_CONFIG_DIR="$CONFIG_DIR"
NH_CLAUDE_VENV_DIR="$VENV_DIR"
export NH_CLAUDE_CONFIG_DIR NH_CLAUDE_VENV_DIR
# Recarrega NV_MODEL/LITELLM_MASTER_KEY gravados no env há pouco.
# shellcheck disable=SC1090
set +e; source "$ENVF" >/dev/null 2>&1; set -e
nh_ensure_claude_proxy || aviso "proxy persistente não subiu; use claude-nvidia nesta sessão"

# ------------------------------------------------------------------------ PATH
case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR já está no PATH" ;;
  *)
    grep -q "$BIN_DIR" "$PREFIX/.profile" 2>/dev/null \
      || printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$PREFIX/.profile"
    aviso "adicione ao PATH desta sessão: export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

# --------------------------------------------------------------------- validação
log "validando"
bash -n "$WRAPPER" || erro "sintaxe do wrapper inválida"
command -v shellcheck >/dev/null 2>&1 && shellcheck -S warning "$WRAPPER" || true
python3 -c "import json,os;json.load(open('$SETTINGS'))" || erro "settings.json inválido"
"$VENV_DIR/bin/python" -c "
import yaml,sys
d=yaml.safe_load(open('$CONF'))
assert d.get('model_list'), 'model_list vazio'
print('   modelos:', ', '.join(m['model_name'] for m in d['model_list']))
" || erro "config.yaml inválido"

if [ "$DO_TEST" = 1 ]; then
  if command -v claude >/dev/null 2>&1; then
    log "teste: claude-nvidia --version (sobe o proxy e limpa)"
    out="$(CLAUDE_NVIDIA_SKIP_SMOKE=1 "$WRAPPER" --version 2>&1 | tail -n 4)" || erro "teste falhou: $out"
    printf '%s\n' "$out" | sed 's/^/   /'
    ok "wrapper + proxy OK"
  else
    log "teste: subindo o proxy direto"
    PORT=4399
    "$VENV_DIR/bin/litellm" --config "$CONF" --port $PORT >"$CONFIG_DIR/litellm-test.log" 2>&1 &
    TP=$!
    for _ in $(seq 1 45); do curl -fs --max-time 2 "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break; sleep 1; done
    curl -fs --max-time 5 -H "Authorization: Bearer $(set +e; source "$ENVF" >/dev/null 2>&1; printf %s "$LITELLM_MASTER_KEY")" \
      "http://127.0.0.1:$PORT/v1/models" | grep -q nvidia-model || { kill $TP; erro "proxy não registrou os modelos (ver $CONFIG_DIR/litellm-test.log)"; }
    kill $TP 2>/dev/null; wait $TP 2>/dev/null || true
    ok "proxy sobe e registra os modelos"
  fi
fi

if [ "$DO_E2E" = 1 ]; then
  log "teste ponta a ponta (claude -p)"
  "$WRAPPER" -p "responda apenas: ok" | tail -n 2
fi

# Espelha a chave no env compartilhado do nvidia-harness.
# Se os testes passaram (ou foram pulados com chave já instalada), marca como validada.
if [ "$DO_TEST" = 1 ] || [ -n "$OLD_API_KEY" ]; then
  NH_KEY_VALIDATED=1
fi
nh_save_shared_env

echo
ok "instalado. Use: claude-nvidia  (ou abra o Claude Code na IDE — proxy em :${NH_CLAUDE_PROXY_PORT:-4310})"
echo "  modelo principal : $(set +e; source "$ENVF" >/dev/null 2>&1; echo "${NV_MODEL#nvidia_nim/}")  (troque NV_MODEL em $ENVF)"
echo "  NVIDIA /model    : nvidia-model nvidia-small ${ACTIVE_NIM[*]-}"
if [ ${#ACTIVE_OC[@]} -gt 0 ]; then
  echo "  OpenCode /model  : ${ACTIVE_OC[*]}"
else
  echo "  OpenCode /model  : (nenhum — suba o LiteLLM :4000 e rode de novo ./install.sh claude)"
fi
echo "  proxy            : nvidia-harness-claude-proxy.service  (${NH_CLAUDE_PROXY_URL:-http://127.0.0.1:4310})"
echo "  por chamada      : NV_MODEL=nvidia_nim/z-ai/glm-5.3 claude-nvidia"
