# Install the agent_core.nvim git hooks (PowerShell / Windows / Cursor).
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Push-Location $Root
git config core.hooksPath .githooks
Pop-Location
Write-Host "Hooks installed (core.hooksPath=.githooks)"
