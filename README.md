# nvidia-harness

Instalador **unificado** para usar modelos [NVIDIA NIM](https://build.nvidia.com) nos harnesses de desenvolvimento com IA:

| Harness | O que o script faz |
|---|---|
| **Claude Code** | Proxy [LiteLLM](https://github.com/BerriAI/litellm) local + wrapper `claude-nvidia` (NIM + pool OpenCode se `:4000`) |
| **Cursor** | Instala o proxy local (`:12436`), grava Base URL + chave + **só** modelos com smoke 200 (NIM e, se o LiteLLM `:4000` estiver no ar, `coder`/`fast`/…). Feche o Cursor antes. |
| **OpenCode** | Mescla `provider.nvidia` em `~/.config/opencode/opencode.json` |
| **VS Code** | Instala [nvidia-nim-provider](https://github.com/hidenobunagai/nvidia-nim-provider) e orienta o cadastro seguro da chave |
| **Antigravity** | Instala o [Cline](https://docs.cline.bot/) e **grava** OpenAI Compatible → NIM (provider/baseUrl/modelo no `state.vscdb` + chave no SecretStorage) |
| **DeepSeek Harness** | Smoke NIM e grava o provider `nvidia` em `~/.dsh/profiles/web/cordis.patch.yml` (só ids 200) + chave em `~/.dsh/.credentials.yaml` |

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
  - DeepSeek Harness: [`dsh`](https://github.com/deepseek-ai/deepseek-harness) já executado uma vez (`~/.dsh/profiles/web/` existe)

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
NVIDIA_NIM_API_KEY=nvapi-SEU_TOKEN ./install.sh deepseek
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

Padrão hosted: `nvidia/nemotron-3.5-super-vl-120b-a12b` (`nvidia/nemotron-3-super-120b-a12b` retirou em 2026-10-20 — HTTP 404 *Function not found*). O instalador faz smoke em cada atalho NIM e só registra quem responde 200 com texto. Atalhos que falham o smoke (pago, 404, timeout, ou pool OpenCode com `:4000` morto) saem do `/model`.

O proxy LiteLLM fica em `nvidia-harness-claude-proxy.service` (`http://127.0.0.1:4310`) e o `env` em `~/.claude/settings.json` aponta o Claude Code da IDE para ele. Sem o serviço, a extensão Cursor/VS Code vê `ECONNREFUSED` — o wrapper antigo matava o LiteLLM ao sair.

Troca de modelo: edite `NV_MODEL` em `~/.config/claude-nvidia/env`, ou `NV_MODEL=nvidia_nim/z-ai/glm-5.3 claude-nvidia`, ou `/model` na sessão (`nvidia-model`, `nvidia-nemotron`, `nvidia-glm`, `nvidia-small`, …).

Pool grátis do OpenCode (`opencode-coder`, `opencode-fast`, …) entra no mesmo `/model` se o LiteLLM em `:4000` estiver no ar na hora do `./install.sh claude`. Sem o free-router, o Claude Code fica só com a NIM; suba o `:4000` e rode o harness de novo.

### Cursor

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh cursor --yes
```

**Feche o Cursor, rode o comando, abra de novo.** Nada para colar na UI: o script (1) instala o shim em `~/.config/nvidia-harness/bin/nvidia-cursor-proxy.py` e sobe `nvidia-harness-cursor-proxy.service` (`http://127.0.0.1:12436/v1`) com `Restart=always` + linger (sobe no boot, mesmo após desligar), (2) prova `chat/completions` e (3) grava Base URL, `useOpenAIKey`, chave no SecretStorage e só os ids que responderam. Unidade legado `nvidia-cursor-proxy.service` é desligada.

O proxy é obrigatório — o Agent do Cursor manda `content` em lista; a NIM rejeita isso com 400. No picker o prefixo diz a origem: `nvidia/…` = NIM, `opencode/…` = pool grátis do OpenCode (só se o LiteLLM `:4000` estiver no ar), sem prefixo = nativo do Cursor.

Sem `git clone` (tarball em `/tmp`, apaga ao sair):

```bash
NVIDIA_NIM_API_KEY=nvapi-… bash -c '
set -euo pipefail
d=$(mktemp -d)
trap "rm -rf \"$d\"" EXIT
curl -fsSL https://github.com/rodriguesfas/nvidia-harness/archive/refs/heads/main.tar.gz \
  | tar -xz -C "$d" --strip-components=1
"$d/install.sh" cursor --yes
'
```

### OpenCode

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh opencode --set-default
opencode
```

Padrão: `nvidia/nvidia/nemotron-3.5-super-vl-120b-a12b`. O instalador tira `moonshotai/kimi-k3` (HTTP 410 desde 2026-10-15) e reescreve `agent.agent` / `debug` / `multitask` se ainda apontarem para DeepSeek Flash (timeout hosted ~5 min). Recarregue o OpenCode e abra uma **sessão nova**.

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

### DeepSeek Harness

```bash
NVIDIA_NIM_API_KEY=nvapi-… ./install.sh deepseek --yes
```

O [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh web`) carrega o catálogo pi-ai da [NVIDIA NIM](https://build.nvidia.com) (~21 ids). Vários 404 (*Function not found*) ou 504 (hosted timeout — `deepseek-ai/deepseek-v4.1-flash`, `z-ai/glm-5.3-flash`). O instalador prova `chat/completions` **com conteúdo** e substitui `providers.nvidia` em `~/.dsh/profiles/web/cordis.patch.yml` só pelos que respondem; o padrão é `nvidia/nemotron-3.5-super-vl-120b-a12b`. A chave vai para `~/.dsh/.credentials.yaml` (`refs.NVIDIA_API_KEY`, permissão `600`) — o YAML só cita `apiKeyEnv`. `local-coder` e o resto do patch ficam. Reabra o dsh (HMR local costuma cair com EMFILE); sessão **nova**, não uma com `moonshotai/kimi-k3`.

Candidatos (smoke 2026-10-24): Nemotron 3.5 Super VL / Ultra 550B / Lightning 30B / Nano Omni, GLM-5.3, GPT OSS 20B, Muse Glimmer 30B, Llama 3.2 11B Vision. Quem falhar o smoke nesta conta sai do picker.

## Diagnóstico

```bash
./install.sh --self-test          # offline: flatten Harmony + HTTP mock (/health, NIM, opencode/fast)
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
lib/nvidia.sh           # chave compartilhada + /models + validação via chat + free-router
lib/cursor-proxy.sh     # instala/sobe o shim :12436
proxy/nvidia-cursor-proxy.py
harnesses/claude.sh
harnesses/cursor.sh
harnesses/opencode.sh
harnesses/vscode.sh
harnesses/antigravity.sh
harnesses/deepseek.sh
lib/dsh-patch.py
config/models.default.txt
config/dsh-models.json
config/claude-models.json
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
| DeepSeek Harness | Coberto (`./install.sh deepseek`) — picker só com smoke 200 |

## Limitações

- Cursor: o Agent exige o proxy local (`:12436`) para flatten Harmony. O serviço `nvidia-harness-cursor-proxy` fica no systemd --user (`Restart=always`) e no boot via linger. Pool OpenCode (`coder`/`fast`) só entra com LiteLLM em `:4000`. A IDE tem de estar **fechada** para gravar o `state.vscdb` (backup só da linha alterada — o banco pode ter dezenas de GB).
- VS Code: a chave fica no SecretStorage da IDE, não no disk do harness.
- Claude Code: depende do proxy LiteLLM local (portas `4310–4313`). Pool OpenCode só entra com LiteLLM em `:4000`.
- Antigravity: Cascade e `agy` não usam a API OpenAI da NIM; o caminho é Cline (OpenAI Compatible).
- DeepSeek Harness: o catálogo pi-ai lista ids mortos; o harness restringe o picker. Credencial do dsh ganha do ambiente. Recarregar a janela depois de gravar (HMR EMFILE).
- `GET /v1/models` da NVIDIA responde sem autenticar; a prova da chave é via `chat/completions` (pule só com `--no-test`).
- Créditos gratuitos da NVIDIA expiram; rate limit da conta free é baixo.

## Licença

MIT — veja `LICENSE`.
