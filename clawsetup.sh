#!/bin/bash

# Piped install (curl … | bash -s): fd 0 is the script; children used to inherit it and could
# eat the rest of this file. Commands that might read stdin use </dev/null; optional: source
# ~/.bashrc </dev/null when fd 0 is not a tty. Use -s so arguments after -- reach this script:
#   curl -fsSL URL | bash -s -- --install-deps

# When piped (curl ... | bash), BASH_SOURCE may be '-' or a non-file fd; use cwd for .env discovery.
_script_path="${BASH_SOURCE[0]:-}"
if [[ -z "$_script_path" || "$_script_path" == '-' || "$_script_path" == '/dev/stdin' || ! -f "$_script_path" ]]; then
    SCRIPT_DIR="$PWD"
else
    SCRIPT_DIR="$(cd "$(dirname "$_script_path")" && pwd)"
fi
unset _script_path

DEFAULT_MODEL_ID="minimax/minimax-m2.5"

# Default values
DEFAULT_CONTEXT_WINDOW=196000
DEFAULT_MAX_TOKENS=16000

MODEL_ID=""
# Preserve API_KEY if exported before running (e.g. API_KEY=x curl … | bash); do not wipe here.
: "${API_KEY:=}"
CONTEXT_WINDOW=$DEFAULT_CONTEXT_WINDOW
MAX_TOKENS=$DEFAULT_MAX_TOKENS
INSTALL_DEPS=false
ENV_FILE_ARG=""

# Display usage
usage() {
    echo "Usage: $0 [model_id] [api_key] [context_window] [max_tokens] [options]"
    echo "One-liner:  curl -fsSL https://your.domain/clawsetup.sh | bash -s -- --install-deps"
    echo "            (-s reads the script from the pipe; everything after -- is passed here.)"
    echo "Fallback:   bash -c \"\$(curl -fsSL URL)\" -- args   (only if a rare environment breaks the pipe.)"
    echo "Example: $0 minimax/minimax-m2.5 sk-mykey123 196000 16000"
    echo "Example: $0 minimax/minimax-m2.5 --install-deps"
    echo "         (API key from .env, API_KEY / OPENCLAW_API_KEY env, or prompt on /dev/tty)"
    echo ""
    echo "Positional arguments:"
    echo "  model_id         Model identifier (optional; default: $DEFAULT_MODEL_ID)"
    echo "  api_key          API key (optional if set via .env or entered when prompted)"
    echo "  context_window   Context window (optional; if api_key is omitted and this is"
    echo "                   numeric-only, it is treated as context_window — see README)"
    echo "  max_tokens       Max tokens (optional, default: $DEFAULT_MAX_TOKENS)"
    echo ""
    echo "Options:"
    echo "  --install-deps           Install nvm (~/.nvm), Node.js and npm via nvm, then pnpm."
    echo "                           Node/npm are user-local; profile hooks can override your"
    echo "                           existing node/npm on PATH. Skip this if you already have"
    echo "                           Node, npm, and pnpm installed and configured."
    echo "  --env-file PATH          Read API key only from this file (API_KEY or OPENCLAW_API_KEY)"
    echo "  -h, --help               Show this help"
    exit 0
}

# Check for help flag before main parse
if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
fi

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        --env-file)
            if [ -z "${2:-}" ]; then
                echo "Error: --env-file requires a path" >&2
                exit 1
            fi
            ENV_FILE_ARG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

if [ -z "${1:-}" ]; then
    MODEL_ID="$DEFAULT_MODEL_ID"
else
    MODEL_ID="$1"
    shift
fi

if [[ "$MODEL_ID" == --install-* ]]; then
    echo "Error: unknown option '$MODEL_ID'. Did you mean --install-deps? Put flags before other arguments." >&2
    exit 1
fi

CONTEXT_WINDOW=$DEFAULT_CONTEXT_WINDOW
MAX_TOKENS=$DEFAULT_MAX_TOKENS

# Remaining positionals: api_key, context_window, max_tokens (after optional model).
# If api_key is omitted, numeric-only args can be context/max.
case $# in
    0)
        ;;
    1)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            CONTEXT_WINDOW="$1"
        else
            API_KEY="$1"
        fi
        ;;
    2)
        if [[ "$1" =~ ^[0-9]+$ ]]; then
            CONTEXT_WINDOW="$1"
            MAX_TOKENS="$2"
        else
            API_KEY="$1"
            CONTEXT_WINDOW="$2"
        fi
        ;;
    *)
        API_KEY="$1"
        [ -n "${2:-}" ] && CONTEXT_WINDOW="$2"
        [ -n "${3:-}" ] && MAX_TOKENS="$3"
        ;;
esac

source_bashrc() {
    if [ -f "$HOME/.bashrc" ]; then
        # shellcheck disable=SC1090
        if [ -t 0 ]; then
            source "$HOME/.bashrc"
        else
            source "$HOME/.bashrc" </dev/null
        fi
    else
        echo "Warning: ~/.bashrc not found; nvm/pnpm may not be on PATH" >&2
    fi
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    export PNPM_HOME="${PNPM_HOME:-$HOME/.local/share/pnpm}"
    export PATH="$PNPM_HOME:$PATH"
}

strip_env_value() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    v="${v%$'\r'}"
    if [[ "${#v}" -ge 2 && ${v:0:1} == '"' && ${v: -1} == '"' ]]; then
        v="${v:1:${#v}-2}"
    elif [[ "${#v}" -ge 2 && ${v:0:1} == "'" && ${v: -1} == "'" ]]; then
        v="${v:1:${#v}-2}"
    fi
    printf '%s' "$v"
}

extract_key_from_env_file() {
    local file="$1"
    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+([^=[:space:]]+)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        elif [[ "$line" =~ ^[[:space:]]*([^=[:space:]]+)[[:space:]]*=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
        else
            continue
        fi
        if [[ "$key" == "API_KEY" || "$key" == "OPENCLAW_API_KEY" ]]; then
            API_KEY="$(strip_env_value "$val")"
            [ -n "$API_KEY" ] && return 0
        fi
    done < "$file"
    return 1
}

# Prompt/read from the real terminal. Piped installs (cat/curl … | bash) use stdin for the
# script; read -rs can still consume that stream on some setups — use stty + read on /dev/tty only.
read_secret_api_key_from_tty() {
    local tty=/dev/tty line saved stty_ok=0
    [ -r "$tty" ] || return 1
    saved=$(stty -g <"$tty" 2>/dev/null) && stty_ok=1
    [ "$stty_ok" -eq 1 ] || return 1
    if ! [ -t 0 ]; then
        echo "Note: script input is a pipe; type your API key on the terminal below (not shown)." >&2
    fi
    printf 'Enter API key: ' >"$tty" || return 1
    stty -echo <"$tty" 2>/dev/null || true
    IFS= read -r line <"$tty" || line=""
    if [ "$stty_ok" -eq 1 ]; then
        stty "$saved" <"$tty" 2>/dev/null || stty sane <"$tty" 2>/dev/null || true
    fi
    printf '\n' >"$tty" || true
    API_KEY="$line"
    return 0
}

sanitize_api_key() {
    API_KEY="${API_KEY//$'\r'/}"
    API_KEY="${API_KEY//$'\n'/}"
    API_KEY="${API_KEY#"${API_KEY%%[![:space:]]*}"}"
    API_KEY="${API_KEY%"${API_KEY##*[![:space:]]}"}"
}

load_api_key() {
    if [ -n "$API_KEY" ]; then
        sanitize_api_key
        return 0
    fi
    if [ -n "$ENV_FILE_ARG" ]; then
        if [ ! -f "$ENV_FILE_ARG" ]; then
            echo "Error: --env-file not found: $ENV_FILE_ARG" >&2
            exit 1
        fi
        if extract_key_from_env_file "$ENV_FILE_ARG"; then
            echo "Using API key from $ENV_FILE_ARG"
            sanitize_api_key
            return 0
        fi
        echo "Error: API_KEY or OPENCLAW_API_KEY not set in $ENV_FILE_ARG" >&2
        exit 1
    fi
    local f
    for f in "$SCRIPT_DIR/.env" "$PWD/.env" "$HOME/.openclaw/.env"; do
        [ -f "$f" ] || continue
        if extract_key_from_env_file "$f"; then
            echo "Using API key from $f"
            sanitize_api_key
            return 0
        fi
    done
    if [ -n "${OPENCLAW_API_KEY:-}" ]; then
        API_KEY="$OPENCLAW_API_KEY"
        echo "Using API key from OPENCLAW_API_KEY"
        sanitize_api_key
        return 0
    fi
    if ! read_secret_api_key_from_tty; then
        echo "Error: cannot read API key from TTY (piped install). Use --env-file, a .env file," >&2
        echo "       or run:  export API_KEY=...  before:  cat script.sh | bash" >&2
        exit 1
    fi
    sanitize_api_key
    if [ -z "$API_KEY" ]; then
        echo "Error: API key is required" >&2
        exit 1
    fi
}

load_api_key
source_bashrc

# Detect package manager and define install function
detect_pkg_manager() {
    if command -v apt-get &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    else
        echo "Error: no supported package manager found (apt, dnf, yum)"
        exit 1
    fi
    echo "Detected package manager: $PKG_MANAGER"
}

install_system_packages() {
    local USE_SUDO=""
    [ "$(id -u)" -ne 0 ] && USE_SUDO="sudo"

    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_SUSPEND=1

    case "$PKG_MANAGER" in
        apt)
            $USE_SUDO apt-get update -y
            $USE_SUDO apt-get install -y build-essential curl wget jq git unzip
            ;;
        dnf)
            $USE_SUDO dnf update -y
            $USE_SUDO dnf groupinstall -y "Development Tools"
            $USE_SUDO dnf install -y curl wget jq git unzip
            ;;
        yum)
            $USE_SUDO yum update -y
            $USE_SUDO yum groupinstall -y "Development Tools"
            $USE_SUDO yum install -y curl wget jq git unzip
            ;;
        *)
            echo "Error: unsupported package manager '$PKG_MANAGER'"
            exit 1
            ;;
    esac
}

# Install nvm, node, pnpm if --install-deps flag is set
if [ "$INSTALL_DEPS" = true ]; then
    echo "Note: --install-deps installs Node.js and npm via nvm under your home directory (~/.nvm)."
    echo "      New shells may prefer this node/npm over other installs. If you already have"
    echo "      Node, npm, and pnpm set up, cancel (Ctrl+C) and rerun without --install-deps."
    echo "Installing dependencies (nvm, node, pnpm)..."
    detect_pkg_manager
    install_system_packages
    LATEST=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep '"tag_name"' | awk -F'"' '{print $4}')
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${LATEST}/install.sh" | bash && source_bashrc
    nvm install node </dev/null
    npm install -g pnpm </dev/null
    pnpm setup </dev/null
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"
    source_bashrc
    echo "Dependencies installed successfully!"
fi

source_bashrc

# Helper: approve any pending devices
approve_pending_devices() {
    echo "Checking for pending device approvals..."
    # Strip any non-JSON lines before the opening '{' (e.g. gateway warning messages)
    DEVICES_JSON=$(openclaw devices list --json 2>/dev/null </dev/null | sed -n '/^{/,$p')
    PENDING_REQUEST_ID=$(echo "$DEVICES_JSON" | jq -r '.pending[0].requestId // empty' 2>/dev/null)

    if [ -n "$PENDING_REQUEST_ID" ]; then
        echo "Found pending device request: $PENDING_REQUEST_ID"
        openclaw devices approve "$PENDING_REQUEST_ID" </dev/null
        echo "Device approved successfully!"
    else
        echo "No pending device approvals found."
    fi
}

# Install openclaw if not already installed
if ! command -v openclaw &> /dev/null; then
    echo "openclaw not found, installing..."

    OPENCLAW_REPO_DIR="$HOME/openclaw"

    if [ ! -d "$OPENCLAW_REPO_DIR" ]; then
        echo "Downloading latest openclaw release..."
        LATEST_URL=$(curl -s https://api.github.com/repos/openclaw/openclaw/releases/latest \
            | jq -r '.zipball_url')
        
        curl -L "$LATEST_URL" -o /tmp/openclaw.zip
        unzip -q /tmp/openclaw.zip -d /tmp/openclaw_extracted
        
        # GitHub zipball extracts to a directory like openclaw-openclaw-<hash>/
        EXTRACTED_DIR=$(find /tmp/openclaw_extracted -maxdepth 1 -mindepth 1 -type d | head -n1)
        mv "$EXTRACTED_DIR" "$OPENCLAW_REPO_DIR"
        
        rm -rf /tmp/openclaw.zip /tmp/openclaw_extracted
    else
        echo "Repository directory already exists at $OPENCLAW_REPO_DIR, skipping download."
    fi

    cd "$OPENCLAW_REPO_DIR" || { echo "Error: failed to enter $OPENCLAW_REPO_DIR"; exit 1; }

    pnpm install </dev/null
    pnpm ui:build </dev/null
    pnpm build </dev/null
    pnpm link --global </dev/null

    openclaw onboard --install-daemon --non-interactive --accept-risk </dev/null || true

    # Approve pending devices immediately after onboarding
    approve_pending_devices

    cd - > /dev/null || exit 1
    echo "openclaw installed successfully!"
else
    echo "openclaw is already installed, skipping installation."
fi

CONFIG_FILE="$HOME/.openclaw/openclaw.json"

# Delete "agents" and "models" sections, then add them back with new config
jq --arg model_id "$MODEL_ID" \
   --arg model_key "llm/${MODEL_ID}" \
   --arg api_key "$API_KEY" \
   --argjson context_window "$CONTEXT_WINDOW" \
   --argjson max_tokens "$MAX_TOKENS" '
  # Delete the sections
  del(.agents, .models) |

  # Recreate agents section
  .agents = {
    "defaults": {
      "workspace": (env.HOME + "/.openclaw/workspace"),
      "model": {
        "primary": $model_key
      },
      "models": {
        ($model_key): {}
      }
    }
  } |

  # Recreate models section
  .models = {
    "mode": "merge",
    "providers": {
      "llm": {
        "baseUrl": "https://inference.asicloud.cudos.org/v1",
        "api": "openai-completions",
        "apiKey": $api_key,
        "models": [
          {
            "id": $model_id,
            "name": ($model_id + " (Custom Provider)"),
            "contextWindow": $context_window,
            "maxTokens": $max_tokens,
            "input": ["text"],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "reasoning": false
          }
        ]
      }
    }
  }
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" </dev/null

# Replace the original file
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo "Configuration updated successfully!"
echo "Model: $MODEL_ID"
echo "Context Window: $CONTEXT_WINDOW"
echo "Max Tokens: $MAX_TOKENS"

echo "Starting openclaw dashboard..."
openclaw dashboard </dev/null