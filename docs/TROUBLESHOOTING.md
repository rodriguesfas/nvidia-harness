# Solução de problemas

## `FORWARD_ARGS[@]: unbound variable` no menu

O menu (qualquer opção **sem** flags) expandia `"${FORWARD_ARGS[@]}"` vazio com `set -u`. No bash < 4.4 isso aborta (`install.sh: FORWARD_ARGS[@]: unbound variable`) **antes** de chamar o harness. O instalador agora encaminha o array com `nh_call_a` (`set +u` só na expansão) e o menu repete se a opção for inválida.

Prova: `./install.sh --self-test`. Atualize com `git pull` e rode o menu de novo.

Workaround em clone antigo (sem atualizar):

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh cursor --yes
```

## HTTP 401 / 403 na API NVIDIA

- Gere uma chave nova em <https://build.nvidia.com>.
- Atualize `~/.config/nvidia-harness/env` (ou rode de novo com `NVIDIA_NIM_API_KEY=…`).
- No Claude Code, a chave também vive em `~/.config/claude-nvidia/env`.

## Claude / NVIDIA: HTTP 404 `Function … Not found for account`

O catálogo `GET /v1/models` ainda lista ids cujo endpoint hosted já saiu. Em 2026-10-20 a NVIDIA retirou `nvidia/nemotron-3-super-120b-a12b`; o substituto é `nvidia/nemotron-3.5-super-vl-120b-a12b`. `./install.sh claude` (e o OpenCode) migram o padrão antigo e só registram atalhos com smoke 200.

## Claude: pool OpenCode não aparece em `/model`

Os ids `opencode-coder` / `opencode-fast` / … só entram se o LiteLLM do free-router (`http://127.0.0.1:4000`) estiver no ar **na hora** de `./install.sh claude`. Diagnóstico: `./install.sh claude --diagnose` (linha `free-rtr` e `opencode`). Suba o `:4000` e rode o harness de novo.

## Claude: fica em “Iniciando proxy…”

- Atualize/reinstale com `./install.sh claude`.
- Veja `~/.config/claude-nvidia/litellm-*.log`.
- Processo travado (Ctrl+Z): `ps -eo pid,stat,args | grep litellm` e `kill -9 <pid>`.

## Cursor: Verify falha / Agent 400 Pydantic

O Agent do Cursor manda `content` como lista; a NIM rejeita. O harness instala o shim em `http://127.0.0.1:12436/v1` (`./install.sh cursor --yes`). Sem o proxy, Verify/Agent quebram mesmo com a chave certa.

- `cursor.openai.baseUrl` e `openAIBaseUrl` no `state.vscdb` = `http://127.0.0.1:12436/v1`.
- Chave OpenAI = `nvapi-…` (o proxy encaminha à NIM; nos ids `coder`/`fast`/… troca pela chave do LiteLLM).
- `systemctl --user status nvidia-harness-cursor-proxy` (ou `./install.sh cursor --diagnose`).
- No picker: `nvidia/…` = NIM, `opencode/…` = pool OpenCode, sem prefixo = nativo do Cursor. OpenCode só aparece depois de fechar a IDE e `./install.sh cursor --yes` com o LiteLLM `:4000` no ar.

## Cursor: configuração some / modelos NVIDIA não respondem

- **Feche o Cursor** e rode `./install.sh cursor --yes`. Aberto, a IDE reverte o `state.vscdb` ao sair.
- O script instala o proxy, prova `chat/completions` e grava só quem respondeu 200 **com texto**. Pool OpenCode (`coder`, `fast`, …) só entra se o LiteLLM `:4000` estiver no ar.
- Estar em `GET /v1/models` **não** significa que o modelo responde (404 “Function not found for account”, timeout, vazio).
- Backup: `~/.config/nvidia-harness/backups/cursor-state-<timestamp>.json` (só a linha `applicationUser` — nunca copie o `state.vscdb` inteiro).

## OpenCode: provider não aparece

- Confira `~/.config/opencode/opencode.json` (`provider.nvidia`).
- Reinicie o OpenCode após gravar.
- Permissão do arquivo deve ser `600`.

## OpenCode: UI trava / `ProviderHeaderTimeoutError` 300000ms

O Desktop não crasha: o modelo da sessão não devolve header. `deepseek-ai/deepseek-v4.1-flash` hosted timeouta ~5 min (6 retries). `moonshotai/kimi-k3` é 410 desde 2026-10-15. `./install.sh opencode --set-default` aponta o default e os agentes `agent`/`debug`/`multitask` para `nvidia/nemotron-3.5-super-vl-120b-a12b` e remove o K3 da lista. Sessão antiga guarda o modelo morto — abra uma sessão nova.

Pool grátis do OpenCode (`flint-40b-free`, `beam-free`) também cai (`Endpoint is unavailable` / `permissions` não suportado). Não uses como fallback do DeepSeek.

## VS Code: modelos NIM não listam

- Extensão `hidenobunagai.nvidia-nim-provider` instalada?
- GitHub Copilot ativo?
- Command Palette → **NVIDIA NIM: Manage NVIDIA NIM API Key**.
- VS Code ≥ 1.104.

## Antigravity: Cascade ignora Base URL / chave NVIDIA

Esperado. **Status (2026-10-21): aguardando BYOK nativo liberado pela Google.** O agente nativo não tem BYOK OpenAI-compatible para usuário final — sem setting de modelo/Base URL/chave na IDE, inferência no backend da Google (`cloudcode-pa.googleapis.com`), e o `CustomModels` do language server é config enterprise/eval vinda do servidor, não cadastro local. Chaves inventadas em `settings.json` (`antigravity.openai-compatible.*`) não roteiam. Quando a Google liberar, o harness passa a gravar no painel nativo.

- Use o Cline (`saoudrizwan.claude-dev`) dentro do Antigravity: Provider **OpenAI Compatible**, Base URL `https://integrate.api.nvidia.com/v1`, chave `nvapi-…`, Model ID exato.
- `./install.sh antigravity` (com a IDE **fechada**) grava isso automaticamente; `./install.sh antigravity --diagnose` mostra `cline cfg : provider=…` quando está aplicado.
- `state.vscdb` editado com a IDE aberta é perdido: ela mantém o estado em memória e regrava ao sair.
- Modelo listado em `/models` pode retornar 404 (sem função na conta) ou 410 (end-of-life) — o script só escolhe modelo com smoke 200.
- `agy` só aceita endpoint Gemini (`GOOGLE_GEMINI_BASE_URL` + `GEMINI_API_KEY`); não use a URL NIM aí.

## Smoke test lento / timeout

O endpoint hosted da NVIDIA às vezes demora. **`GET /v1/models` não autentica de fato** — a chave só é comprovada em `chat/completions` (isso roda por padrão). Timeout no chat vira aviso; **401/403 abortam**. Pule a prova da chave com `--no-test` (não recomendado).

## Restaurar backup

Arquivos modificados geram `*.bak-nvidia-harness-<timestamp>` ao lado do original:

```bash
ls -lt ~/.config/opencode/opencode.json.bak-nvidia-harness-* 
cp ~/.config/opencode/opencode.json.bak-nvidia-harness-XXXXXXXX ~/.config/opencode/opencode.json
```

## Diagnóstico completo

```bash
./install.sh diagnose
```
