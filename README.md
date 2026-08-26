# agent_core.nvim

An agent orchestrator for Neovim that makes `avante.nvim` feel more like a
Cursor-style agent: one-key switching between provider/model/API-key profiles,
an auto-generated project brief that is injected into the system prompt, and a
two-tier context strategy that pulls deep context on demand via MCP tools.

<p align="center">
  <a href="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml"><img src="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whitecat1331/agent_core.nvim/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

## What it does

1. **Profiles** — bundle a provider, model, API key, and optional persona
   together and switch between them with one key.
2. **Indexer** — generates a committable project brief (`AVANTE.md`) and
   refreshes it on save.
3. **Two-tier context** — the brief is always injected into the system prompt
   (cheap, structural); deep context is pulled on demand via MCP tools
   (semantic search, repo map, call graphs) so the model only spends tokens
   when it actually needs deeper context.

## Requirements

- Neovim 0.10+ (tested against 0.12)
- [avante.nvim](https://github.com/avante-corp/avante.nvim) (for the chat UI)
- Optional: [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim) + a
  semantic indexer (`ripvec`, `semnav`) for on-demand retrieval
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the profile
  picker (falls back to `vim.ui.select` when absent)

## Installation

### lazy.nvim

```lua
{
  "whitecat1331/agent_core.nvim",
  config = function()
    require("agent_core").setup()
  end,
}
```

### packer.nvim

```lua
use {
  "whitecat1331/agent_core.nvim",
  config = function()
    require("agent_core").setup()
  end,
}
```

### vim-plug

```vim
Plug 'whitecat1331/agent_core.nvim'
```

Then in your config:

```lua
require("agent_core").setup()
```

### Wire into avante

`agent_core` exposes `get_brief_prompt()` for the system prompt and the active
persona via `vim.g.agent_persona`. A minimal `avante.nvim` integration:

```lua
require("avante").setup({
  system_prompt = function()
    local parts = { "You are a senior software engineer." }
    local persona = vim.g.agent_persona
    if persona and persona ~= "" then
      table.insert(parts, persona)
    end
    local ok, core = pcall(require, "agent_core")
    if ok and core.get_brief_prompt then
      table.insert(parts, core.get_brief_prompt())
    end
    return table.concat(parts, "\n\n")
  end,
})
```

## Commands & keymaps

| Command         | Keymap       | Purpose                                     |
|-----------------|--------------|---------------------------------------------|
| `:AgentSwitch`  | `<leader>aP` | Pick an agent/key profile                   |
| `:AgentIndex`   | `<leader>aI` | Regenerate `AVANTE.md` for the current repo |
| `:AgentProfile` | `<leader>ap` | Show the active profile                     |

## Configuration

```lua
require("agent_core").setup({
  brief_filename = "AVANTE.md",      -- filename written at the project root
  semnav_bin = "semnav",             -- semnav binary (resolved via exepath)
  brief_prompt_max_chars = 8000,     -- token budget for the injected brief
  refresh_debounce_ms = 5000,        -- debounce for auto-refresh after saves
  profiles = nil,                    -- nil = use built-in defaults
  excluded_dirs = { ".git", "node_modules", ".venv", "vendor" },
})
```

### Profiles

Profiles live in `lua/agent_core/profiles.lua` (`M.defaults`). Each bundles
`name`, `provider`, `model`, `api_key_name`, and an optional `description` /
`system_prompt`. Pass your own `profiles` table to `setup()` to override the
defaults.

## Security

- **API keys are resolved env-first**: `profile.api_key` > `os.getenv(api_key_name)`
  > `~/.config/nvim/agent_keys.json` (chmod 0600). Prefer setting
  `DEEPSEEK_API_KEY` / `GEMINI_API_KEY` in a `chmod 600` file sourced by your
  shell. Never put real keys in `profiles.lua` or commit `agent_keys.json`.
- The generated brief is **structural only** — file paths, language counts,
  key files, and build/test commands. It never embeds file contents, so it
  cannot leak secrets, and it is safe to commit.
- See [SECURITY.md](SECURITY.md) for the full model and reporting policy.

## How the brief works

- `:AgentIndex` writes `AVANTE.md` at the git root (or cwd when not a repo).
- It auto-refreshes (debounced) after every `BufWritePost`, but only if a brief
  already exists — run `:AgentIndex` once per repo to opt in.
- Extend `agent_core.indexer` to redact additional patterns if ever needed.

## How MCP indexing works

- `mcphub.nvim` merges `~/.config/mcphub/servers.json` (global) with a
  per-project `.mcphub/servers.json`.
- `ripvec` — semantic + BM25 + LSP search. Registered globally; zero setup.
- `semnav` — LSP semantic graph. Opted in **per project**: `:AgentIndex`
  detects a supported language (Go/Rust/JS/Python), writes the project
  `.mcphub/servers.json`, and runs a one-time `semnav index` if
  `<repo>/.semnav/graph.db` is missing. Tracked daemons are stopped on
  `VimLeavePre`.

  `semnav` needs the relevant LSP server on `PATH` (`gopls`, `rust-analyzer`,
  `pyright`, or `typescript-language-server`). Add `.semnav/` and `.mcphub/`
  to `.gitignore` in opted-in repos.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup (Windows/Cursor
and WSL/nvim), running the checks, and the Conventional Commits style.

## License

[MIT](LICENSE)
