#!/usr/bin/env bash
# Install the agent_core.nvim development toolchain (bash / WSL / Linux).
set -euo pipefail

install_bin() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    echo "[setup] $name already installed: $(command -v "$name")"
    return
  fi
  if command -v cargo-binstall >/dev/null 2>&1; then
    echo "[setup] installing $name (cargo-binstall)..."
    cargo binstall -y "$name"
  elif command -v cargo >/dev/null 2>&1; then
    echo "[setup] installing $name (cargo, compiling)..."
    cargo install --locked "$name"
  else
    echo "[setup] ERROR: install rustup (https://rustup.rs) or cargo-binstall first" >&2
    exit 1
  fi
}

install_bin stylua
install_bin selene

# detect-secrets (used to generate/audit .secrets.baseline)
if ! command -v detect-secrets >/dev/null 2>&1; then
  echo "[setup] installing detect-secrets (pip)..."
  python3 -m pip install --user detect-secrets
fi

echo "[setup] done."
echo "  - Install git hooks: bash .githooks/install-git-hooks.sh"
echo "  - Regenerate baseline: detect-secrets scan > .secrets.baseline"
