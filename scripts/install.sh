#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="hermes-agent"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY="$ROOT/dist/hermes-agent"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [--uninstall] [--source | --binary]"
    echo ""
    echo "  --uninstall    Remove the systemd service and binary"
    echo "  --source       Install from source via uv (dev mode, runs from $ROOT)"
    echo "  --binary       Install from PyInstaller binary ($BINARY)"
    echo ""
    echo "Without options, auto-detects: binary if built, otherwise source."
}

check_command() {
    if ! command -v "$1" &>/dev/null; then
        echo -e "${RED}ERROR: '$1' is required but not found.${NC}"
        if [ "$1" = "uv" ]; then
            echo "  Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
        fi
        exit 1
    fi
}

uninstall() {
    echo "Uninstalling Hermes Agent..."
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$SERVICE_NAME.service"
    systemctl --user daemon-reload
    rm -f "${HOME}/.local/bin/hermes-agent"
    rm -f "${HOME}/.local/bin/.env-hermes"
    echo -e "${GREEN}Uninstall complete.${NC}"
}

ensure_no_root() {
    if [ "$(id -u)" -eq 0 ]; then
        echo -e "${RED}ERROR: Do not run this script as root. It installs as a user service.${NC}"
        exit 1
    fi
}

setup_env() {
    local env_dir="$1"
    if [ ! -f "$env_dir/.env" ]; then
        if [ -f "$ROOT/.env.example" ]; then
            cp "$ROOT/.env.example" "$env_dir/.env"
            echo -e "${YELLOW}Created $env_dir/.env from .env.example${NC}"
            echo -e "${YELLOW}IMPORTANT: Edit $env_dir/.env and change HERMES_AGENT_TOKEN${NC}"
        fi
    else
        echo "Using existing .env at $env_dir/.env"
    fi
}

install_systemd_service() {
    local workdir="$1"
    local exec_cmd="$2"

    local service_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$service_dir"

    cat > "$service_dir/$SERVICE_NAME.service" << EOF
[Unit]
Description=Hermes Remote Control Agent
After=network.target

[Service]
Type=simple
WorkingDirectory=$workdir
ExecStart=/bin/bash -c '$exec_cmd'
Restart=on-failure
RestartSec=5
Environment="PATH=$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME"
    systemctl --user start "$SERVICE_NAME"
}

install_source() {
    check_command uv
    check_command python3

    echo "Installing Hermes Agent from source..."

    cd "$ROOT"
    uv sync
    setup_env "$ROOT"

    install_systemd_service "$ROOT" "uv run python agent.py"

    echo -e "${GREEN}Hermes Agent installed from source.${NC}"
    echo ""
    echo "Check status:  systemctl --user status $SERVICE_NAME"
    echo "View logs:     journalctl --user -u $SERVICE_NAME -f"
    echo "Stop:          systemctl --user stop $SERVICE_NAME"
    echo "Edit config:   $ROOT/.env"
}

install_binary() {
    check_command systemctl

    if [ ! -f "$BINARY" ]; then
        echo -e "${RED}ERROR: $BINARY not found.${NC}"
        echo "  Build it first: ./scripts/build.sh"
        echo "  Or install from source: ./scripts/install.sh --source"
        exit 1
    fi

    local install_dir="${HOME}/.local/bin"
    mkdir -p "$install_dir"
    cp "$BINARY" "$install_dir/hermes-agent"
    chmod +x "$install_dir/hermes-agent"

    setup_env "$install_dir"
    if [ -f "$ROOT/.env" ] && [ ! -f "$install_dir/.env" ]; then
        echo "No .env at $install_dir/.env — copying from repo .env"
        cp "$ROOT/.env" "$install_dir/.env"
    fi

    install_systemd_service "$install_dir" "./hermes-agent"

    echo -e "${GREEN}Hermes Agent installed as a user service.${NC}"
    echo ""
    echo "Check status:  systemctl --user status $SERVICE_NAME"
    echo "View logs:     journalctl --user -u $SERVICE_NAME -f"
    echo "Stop:          systemctl --user stop $SERVICE_NAME"
    echo "Edit config:   $install_dir/.env"
}

main() {
    ensure_no_root

    if [ "${1:-}" = "--uninstall" ]; then
        uninstall
        exit 0
    fi

    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        usage
        exit 0
    fi

    local mode="${1:-auto}"
    case "$mode" in
        --binary) install_binary ;;
        --source|--dev) install_source ;;
        auto|"")
            if [ -f "$BINARY" ]; then
                echo "Detected pre-built binary. Installing from binary."
                echo "  Use --source for source-based install."
                install_binary
            else
                echo "No binary found. Installing from source."
                echo "  Use --binary after running build.sh to install from binary."
                install_source
            fi
            ;;
        *)
            echo -e "${RED}Unknown option: $mode${NC}"
            usage
            exit 1
            ;;
    esac
}

main "${@}"
