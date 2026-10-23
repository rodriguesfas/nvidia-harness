#!/usr/bin/env bash
# Resolução da chave NVIDIA e validação da API NIM (OpenAI-compatible).
# shellcheck shell=bash
# Requer: common.sh já carregado.

NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com/v1}"
NH_FREE_ROUTER_URL="${NH_FREE_ROUTER_URL:-http://127.0.0.1:4000}"

# Carrega chave já salva em ~/.config/nvidia-harness/env (se existir).
nh_load_shared_env() {
  if [ -f "$NH_ENVF" ]; then
    # shellcheck disable=SC1090
    set +e
    # shellcheck source=/dev/null
    source "$NH_ENVF" >/dev/null 2>&1
    set -e
  fi
}

# Resolve a chave sem ecoar o valor. Ordem (não sobrescreve env já exportada):
#   1) --api-key / NH_API_KEY_IN
#   2) $NVIDIA_NIM_API_KEY (já no ambiente do processo)
#   3) $NVIDIA_API_KEY
#   4) ~/.config/nvidia-harness/env
#   5) ~/.config/claude-nvidia/env
#   6) prompt interativo (se TTY)
nh_resolve_api_key() {
  local key="${NH_API_KEY_IN:-}"
  if [ -z "$key" ]; then key="${NVIDIA_NIM_API_KEY:-}"; fi
  if [ -z "$key" ]; then key="${NVIDIA_API_KEY:-}"; fi

  if [ -z "$key" ] && [ -f "$NH_ENVF" ]; then
    # shellcheck disable=SC1090
    key="$(set +e; # shellcheck source=/dev/null
      source "$NH_ENVF" >/dev/null 2>&1
      printf '%s' "${NVIDIA_NIM_API_KEY:-}")"
  fi

  if [ -z "$key" ] && [ -f "$HOME/.config/claude-nvidia/env" ]; then
    # shellcheck disable=SC1090
    key="$(set +e; # shellcheck source=/dev/null
      source "$HOME/.config/claude-nvidia/env" >/dev/null 2>&1
      printf '%s' "${NVIDIA_NIM_API_KEY:-}")"
  fi

  if [ -z "$key" ]; then
    if [ -t 0 ]; then
      printf 'Chave da NVIDIA (nvapi-...): '
      IFS= read -rs key || true
      echo
    fi
  fi

  if [ -z "$key" ]; then
    if [ "${NH_SOFT_KEY:-0}" = "1" ]; then
      NH_API_KEY=""
      return 1
    fi
    erro "chave NVIDIA ausente (use NVIDIA_NIM_API_KEY=… ou --api-key)"
  fi
  case "$key" in
    nvapi-*) ;;
    *) aviso "a chave não começa com 'nvapi-' — confira se é a chave certa" ;;
  esac
  NH_API_KEY="$key"
  export NVIDIA_NIM_API_KEY="$key"
  export NVIDIA_API_KEY="$key"
}

# Persiste a chave no env compartilhado (600). Idempotente: preserva se igual.
# NH_KEY_VALIDATED=1 deve ser setado após nh_validate_key bem-sucedido.
# Com --no-test (chave não validada), só grava se ainda não existir env.
nh_save_shared_env() {
  ensure_dir "$NH_CONFIG_DIR"
  umask 077
  local old=""
  if [ -f "$NH_ENVF" ]; then
    # shellcheck disable=SC1090
    old="$(set +e; # shellcheck source=/dev/null
      source "$NH_ENVF" >/dev/null 2>&1
      printf '%s' "${NVIDIA_NIM_API_KEY:-}")"
  fi
  if [ -n "$old" ] && [ "$old" = "$NH_API_KEY" ] && [ -f "$NH_ENVF" ]; then
    ok "chave compartilhada já gravada ($(mask_key "$NH_API_KEY"))"
    return 0
  fi
  if [ "${NH_KEY_VALIDATED:-0}" != "1" ]; then
    if [ -n "$old" ]; then
      aviso "chave não validada (--no-test); mantendo $NH_ENVF existente ($(mask_key "$old"))"
      return 0
    fi
    aviso "gravando chave ainda não validada em $NH_ENVF (não havia env prévio)"
  fi
  if [ -n "$old" ] && [ "$old" != "$NH_API_KEY" ]; then
    confirm "Substituir chave em $NH_ENVF ($(mask_key "$old") → $(mask_key "$NH_API_KEY"))?" \
      || { aviso "mantendo chave anterior"; NH_API_KEY="$old"; export NVIDIA_NIM_API_KEY="$old"; return 0; }
    backup_file "$NH_ENVF" >/dev/null
  fi
  cat > "$NH_ENVF" <<EOF
$NH_MARKER
# Não versionar nem colar este arquivo em issues/chats.
export NVIDIA_NIM_API_KEY="$NH_API_KEY"
export NVIDIA_API_KEY="\$NVIDIA_NIM_API_KEY"
export NVIDIA_BASE_URL="${NVIDIA_BASE_URL}"
EOF
  chmod 600 "$NH_ENVF"
  ok "env compartilhado em $NH_ENVF ($(mask_key "$NH_API_KEY"))"
}

# Lista modelos (ou falha). Não imprime a chave.
nh_list_models() {
  need_cmd curl
  need_cmd python3
  local body code
  body="$(mktemp)"
  code="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
    "$NVIDIA_BASE_URL/models" \
    -H "Authorization: Bearer $NH_API_KEY" || true)"
  case "$code" in
    200)
      python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("\n".join(m["id"] for m in d.get("data",[])))' "$body"
      rm -f "$body"
      ;;
    401|403)
      rm -f "$body"
      erro "API NVIDIA recusou a chave (HTTP $code). Gere outra em https://build.nvidia.com"
      ;;
    *)
      rm -f "$body"
      erro "falha ao listar modelos (HTTP ${code:-000}). Verifique rede/URL ($NVIDIA_BASE_URL)"
      ;;
  esac
}

# /v1/models da NVIDIA costuma responder sem autenticar — não use só isso para
# validar a chave. Este probe exige Bearer válido (chat/completions).
# NH_SMOKE_STRICT=1 (padrão) transforma 401/403 em erro fatal.
nh_smoke_chat() {
  local model="${1:-openai/gpt-oss-20b}"
  local strict="${NH_SMOKE_STRICT:-1}"
  local body code
  local max_tokens=8
  local timeout=45
  if [ "${NH_SMOKE_REQUIRE_CONTENT:-0}" = 1 ]; then
    # Modelos com thinking (Nemotron 3.5, GLM, …) gastam o orçamento em
    # reasoning_content; 8 tokens devolvem HTTP 200 vazio e um falso negativo.
    max_tokens=128
    timeout=90
  fi
  body="$(mktemp)"
  code="$(curl -sS --max-time "$timeout" -o "$body" -w '%{http_code}' \
    "$NVIDIA_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $NH_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"responda: ok\"}],\"max_tokens\":$max_tokens}" \
    || true)"
  case "$code" in
    200)
      if [ "${NH_SMOKE_REQUIRE_CONTENT:-0}" = 1 ]; then
        if ! python3 - "$body" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
if d.get("error"):
    raise SystemExit(1)
msg = ((d.get("choices") or [{}])[0].get("message") or {})
content = (msg.get("content") or "").strip()
reasoning = (msg.get("reasoning_content") or msg.get("reasoning") or "").strip()
tools = msg.get("tool_calls") or []
raise SystemExit(0 if content or reasoning or tools else 1)
PY
        then
          aviso "smoke chat: HTTP 200 sem conteúdo útil ($model)"
          rm -f "$body"
          return 1
        fi
      fi
      ok "smoke chat OK ($model)"
      rm -f "$body"
      return 0
      ;;
    401|403)
      aviso "chave rejeitada pela NVIDIA (HTTP $code)"
      head -c 400 "$body" >&2; echo >&2
      rm -f "$body"
      if [ "$strict" = "1" ]; then
        erro "API key inválida ou sem permissão — gere outra em https://build.nvidia.com"
      fi
      return 1
      ;;
    404)
      aviso "smoke chat: modelo não encontrado (HTTP 404) para $model"
      rm -f "$body"
      return 1
      ;;
    *)
      aviso "smoke chat sem resposta útil (HTTP ${code:-000}); endpoint pode estar lento"
      rm -f "$body"
      return 1
      ;;
  esac
}

# Validação mínima de chave via chat/completions (prova real de auth).
nh_validate_key() {
  local model="${NVIDIA_TEST_MODEL:-openai/gpt-oss-20b}"
  log "validando chave NVIDIA (chat/completions)"
  NH_SMOKE_STRICT=1 nh_smoke_chat "$model"
  NH_KEY_VALIDATED=1
  export NH_KEY_VALIDATED
}

nh_diagnose_common() {
  log "diagnóstico comum"
  printf '  base URL : %s\n' "$NVIDIA_BASE_URL"
  printf '  env file : %s (%s)\n' "$NH_ENVF" "$([ -f "$NH_ENVF" ] && echo presente || echo ausente)"
  if [ -n "${NH_API_KEY:-}" ]; then
    printf '  api key  : %s\n' "$(mask_key "$NH_API_KEY")"
  else
    printf '  api key  : (não resolvida)\n'
  fi
  printf '  free-rtr : %s (%s)\n' "$NH_FREE_ROUTER_URL" "$(nh_free_router_up && echo ativo || echo ausente)"
  for c in curl python3 ss git; do
    if has_cmd "$c"; then printf '  dep %-8s ok (%s)\n' "$c" "$(command -v "$c")"
    else printf '  dep %-8s AUSENTE\n' "$c"; fi
  done
}

# HTTP "está no ar?" — 2xx/4xx/5xx contam (serviço responde); 000 não.
nh_http_up() {
  local url="$1"
  local code
  code="$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "$url" || true)"
  case "$code" in
    200|401|404|405|500) return 0 ;;
    *) return 1 ;;
  esac
}

nh_free_router_up() {
  nh_http_up "${NH_FREE_ROUTER_URL%/}/v1/models" \
    || nh_http_up "${NH_FREE_ROUTER_URL%/}/models" \
    || nh_http_up "${NH_FREE_ROUTER_URL%/}/"
}

# Lê KEY= de um env file (aceita `export KEY=`). Não imprime o arquivo inteiro.
nh_read_env_key() {
  local file="$1" name="$2"
  [ -f "$file" ] || return 0
  python3 - "$file" "$name" <<'PY'
import sys
path, name = sys.argv[1], sys.argv[2]
prefix = name + "="
try:
    lines = open(path, encoding="utf-8", errors="replace")
except OSError:
    raise SystemExit(0)
for raw in lines:
    line = raw.strip()
    if line.startswith("export "):
        line = line[7:].strip()
    if line.startswith(prefix):
        print(line.split("=", 1)[1].strip().strip('"').strip("'"))
        break
PY
}

# Master key do LiteLLM :4000 (pool OpenCode). NÃO grava em LITELLM_MASTER_KEY —
# o proxy do Claude Code usa outra chave.
nh_detect_free_router_key() {
  local f key
  if [ -n "${NH_FREE_ROUTER_KEY:-}" ]; then
    return 0
  fi
  for f in \
    "${NH_FREE_ROUTER_ENV:-}" \
    "$NH_ENVF" \
    "$NH_CONFIG_DIR/proxy.env" \
    "$HOME/.config/opencode-free-router/.env" \
    "$HOME/.config/nvidia-harness/free-router/.env"
  do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    key="$(nh_read_env_key "$f" LITELLM_MASTER_KEY || true)"
    if [ -n "$key" ]; then
      NH_FREE_ROUTER_KEY="$key"
      NH_FREE_ROUTER_ENV="$f"
      export NH_FREE_ROUTER_KEY NH_FREE_ROUTER_ENV
      return 0
    fi
  done
  if has_cmd systemctl; then
    f="$(systemctl --user show -p EnvironmentFiles --value free-router.service 2>/dev/null | awk '{print $1}' | head -1 || true)"
    f="${f#-}"; f="${f%% *}"
    if [ -n "$f" ] && [ -f "$f" ]; then
      key="$(nh_read_env_key "$f" LITELLM_MASTER_KEY || true)"
      if [ -n "$key" ]; then
        NH_FREE_ROUTER_KEY="$key"
        NH_FREE_ROUTER_ENV="$f"
        export NH_FREE_ROUTER_KEY NH_FREE_ROUTER_ENV
        return 0
      fi
    fi
  fi
  return 1
}

nh_try_start_free_router() {
  nh_free_router_up && return 0
  has_cmd systemctl || return 1
  systemctl --user is-enabled free-router.service >/dev/null 2>&1 \
    || systemctl --user list-unit-files free-router.service >/dev/null 2>&1 \
    || return 1
  log "tentando subir free-router.service (pool OpenCode)"
  systemctl --user start free-router.service >/dev/null 2>&1 || return 1
  local _
  for _ in 1 2 3 4 5 6 7 8; do
    nh_free_router_up && return 0
    sleep 0.5
  done
  return 1
}
