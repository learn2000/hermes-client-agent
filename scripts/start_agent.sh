#!/usr/bin/env bash
set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT"

if [ ! -f ".env" ]; then
    echo -e "${YELLOW}No .env found. Creating from .env.example...${NC}"
    if [ -f ".env.example" ]; then
        cp .env.example .env
        echo -e "${YELLOW}IMPORTANT: Edit .env and change HERMES_AGENT_TOKEN${NC}"
    fi
fi

if [ -d ".venv" ] && [ ! -w ".venv" ]; then
    echo -e "${RED}ERROR: .venv/ is not writable (owned by another user).${NC}"
    echo "  Fix:  sudo chown -R \$USER:\$USER .venv/"
    echo "  Or:   rm -rf .venv && uv sync"
    exit 1
fi

echo "Installing dependencies with uv..."
uv sync

echo "Starting Hermes Agent on port 8765..."
uv run python agent.py
