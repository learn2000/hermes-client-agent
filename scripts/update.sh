#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

REPO_URL="https://github.com/scwall/hermes-client-agent.git"
PYPROJECT="$ROOT/pyproject.toml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [--check | --install]"
    echo ""
    echo "  --check      Check for newer version, print result, but don't update"
    echo "  --install    Apply update if available (git pull + rebuild)"
    echo ""
    echo "Without options, checks for updates and prompts interactively."
}

get_local_version() {
    awk -F'"' '/^version *= *"/ {print $2; exit}' "$PYPROJECT"
}

get_remote_version() {
    local tags
    tags=$(git ls-remote --tags --refs "$REPO_URL" 2>/dev/null || echo "")

    if [ -z "$tags" ]; then
        tags=$(curl -sfL "https://api.github.com/repos/scwall/hermes-client-agent/git/refs/tags" 2>/dev/null | \
               python3 -c "import json,sys; [print(t['ref']) for t in json.load(sys.stdin)]" 2>/dev/null || echo "")
    fi

    echo "$tags" | sed -n 's|.*refs/tags/v\?\([0-9.]*\).*|\1|p' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

version_greater() {
    local a="$1" b="$2"
    if [ "$a" = "$b" ]; then return 1; fi
    local IFS=.
    local a_parts=($a) b_parts=($b)
    local i max
    max=${#a_parts[@]}
    [ ${#b_parts[@]} -gt "$max" ] && max=${#b_parts[@]}
    for ((i = 0; i < max; i++)); do
        local av="${a_parts[$i]:-0}" bv="${b_parts[$i]:-0}"
        if [ "$av" -lt "$bv" ]; then return 1; fi
        if [ "$av" -gt "$bv" ]; then return 0; fi
    done
    return 1
}

check_update() {
    local local_ver remote_ver
    local_ver=$(get_local_version)
    echo -e "${CYAN}Local version:  v$local_ver${NC}"

    echo -n "Checking GitHub..."
    remote_ver=$(get_remote_version)

    if [ -z "$remote_ver" ]; then
        echo ""
        echo -e "${RED}ERROR: Could not check GitHub for updates.${NC}"
        echo "  Make sure you have internet access."
        return 3
    fi

    echo -e "\r${CYAN}Latest release: v$remote_ver${NC}"

    if version_greater "$local_ver" "$remote_ver"; then
        echo -e "${GREEN}You are up to date.${NC}"
        return 0
    elif [ "$local_ver" = "$remote_ver" ]; then
        echo -e "${GREEN}You are up to date.${NC}"
        return 0
    else
        echo -e "${YELLOW}Update available: v$local_ver -> v$remote_ver${NC}"
        return 1
    fi
}

do_update() {
    cd "$ROOT"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        echo -e "${RED}ERROR: Not a git repository. Cannot auto-update.${NC}"
        echo "  Clone again: git clone $REPO_URL"
        exit 1
    fi

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    local has_changes=false
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        has_changes=true
        echo -e "${YELLOW}Local changes detected.${NC}"
        if [ "${1:-}" = "--install" ]; then
            echo "  Stashing local changes..."
            git stash push -m "hermes-agent update $(date -Iseconds)" 2>/dev/null || true
        else
            echo -n "Stash local changes and continue? [Y/n] "
            read -r answer
            if [ "${answer:-y}" = "y" ] || [ "${answer:-y}" = "Y" ] || [ -z "${answer:-}" ]; then
                git stash push -m "hermes-agent update $(date -Iseconds)" 2>/dev/null || true
            else
                echo "Aborted."
                exit 0
            fi
        fi
    fi

    echo "Pulling latest changes..."
    git fetch origin --tags 2>/dev/null || true
    git pull origin "$current_branch" --ff-only 2>/dev/null || {
        echo -e "${RED}ERROR: git pull failed. You may need to resolve conflicts manually.${NC}"
        if $has_changes; then
            echo "  Restore stashed changes: git stash pop"
        fi
        exit 1
    }

    echo "Reinstalling dependencies..."
    uv sync 2>/dev/null || {
        echo -e "${YELLOW}Warning: uv sync failed. You may need to run it manually.${NC}"
    }

    local service_active
    service_active=$(systemctl --user is-active hermes-agent 2>/dev/null || echo "unknown")
    if [ "$service_active" = "active" ]; then
        echo "Restarting hermes-agent service..."
        systemctl --user restart hermes-agent || true
    fi

    local new_ver
    new_ver=$(get_local_version)
    echo -e "${GREEN}Update complete: v$new_ver${NC}"
}

main() {
    local mode="${1:-interactive}"

    case "$mode" in
        --help|-h)
            usage
            exit 0
            ;;
        --check)
            check_update
            exit $?
            ;;
        --install)
            check_update || {
                local ec=$?
                if [ $ec -eq 3 ]; then exit 1; fi
                do_update --install
            }
            exit 0
            ;;
        interactive|"")
            if ! check_update; then
                local ec=$?
                if [ $ec -eq 3 ]; then exit 1; fi
                echo ""
                echo -n "Apply update now? [Y/n] "
                read -r answer
                if [ "${answer:-y}" = "y" ] || [ "${answer:-y}" = "Y" ] || [ -z "${answer:-}" ]; then
                    do_update
                else
                    echo "Skipping update."
                fi
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
