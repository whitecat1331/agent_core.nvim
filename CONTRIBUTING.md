# Contributing to agent_core.nvim

Thanks for contributing. This plugin is small and Lua-only; the bar for a
quality PR is: code is `stylua`-clean, `selene`-clean, passes the headless nvim
smoke test, and follows Conventional Commits.

## Development setup

The plugin works identically under Neovim on WSL (Linux) and under Neovim on
Windows (which shells out to WSL for nvim). Pick either — the CI matrix runs
both.

### WSL (nvim)

```bash
# Install the lint/format toolchain
bash scripts/setup-dev.sh

# Install the git hooks
bash .githooks/install-git-hooks.sh
```

Load the plugin from source during development:

```lua
-- lazy.nvim
{
  dir = "/path/to/agent_core.nvim",
  config = function()
    require("agent_core").setup()
  end,
}
```

### Windows (Neovim)

From PowerShell:

```powershell
.\scripts\setup-dev.ps1
.\githooks\install-git-hooks.ps1
```

The Lua sources live under `lua/agent_core/` and are edited the same way
regardless of host.

## Running the checks

All gates are in `.githooks/lib/checks.sh` (the single source of truth; the
local hooks and GitHub Actions call the same functions so they cannot drift).

```bash
# Everything the pre-push hook runs
bash .githooks/lib/checks.sh run_ci_security
bash .githooks/lib/checks.sh run_ci_lint
bash .githooks/lib/checks.sh run_ci_smoke
bash .githooks/lib/checks.sh run_ci_tests

# Format (and check) the Lua sources
stylua lua/
stylua --check lua/
selene lua
```

## Unit tests

The suite lives under `tests/` and uses a dependency-free harness (no plenary or
busted). `tests/harness.lua` provides `describe`/`it` plus assertion helpers
(`equals`, `not_equals`, `truthy`, `falsy`, `same`, `contains`, `matches`,
`throws`); `tests/run.lua` requires every `*_spec.lua` and invokes the runner.

Run them headlessly:

```bash
nvim --headless -u tests/minimal_init.lua "+lua require('tests.run')"
```

Adding a spec:

1. Create `tests/<module>_spec.lua` that `require`s the module under test and
   `tests.harness`, then registers `describe`/`it` blocks.
2. Add `require("tests.<module>_spec")` to `tests/run.lua` so it runs in CI.
3. Pure helpers under test must be module exports (`M.<name>`), not locals.
4. Tests must be deterministic and must not require network, LSP servers, or a
   writable `~/.config`; use `vim.fn.tempname()` for any filesystem state and
   clean it up.

The `tests` job in CI runs the same suite on `ubuntu-latest` and
`windows-latest`.

## Commit convention

`TYPE(SCOPE): subject`, e.g. `FEAT(indexer): add semnav opt-in`.

Types: `ADD MOD REMOVE FIX DOCS TEST REFACTOR PERF CI CHORE FEAT STYLE BUILD REVERT`.

The `commit-msg` hook enforces this.

## Workflow

1. Fork the repository.
2. Create a feature branch off `main`.
3. Make changes; run `stylua lua/` and the checks above.
4. Open a pull request into `main`.

The default branch is `main`. Maintainers may push `main` directly; contributors
open PRs.
