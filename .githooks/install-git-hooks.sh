#!/usr/bin/env bash
# Install the agent_core.nvim git hooks (bash / WSL / Linux / macOS).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
git config core.hooksPath .githooks
echo "Hooks installed (core.hooksPath=.githooks)"
