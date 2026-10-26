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

## Claude: `Connection refused` (ECONNREFUSED) · attempt N/10

O Claude Code está a falar com `ANTHROPIC_BASE_URL=http://127.0.0.1:4310` e **nada escuta** nessa porta. Não é firewall: o wrapper antigo subia o LiteLLM, lançava o `claude` e **matava o proxy ao sair**. A extensão no Cursor/VS Code (e um `claude` aberto depois) ficava a retentar uma porta morta.

- `./install.sh claude` instala `nvidia-harness-claude-proxy.service`, grava `env` em `~/.claude/settings.json` e só deixa no `/model` atalhos com smoke 200.
- Diagnóstico: `./install.sh claude --diagnose` (linhas `proxy` / `unit` / `base URL`).
- `systemctl --user status nvidia-harness-claude-proxy` e `curl -sS --max-time 2 http://127.0.0.1:4310/health/liveliness`.
- Abra uma sessão **nova** do Claude Code depois de reinstalar (a sessão antiga guarda o `ANTHROPIC_BASE_URL` morto).

O modo interativo também tenta `api.anthropic.com` no arranque. O harness grava `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` para esse tráfego não furar o proxy.

## Claude: fica em “Iniciando proxy…”

- Atualize/reinstale com `./install.sh claude`.
- Veja `~/.config/claude-nvidia/litellm-*.log`.
- Processo travado (Ctrl+Z): `ps -eo pid,stat,args | grep litellm` e `kill -9 <pid>`.
- Se o systemd estiver activo, `systemctl --user restart nvidia-harness-claude-proxy`.

## Cursor: Verify falha / Agent 400 Pydantic

O Agent do Cursor manda `content` como lista; a NIM rejeita. O harness instala o shim em `http://127.0.0.1:12436/v1` (`./install.sh cursor --yes`). Sem o proxy, Verify/Agent quebram mesmo com a chave certa.

- `cursor.openai.baseUrl` e `openAIBaseUrl` no `state.vscdb` = `http://127.0.0.1:12436/v1`.
- Chave OpenAI = `nvapi-…` (o proxy encaminha à NIM; nos ids `coder`/`fast`/… troca pela chave do LiteLLM).
- `systemctl --user status nvidia-harness-cursor-proxy` (ou `./install.sh cursor --diagnose`).
- `curl -sS http://127.0.0.1:12436/health` tem de devolver `{"ok":true,…}` sem esperar o catálogo NVIDIA.
- Regressão offline: `./install.sh --self-test` (sobe o shim + upstreams mock; não usa a chave NVIDIA).
- No picker: `nvidia/…` = NIM, `opencode/…` = pool OpenCode, sem prefixo = nativo do Cursor. OpenCode só aparece depois de fechar a IDE e `./install.sh cursor --yes` com o LiteLLM `:4000` no ar.

## Cursor: proxy some após reboot / desligar

O shim tem de ser a unidade **nova** `nvidia-harness-cursor-proxy.service`, não a legado `nvidia-cursor-proxy.service` (binário em `local-ai/`).

- `systemctl --user is-enabled nvidia-harness-cursor-proxy` → `enabled`
- `loginctl show-user "$USER" -p Linger` → `Linger=yes` (sem linger o systemd --user só sobe no login)
- `./install.sh cursor --yes` activa linger, desliga a unidade legado e faz `Restart=always`
- Diagnose: linha `unit` / `enabled` / `linger` em `./install.sh cursor --diagnose`

## Cursor: configuração some / modelos NVIDIA não respondem

- **Feche o Cursor** e rode `./install.sh cursor --yes`. Aberto, a IDE reverte o `state.vscdb` ao sair. O timer `nvidia-harness-cursor-byok` grava Base URL + chave + modelos validados quando a IDE não está a correr, para a próxima abertura já ir ao proxy (`http://127.0.0.1:12436/v1`).
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

## DeepSeek Harness: picker cheio de modelos que 404 / 504

O catálogo pi-ai do [dsh](https://github.com/deepseek-ai/deepseek-harness) anuncia ids hosted sem função nesta conta (Gemma 3, Kimi K2.6, Llama 3.1 Nemotron 70B/253B, …) ou que timeoutam (~90 s: DeepSeek V4.1 Flash, GLM-5.3-Flash). `./install.sh deepseek` prova `chat/completions` e deixa só quem devolve texto/reasoning. Padrão: `nvidia/nemotron-3.5-super-vl-120b-a12b`.

- Diagnóstico: `./install.sh deepseek --diagnose` (linhas `patch` / `default` / `picker` / `cred NV`).
- A chave vive em `~/.dsh/.credentials.yaml` (`NVIDIA_API_KEY`), não no `cordis.patch.yml`. O store do dsh ganha do `NVIDIA_API_KEY` de ambiente.
- Sessão antiga com `moonshotai/kimi-k3` (410 desde 2026-10-15) não muda sozinha — abra uma sessão nova.
- HMR do dsh neste host costuma falhar com `EMFILE`; depois de gravar, reabra a janela (dock / `deepseek-harness`).

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
