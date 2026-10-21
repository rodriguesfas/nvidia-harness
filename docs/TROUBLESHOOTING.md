# Solução de problemas

## HTTP 401 / 403 na API NVIDIA

- Gere uma chave nova em <https://build.nvidia.com>.
- Atualize `~/.config/nvidia-harness/env` (ou rode de novo com `NVIDIA_NIM_API_KEY=…`).
- No Claude Code, a chave também vive em `~/.config/claude-nvidia/env`.

## Claude: fica em “Iniciando proxy…”

- Atualize/reinstale com `./install.sh claude`.
- Veja `~/.config/claude-nvidia/litellm-*.log`.
- Processo travado (Ctrl+Z): `ps -eo pid,stat,args | grep litellm` e `kill -9 <pid>`.

## Cursor: Verify falha

- Confirme `cursor.openai.baseUrl` = `https://integrate.api.nvidia.com/v1`.
- A chave deve ser a NVIDIA (`nvapi-…`) no campo OpenAI API Key.
- Desative modelos OpenAI/Anthropic que não usa durante o verify.
- Nomes de modelo precisam ser **exatos** (lista: `./install.sh cursor` ou `GET /v1/models`).

## Cursor: configuração some / modelos NVIDIA não respondem

- `./install.sh cursor` grava `useOpenAIKey=true`, a chave (SecretStorage) e os modelos no `state.vscdb`. **Com o Cursor aberto a gravação é recusada** — a IDE mantém o estado em memória e sobrescreve edições externas ao sair (confirmado na prática: edição com a IDE aberta é revertida).
- Só 4 modelos responderam nesta conta (smoke `chat/completions` 200, 2026-10-21) e são os únicos ativados: `nvidia/nemotron-3-ultra-550b-a55b`, `nvidia/nemotron-3.5-lightning-30b-a3b`, `openai/gpt-oss-20b`, `meta/llama-3.2-11b-vision-instruct`.
- Os demais ids testados falham: `404 Function … Not found for account` (ex.: `moonshotai/kimi-k2.6`, `nvidia/nemotron-3-super-120b-a12b`, `nvidia/nemotron-4-340b-instruct`, `nvidia/llama-3.1-nemotron-70b-instruct`, `deepseek-ai/deepseek-coder-6.7b-instruct`, `mistralai/*`, `google/gemma-3-*`), timeout >150 s (`deepseek-ai/deepseek-v4.1-flash`, `meta/llama-3.2-90b-vision-instruct`) ou nem constam no catálogo (`moonshotai/kimi-k3`). Estar em `GET /v1/models` **não** significa que o modelo responde.
- `./install.sh cursor --diagnose` mostra `nim cfg : aplicada` quando baseUrl + `useOpenAIKey` + modelos validados + secret estão no lugar.
- Backup da gravação fica em `~/.config/nvidia-harness/backups/cursor-state-<timestamp>.json` (só a linha `applicationUser` — o `state.vscdb` pode ter dezenas de GB; nunca copie o banco inteiro).

## OpenCode: provider não aparece

- Confira `~/.config/opencode/opencode.json` (`provider.nvidia`).
- Reinicie o OpenCode após gravar.
- Permissão do arquivo deve ser `600`.

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
