# nvidia-harness

Instalador **unificado** para usar modelos [NVIDIA NIM](https://build.nvidia.com) nos harnesses de desenvolvimento com IA:

| Harness | O que o script faz |
|---|---|
| **Claude Code** | Proxy [LiteLLM](https://github.com/BerriAI/litellm) local + wrapper `claude-nvidia` |
| **Cursor** | Grava `cursor.openai.baseUrl` e valida a API (Model Names são manuais na UI) |
| **OpenCode** | Mescla `provider.nvidia` em `~/.config/opencode/opencode.json` |
| **VS Code** | Instala [nvidia-nim-provider](https://github.com/hidenobunagai/nvidia-nim-provider) e orienta o cadastro seguro da chave |

Um único ponto de entrada, módulos por harness, chave compartilhada em `~/.config/nvidia-harness/env` (permissão `600`). **Nunca** versionamos tokens.

## Pré-requisitos

- Linux, `bash`, `curl`, `python3`
- Conta e chave `nvapi-…` em <https://build.nvidia.com>
- Por harness:
  - Claude Code: [`@anthropic-ai/claude-code`](https://docs.anthropic.com/en/docs/claude-code) (`npm i -g @anthropic-ai/claude-code`)
  - Cursor: [Cursor](https://cursor.com/) instalado
  - OpenCode: [OpenCode](https://opencode.ai/) no `PATH`
  - VS Code: [VS Code](https://code.visualstudio.com/) + [GitHub Copilot](https://marketplace.visualstudio.com/items?itemName=GitHub.copilot) (hospedeiro do picker)

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

Depois: **Ctrl+Shift+J → Models** → cole a chave OpenAI (`nvapi-…`) → adicione os Model Names listados pelo script. A base URL já fica em `settings.json`.

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
lib/nvidia.sh           # chave compartilhada + /models + smoke
harnesses/claude.sh
harnesses/cursor.sh
harnesses/opencode.sh
harnesses/vscode.sh
config/models.default.txt
config/opencode-provider.json
docs/TROUBLESHOOTING.md
```

## Histórico / repositórios anteriores

| Antes | Situação |
|---|---|
| [`rodriguesfas/claude-nvidia`](https://github.com/rodriguesfas/claude-nvidia) | Mantido: o instalador antigo redireciona / espelha este repo |
| [Gist Cursor](https://gist.github.com/rodriguesfas/c45aeccb42cd0ceb5d900b11198d80cb) | Absorvido em `harnesses/cursor.sh` |
| OpenCode / VS Code | Não havia repo — cobertos aqui |

## Limitações

- Cursor: cadastro de Model Names continua manual (sem API estável da IDE).
- VS Code: a chave fica no SecretStorage da IDE, não no disk do harness.
- Claude Code: depende do proxy LiteLLM local (portas `4310–4313`).
- Créditos gratuitos da NVIDIA expiram; rate limit da conta free é baixo.

## Licença

MIT — veja `LICENSE`.
