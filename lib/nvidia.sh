#!/usr/bin/env bash
# Resolução da chave NVIDIA e validação da API NIM (OpenAI-compatible).
# shellcheck shell=bash
# Requer: common.sh já carregado.

NVIDIA_BASE_URL="${NVIDIA_BASE_URL:-https://integrate.api.nvidia.com/v1}"

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
  body="$(mktemp)"
  code="$(curl -sS --max-time 45 -o "$body" -w '%{http_code}' \
    "$NVIDIA_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $NH_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"responda: ok\"}],\"max_tokens\":8}" \
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
tools = msg.get("tool_calls") or []
raise SystemExit(0 if content or tools else 1)
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
  for c in curl python3 ss git; do
    if has_cmd "$c"; then printf '  dep %-8s ok (%s)\n' "$c" "$(command -v "$c")"
    else printf '  dep %-8s AUSENTE\n' "$c"; fi
  done
}
