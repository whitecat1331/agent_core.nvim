# Install the agent_core.nvim development toolchain (PowerShell / Windows / Cursor).
$ErrorActionPreference = "Stop"

function Install-CargoBin($Name) {
  if (Get-Command $Name -ErrorAction SilentlyContinue) {
    Write-Host "[setup] $Name already installed: $((Get-Command $Name).Source)"
    return
  }
  if (Get-Command cargo-binstall -ErrorAction SilentlyContinue) {
    Write-Host "[setup] installing $Name (cargo-binstall)..."
    cargo binstall -y $Name
  }
  elseif (Get-Command cargo -ErrorAction SilentlyContinue) {
    Write-Host "[setup] installing $Name (cargo, compiling)..."
    cargo install --locked $Name
  }
  else {
    Write-Error "[setup] install rustup (https://rustup.rs) or cargo-binstall first"
  }
}

Install-CargoBin stylua
Install-CargoBin selene

if (-not (Get-Command detect-secrets -ErrorAction SilentlyContinue)) {
  Write-Host "[setup] installing detect-secrets (pip)..."
  python -m pip install --user detect-secrets
}

Write-Host "[setup] done."
Write-Host "  - Install git hooks: .\.githooks\install-git-hooks.ps1"
Write-Host "  - Regenerate baseline: detect-secrets scan > .secrets.baseline"
