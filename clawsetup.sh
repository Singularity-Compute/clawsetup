#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
DEFAULT_CONTEXT_WINDOW=196000
DEFAULT_MAX_TOKENS=16000

MODEL_ID=""
API_KEY=""
CONTEXT_WINDOW=$DEFAULT_CONTEXT_WINDOW
MAX_TOKENS=$DEFAULT_MAX_TOKENS
INSTALL_DEPS=false
ENV_FILE_ARG=""

# Display usage
usage() {
    echo "Usage: $0 <model_id> [api_key] [context_window] [max_tokens] [options]"
    echo "Example: $0 minimax/minimax-m2.5 sk-mykey123 196000 16000"
    echo "Example: $0 minimax/minimax-m2.5 --install-deps"
    echo "         (API key from .env or interactive prompt)"
    echo ""
    echo "Positional arguments:"
    echo "  model_id         Model identifier (required, e.g., minimax/minimax-m2.5)"
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
    echo "Error: model_id is required"
    echo ""
    usage
fi

MODEL_ID="$1"
API_KEY=""
CONTEXT_WINDOW=$DEFAULT_CONTEXT_WINDOW
MAX_TOKENS=$DEFAULT_MAX_TOKENS

# Positional disambiguation: if api_key is omitted, the next numeric-only args can be context/max.
case $# in
    1)
        ;;
    2)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
            CONTEXT_WINDOW="$2"
        else
            API_KEY="$2"
        fi
        ;;
    3)
        if [[ "$2" =~ ^[0-9]+$ ]]; then
            CONTEXT_WINDOW="$2"
            MAX_TOKENS="$3"
        else
            API_KEY="$2"
            CONTEXT_WINDOW="$3"
        fi
        ;;
    *)
        API_KEY="$2"
        [ -n "${3:-}" ] && CONTEXT_WINDOW="$3"
        [ -n "${4:-}" ] && MAX_TOKENS="$4"
        ;;
esac

source_bashrc() {
    if [ -f "$HOME/.bashrc" ]; then
        # shellcheck disable=SC1090
        source "$HOME/.bashrc"
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

load_api_key() {
    if [ -n "$API_KEY" ]; then
        return 0
    fi
    if [ -n "$ENV_FILE_ARG" ]; then
        if [ ! -f "$ENV_FILE_ARG" ]; then
            echo "Error: --env-file not found: $ENV_FILE_ARG" >&2
            exit 1
        fi
        if extract_key_from_env_file "$ENV_FILE_ARG"; then
            echo "Using API key from $ENV_FILE_ARG"
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
            return 0
        fi
    done
    read -rs -p "Enter API key: " API_KEY
    echo
    if [ -z "$API_KEY" ]; then
        echo "Error: API key is required" >&2
        exit 1
    fi
}

source_bashrc
load_api_key

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
    nvm install node
    npm install -g pnpm
    pnpm setup
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
    DEVICES_JSON=$(openclaw devices list --json 2>/dev/null | sed -n '/^{/,$p')
    PENDING_REQUEST_ID=$(echo "$DEVICES_JSON" | jq -r '.pending[0].requestId // empty' 2>/dev/null)

    if [ -n "$PENDING_REQUEST_ID" ]; then
        echo "Found pending device request: $PENDING_REQUEST_ID"
        openclaw devices approve "$PENDING_REQUEST_ID"
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

    pnpm install
    pnpm ui:build
    pnpm build
    pnpm link --global

    openclaw onboard --install-daemon --non-interactive --accept-risk || true

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
' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

# Replace the original file
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

echo "Configuration updated successfully!"
echo "Model: $MODEL_ID"
echo "Context Window: $CONTEXT_WINDOW"
echo "Max Tokens: $MAX_TOKENS"

echo "Starting openclaw dashboard..."
openclaw dashboard