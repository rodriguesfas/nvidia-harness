# nvidia-harness

Instalador **unificado** para usar modelos [NVIDIA NIM](https://build.nvidia.com) nos harnesses de desenvolvimento com IA:

| Harness | O que o script faz |
|---|---|
| **Claude Code** | Proxy [LiteLLM](https://github.com/BerriAI/litellm) local + wrapper `claude-nvidia` |
| **Cursor** | Grava `cursor.openai.baseUrl`, `useOpenAIKey`, ativa **só** modelos com smoke 200 e grava a chave no SecretStorage (feche o Cursor antes) |
| **OpenCode** | Mescla `provider.nvidia` em `~/.config/opencode/opencode.json` |
| **VS Code** | Instala [nvidia-nim-provider](https://github.com/hidenobunagai/nvidia-nim-provider) e orienta o cadastro seguro da chave |
| **Antigravity** | Instala o [Cline](https://docs.cline.bot/) e **grava** OpenAI Compatible → NIM (provider/baseUrl/modelo no `state.vscdb` + chave no SecretStorage) |

Um único ponto de entrada, módulos por harness, chave compartilhada em `~/.config/nvidia-harness/env` (permissão `600`). **Nunca** versionamos tokens.

## Pré-requisitos

- Linux, `bash`, `curl`, `python3`
- Conta e chave `nvapi-…` em <https://build.nvidia.com>
- Por harness:
  - Claude Code: [`@anthropic-ai/claude-code`](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
  - Cursor: [Cursor](https://cursor.com/) instalado
  - OpenCode: [OpenCode](https://opencode.ai/) no `PATH`
  - VS Code: [VS Code](https://code.visualstudio.com/) + [GitHub Copilot](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot) (hospedeiro do picker)
  - Antigravity: [Antigravity](https://antigravity.google/) instalado (`antigravity` no `PATH`)

## Instalação rápida

```bash
git clone https://github.com/rodriguesfas/nvidia-harness.git
cd nvidia-harness
chmod +x install.sh harnesses/*.sh
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh
```

Menu interativo, ou direto:

```bash
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh claude
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh cursor
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh opencode
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh vscode
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh antigravity
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh all --yes
```

One-liner (baixa e clona em `/tmp`):

```bash
git clone --depth 1 https://github.com/rodriguesfas/nvidia-harness.git /tmp/nvidia-harness \
  && NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN /tmp/nvidia-harness/install.sh
```

Prefira a variável de ambiente a `--api-key` (esta aparece na lista de processos).

## Comandos recomendados por harness

### Claude Code

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh claude
claude-nvidia
```

Troca de modelo: edite `NV_MODEL` em `~/.config/claude-nvidia/env`, ou `NV_MODEL=nvidia_nim/z-ai/glm-5.3 claude-nvidia`, ou `/model` na sessão.

### Cursor

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh cursor
```

**Feche o Cursor antes de rodar** — a IDE mantém o estado em memória e sobrescreve o `state.vscdb` ao sair. O script grava a configuração completa: base URL em `settings.json`, `useOpenAIKey=true`, chave no SecretStorage da IDE e, em *Settings → Models*, ativa **somente** os modelos com smoke `chat/completions` 200 nesta conta (verificado em 2026-10-21): `nvidia/nemotron-3-ultra-550b-a55b`, `nvidia/nemotron-3.5-lightning-30b-a3b`, `openai/gpt-oss-20b` e `meta/llama-3.2-11b-vision-instruct`. Qualquer outro id é desativado de propósito (404/timeout — ver `docs/TROUBLESHOOTING.md`).

### OpenCode

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh opencode --set-default
opencode
```

### VS Code

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh vscode
```

Depois: Command Palette → **NVIDIA NIM: Manage NVIDIA NIM API Key**.

### Antigravity

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh antigravity
```

> **Status (2026-10-21): aguardando BYOK nativo liberado pela Google.** O Agent/Cascade nativo ainda não aceita modelo customizado para usuário final (sem setting de Base URL/chave; inferência no backend da Google). Quando isso for liberado, este harness migra para o painel nativo e o Cline vira legado. Até lá:

O agente Cascade nativo **não** aceita Base URL OpenAI-compatible. O script instala o [Cline](https://docs.cline.bot/), escolhe um modelo que **responde** nesta conta (smoke `chat/completions`; padrão `z-ai/glm-5.3`) e grava a configuração: provider **OpenAI Compatible**, Base URL `https://integrate.api.nvidia.com/v1`, modelo e chave (SecretStorage da IDE). **Feche o Antigravity antes de rodar** — a IDE sobrescreve o `state.vscdb` ao sair. O CLI `agy` só fala protocolo Gemini (`GOOGLE_GEMINI_BASE_URL`), não a API NIM.

## Diagnóstico

```bash
./install.sh diagnose
./install.sh cursor --diagnose
```

## Idempotência e segurança

- Reexecutar é seguro: backups `*.bak-nvidia-harness-<timestamp>` antes de sobrescrever.
- Confirmação interativa antes de substituir configs (pule com `--yes`).
- Chaves só em arquivos `600`; logs mascaram (`nvapi-…xxxx`).
- Não imprima `NVIDIA_NIM_API_KEY` em issues, PRs ou prints de tela.

## Layout

```text
install.sh              # entrada (menu / CLI)
lib/common.sh           # log, backup, confirm
lib/nvidia.sh           # chave compartilhada + /models + validação via chat
harnesses/claude.sh
harnesses/cursor.sh
harnesses/opencode.sh
harnesses/vscode.sh
harnesses/antigravity.sh
config/models.default.txt
config/opencode-provider.json
docs/TROUBLESHOOTING.md
```

## Histórico

| Antes | Situação |
|---|---|
| `rodriguesfas/claude-nvidia` | Removido — tudo vive aqui (`./install.sh claude`). O binário local `claude-nvidia` e `~/.config/claude-nvidia/` continuam sendo o runtime do harness Claude. |
| [Gist Cursor](https://gist.github.com/rodriguesfas/c45aeccb42cd0ceb5d900b11198d80cb) | Absorvido em `harnesses/cursor.sh` |
| OpenCode / VS Code | Não havia repo — cobertos aqui |
| Antigravity | Coberto via Cline (Cascade nativo sem BYOK OpenAI) |

## Limitações

- Cursor: sem API estável da IDE para Model Names — o harness grava direto no `state.vscdb` (com a IDE fechada) e faz backup só da linha alterada, nunca do banco inteiro (que pode ter dezenas de GB).
- VS Code: a chave fica no SecretStorage da IDE, não no disk do harness.
- Claude Code: depende do proxy LiteLLM local (portas `4310–4313`).
- Antigravity: Cascade e `agy` não usam a API OpenAI da NIM; o caminho é Cline (OpenAI Compatible).
- `GET /v1/models` da NVIDIA responde sem autenticar; a prova da chave é via `chat/completions` (pule só com `--no-test`).
- Créditos gratuitos da NVIDIA expiram; rate limit da conta free é baixo.

## Licença

MIT — veja `LICENSE`.
