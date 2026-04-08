# clawsetup

`clawsetup.sh` automates installing [OpenClaw](https://github.com/openclaw/openclaw), wiring it to a custom LLM provider, and launching the dashboard. It is aimed at Linux environments that use `apt`, `dnf`, or `yum`.

## What it does

1. **Optional dependency install** (`--install-deps`): installs build tools and common utilities, then installs [nvm](https://github.com/nvm-sh/nvm) under your home directory, uses it to install **Node.js** and **`npm`** locally (per-user, not system-wide packages), and installs [pnpm](https://pnpm.io/) via npm. Your shell profile (for example `~/.bashrc`) is updated so **`node`/`npm` from nvm take precedence** when you open a shell. If you already use another Node install (distro package, fnm, direct binary, corporate image, and so on), **do not pass `--install-deps`**: run the script without that flag so your existing **Node**, **npm**, and **pnpm** stay in charge.

2. **OpenClaw**: If `openclaw` is not on your `PATH`, it downloads the latest release zip from `openclaw/openclaw`, extracts it to `~/openclaw`, runs `pnpm install`, `pnpm ui:build`, `pnpm build`, `pnpm link --global`, then runs non-interactive onboarding (including daemon install). It also tries to approve any pending device via `openclaw devices approve`.

3. **Configuration**: Rewrites `~/.openclaw/openclaw.json` by removing existing `agents` and `models` keys and replacing them with:
   - **Agents**: default workspace `~/.openclaw/workspace` and a primary model key of the form `llm/<model_id>`.
   - **Models**: `merge` mode and a provider `llm` pointing at `https://inference.asicloud.cudos.org/v1` (OpenAI-compatible completions), using your API key and the model metadata you pass in (context window, max tokens, etc.).

4. **Dashboard**: Runs `openclaw dashboard`.

## Requirements

- **Bash** and tools used by the script: `curl`, `jq`, `unzip`, `git` (and `find`, `mv`).

Without `--install-deps` you must already have **pnpm** and a working **Node** (and **npm**) environment, since the OpenClaw install path uses `pnpm`.

**Already have Node/npm/pnpm?** Omit **`--install-deps`**. The flag is meant for clean machines; with it, nvm-managed Node/npm in your home directory become the default in new shells and can **override** what you had before in practice (whichever `node` is first on `PATH` after `source ~/.bashrc`).

With `--install-deps`, the script installs Node via nvm under **`~/.nvm`**. The script also runs `source ~/.bashrc` (via its internal setup) after the nvm installer and at other points so this session can see `nvm` / `pnpm` / `openclaw`.

## Installation environment

**Do not** run this installer from a **`sudo su`** shell, **`sudo -u`**, or any other pattern that **switches user / login context** partway through (nested `su`, a fresh login shell with a different `HOME`, and so on). That often breaks the install: `HOME`, `PATH`, nvm, and `~/.openclaw` no longer line up with the account you meant to use.

**You can** run the script **as your normal user**, or **as root** in a direct, intentional way—but avoid “becoming another user” mid-session with `sudo su` / `su` tricks. If you run as a normal user and `--install-deps` needs package installs, the script uses `sudo` for `apt`/`dnf`/`yum` where required.

## Usage

### One-liner (remote install)

From a directory where you are happy for `.env` to be picked up (optional), or with `API_KEY` / `OPENCLAW_API_KEY` exported:

```bash
curl -fsSL https://raw.githubusercontent.com/Singularity-Compute/clawsetup/main/clawsetup.sh | bash -s -- --install-deps && source ~/.bashrc
```

Omit **`--install-deps`** if you already have Node, npm, and pnpm set up the way you want (same rules as running the script locally).

**Reload your shell profile after running the script** so your interactive shell (or new terminals) match what the script used. Either chain it when you invoke with `bash`, or run `source` on the next line:

```bash
bash clawsetup.sh <model_id> [api_key] [context_window] [max_tokens] [--install-deps] [--env-file PATH] && source ~/.bashrc
```

```bash
chmod +x clawsetup.sh
./clawsetup.sh <model_id> [api_key] [context_window] [max_tokens] [--install-deps] [--env-file PATH]
source ~/.bashrc
```

| Argument / option | Required | Default | Description |
|-------------------|----------|---------|-------------|
| `model_id` | No | `minimax/minimax-m2.5` | Model id as exposed by the provider (e.g. `minimax/minimax-m2.5`). |
| `api_key` | No* | — | API key for the inference endpoint. Omit to load from `.env` or to enter it when prompted. |
| `context_window` | No | `196000` | Reported context window for the model in config. |
| `max_tokens` | No | `16000` | Max output tokens setting in config. |
| `--install-deps` | No | off | Installs system build packages, then **nvm + Node + npm (user-local) + pnpm**. **Skip this flag** if Node, npm, and pnpm are already set up the way you want—otherwise nvm may **take over** `node`/`npm` in your home shell environment. |
| `--env-file PATH` | No | — | Use only this file for the key (`API_KEY` or `OPENCLAW_API_KEY`). The file must exist; if no key is found, the script exits with an error (no prompt). |

\*If you omit `api_key`, the script looks for **`API_KEY`** or **`OPENCLAW_API_KEY`** in the first file that exists, in this order: `.env` next to `clawsetup.sh`, `.env` in the current working directory, `~/.openclaw/.env`. If none of those yield a key, it **prompts** once (input is hidden).

**Omitting the key on the command line:** if the second positional argument is **only digits**, it is treated as `context_window` (not the key), and the key still comes from `.env` or the prompt. Example: `./clawsetup.sh minimax/minimax-m2.5 196000 16000` with a key in `.env`. If your key is numeric-only, put it in `.env` or enter it at the prompt instead of passing it positionally.

Examples:

```bash
./clawsetup.sh minimax/minimax-m2.5 sk-your-key-here

./clawsetup.sh minimax/minimax-m2.5 sk-your-key-here 196000 16000

# Fresh machine only — omit --install-deps if Node, npm, and pnpm are already installed
./clawsetup.sh minimax/minimax-m2.5 sk-your-key-here --install-deps

# Key from .env or prompt (never on argv)
./clawsetup.sh minimax/minimax-m2.5

# Key only from a specific file
./clawsetup.sh minimax/minimax-m2.5 --env-file /path/to/.env
```

After any of these examples, run `source ~/.bashrc` on the next line (or use `bash clawsetup.sh … && source ~/.bashrc` from the top of this section).

`.env` format (one key is enough):

```env
API_KEY=sk-your-key-here
# or
OPENCLAW_API_KEY=sk-your-key-here
```

Show built-in help:

```bash
./clawsetup.sh --help
```

## Security notes

- Passing the API key on the command line exposes it in shell history and process listings. Prefer `.env` (not committed to git), `--env-file` pointing at a restricted path, or the interactive prompt.

- The script runs `openclaw onboard --install-daemon --non-interactive --accept-risk` on first install; read OpenClaw’s own docs for what that implies on your machine.

## Troubleshooting

- **`openclaw` not found**: Run `source ~/.bashrc` (see **Usage**). If it is still missing, ensure nvm/pnpm global bins are configured in `~/.bashrc` and that `pnpm link --global` ran successfully during install.

- **Config errors**: The `jq` rewrite expects `~/.openclaw/openclaw.json` to exist after onboarding. If onboarding fails, create or fix that file before relying on the script’s config step.

- **Package manager**: Only `apt-get`, `dnf`, and `yum` are supported for `--install-deps`; others must install dependencies manually.
