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

Esperado. O agente nativo não tem BYOK OpenAI-compatible — chaves inventadas em `settings.json` (`antigravity.openai-compatible.*`) não roteiam.

- Use o Cline (`saoudrizwan.claude-dev`) dentro do Antigravity: Provider **OpenAI Compatible**, Base URL `https://integrate.api.nvidia.com/v1`, chave `nvapi-…`, Model ID exato.
- Reinstale/oriente com `./install.sh antigravity`.
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
