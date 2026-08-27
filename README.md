# agent_core.nvim

An agent orchestrator for Neovim that makes `avante.nvim` feel more like a
Cursor-style agent: one-key switching between provider/model/API-key profiles,
Cursor-style behavior **modes** (ask / plan / debug / agent / multi-task), an
auto-generated project brief that is injected into the system prompt, and a
two-tier context strategy that pulls deep context on demand via MCP tools.

<p align="center">
  <a href="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml"><img src="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whitecat1331/agent_core.nvim/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

## What it does

1. **Profiles** — bundle a provider, model, API key, and optional persona
   together and switch between them with one key.
2. **Modes** — Cursor-style `ask`, `plan`, `debug`, `agent`, and `multi-task`
   modes. A mode bundles a system-prompt persona, a tool policy (read-only vs
   full), and an auto-approve policy.
3. **Indexer** — generates a committable project brief (`AVANTE.md`) and
   refreshes it on save.
4. **Two-tier context** — the brief is always injected into the system prompt
   (cheap, structural); deep context is pulled on demand via MCP tools
   (semantic search, repo map, call graphs) so the model only spends tokens
   when it actually needs deeper context.
5. **Multi-task** — a write-capable `run_agent` subagent tool for fanning out
   parallel work, with optional isolated git worktrees.
6. **Mode recommendation** — classifies each prompt against the active mode's
   realm and suggests a switch when the prompt is out of scope.
7. **Agent autoswitch** — routes each prompt to the best-fit provider/model
   (DeepSeek / Gemini / Claude) based on declared profile strengths.
8. **Workspace registry** — persistently register multiple project roots and
   switch between them, with a compact index injected into the system prompt.
9. **Multi-root indexing** — semantic/structural search across every registered
   project (ripvec natively via a `root` parameter, `semnav` via one MCP server
   per project), not just the active repo.

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

`agent_core` exposes `get_brief_prompt()`, `get_mode_prompt()`, and
`get_workspace_prompt()` for the system prompt, plus the active persona via
`vim.g.agent_persona` and a write-capable `run_agent` subagent tool. A minimal
`avante.nvim` integration:

```lua
require("avante").setup({
  system_prompt = function()
    local parts = { "You are a senior software engineer." }
    local persona = vim.g.agent_persona
    if persona and persona ~= "" then
      table.insert(parts, persona)
    end
    local ok, core = pcall(require, "agent_core")
    if ok then
      if core.get_mode_prompt then
        local m = core.get_mode_prompt()
        if m and m ~= "" then table.insert(parts, m) end
      end
      if core.get_brief_prompt then
        table.insert(parts, core.get_brief_prompt())
      end
      if core.get_workspace_prompt then
        local ws = core.get_workspace_prompt()
        if ws and ws ~= "" then table.insert(parts, ws) end
      end
    end
    return table.concat(parts, "\n\n")
  end,
  custom_tools = function()
    local tools = {}
    -- ... your other custom tools (e.g. mcphub's mcp_tool) ...
    local ok, mt = pcall(require, "agent_core.multitask")
    if ok and mt.run_agent_tool then
      table.insert(tools, mt.run_agent_tool())
    end
    return tools
  end,
})
```

> **Note on keymaps:** avante's default `<leader>am` / `<leader>aM` (ACP
> selectors) collide with `agent_core`'s `<leader>am` (AgentMode). Remap
> avante's `mappings.select_acp_mode` / `mappings.select_acp_model` to a free
> key if you don't use ACP.

## Commands & keymaps

| Command         | Keymap       | Purpose                                     |
|-----------------|--------------|---------------------------------------------|
| `:AgentSwitch`  | `<leader>aP` | Pick an agent/key profile                   |
| `:AgentMode`    | `<leader>am` | Pick an agent mode (ask/plan/debug/agent/multi-task) |
| `:AgentIndex`   | `<leader>aI` | Regenerate `AVANTE.md` for the current repo |
| `:AgentProfile` | `<leader>ap` | Show the active profile                     |
| `:AgentRecommend` | —          | Recommend a mode for a prompt (args, selection, or input) |
| `:AgentRecommendToggle` | —   | Enable/disable automatic mode recommendation |
| `:AgentAutoSwitch` | `<leader>ao` | Recommend an agent profile for a prompt |
| `:AgentAutoSwitchToggle` | — | Enable/disable automatic agent routing |
| `:AgentWorkspaceAdd` | `<leader>aW` | Add a project (default: cwd) to the workspace |
| `:AgentWorkspaceRemove` | —      | Remove a project from the workspace |
| `:AgentWorkspaceScan` | —       | Scan a folder for git repos and register them |
| `:AgentWorkspaceList` | `<leader>aw` | List registered workspace projects |
| `:AgentWorkspaceSwitch` | `<leader>aj` | Switch to a registered workspace project |

## Configuration

```lua
require("agent_core").setup({
  brief_filename = "AVANTE.md",      -- filename written at the project root
  semnav_bin = "semnav",             -- semnav binary (resolved via exepath)
  ripvec_bin = "ripvec-mcp",         -- ripvec MCP binary (multi-root search)
  brief_prompt_max_chars = 8000,     -- token budget for the injected brief
  refresh_debounce_ms = 5000,        -- debounce for auto-refresh after saves
  profiles = nil,                    -- nil = use built-in defaults
  modes = nil,                       -- nil = use built-in defaults
  -- Mode-realm recommendation: classify each submitted prompt and suggest a
  -- mode switch when it is out of scope for the active mode.
  recommend = {
    enabled = true,                  -- listen on AvanteInputSubmitted
    confidence_threshold = 0.6,      -- below this, the LLM fallback runs
    use_llm_fallback = true,         -- one-shot LLM classification
    min_prompt_length = 8,           -- ignore shorter prompts
  },
  -- Agent autoswitch: route each prompt to the best-fit provider/model.
  autoswitch = {
    enabled = true,
    confidence_threshold = 0.6,
    use_llm_fallback = true,
    min_prompt_length = 8,
  },
  -- Workspace registry: multiple project roots for multi-root indexing.
  workspace = {
    enabled = true,
    registry_dir = nil,      -- nil = <data>/agent_core/workspace.json
    scan_parent = nil,       -- optional parent dir auto-scanned for git repos
    prompt_max_chars = 6000, -- token budget for the injected workspace index
    auto_index_on_add = true,
    auto_index_on_scan = true,
  },
  -- Tools treated as destructive: never auto-approved in full modes.
  destructive_tools = {
    "delete_path", "move_path", "write_global_file", "run_python", "git_commit",
  },
  excluded_dirs = { ".git", "node_modules", ".venv", "vendor" },
})
```

### Profiles

Profiles live in `lua/agent_core/profiles.lua` (`M.defaults`). Each bundles
`name`, `provider`, `model`, `api_key_name`, and an optional `description` /
`system_prompt`. Pass your own `profiles` table to `setup()` to override the
defaults.

### Modes

Modes live in `lua/agent_core/modes.lua` (`M.defaults`). A **mode** is
orthogonal to a **profile**: profiles pick the model/API key, modes pick the
behavior. Each mode bundles:

| Mode       | read-only | auto-approve            | persona focus                 |
|------------|-----------|-------------------------|-------------------------------|
| `ask`      | yes       | n/a                     | read-only Q&A                 |
| `plan`     | yes       | n/a                     | research + produce a plan     |
| `agent`    | no        | all except destructive  | autonomous build/edit         |
| `debug`    | no        | all except destructive  | runtime-evidence bugfixing    |
| `multi-task` | no      | all except destructive  | parallel fan-out orchestration |

Read-only modes keep avante's read/search tools but disable every mutating
tool (`bash`, `run_python`, `str_replace`, `write_to_file`, `edit_file`,
`git_commit`, `move_path`, `delete_path`, `create_dir`, `write_todos`,
`run_agent`, ...), matching Cursor's ask/plan behavior.

The auto-approve list for full modes is computed dynamically as
`(all tools) - destructive_tools`, so it stays in sync as avante adds tools.
`bash` can still be destructive; move it into `destructive_tools` if you want
prompts for it. Set `auto_approve = "all"` on a mode to auto-approve everything.

The active mode is persisted and restored on startup (once avante is loaded).
Pass your own `modes` table to `setup()` to override the defaults.

## Multi-task (parallel subagents)

In `multi-task` mode the persona instructs the model to fan out independent
work using the `run_agent` tool. Unlike avante's built-in read-only
`dispatch_agent`, `run_agent` subagents get the full write-capable tool set and
run on avante's agent loop. Emit **multiple `run_agent` tool calls in a single
message** to run them concurrently; each returns its `attempt_completion`
summary for the lead to synthesize.

`run_agent` accepts:

- `prompt` (required) — a detailed, self-contained task.
- `tools` (optional) — an allowlist of tool names to restrict the subagent.
- `worktree` (optional) — run the subagent in an isolated detached git
  worktree (`git worktree add`) so it cannot collide with the main tree. This
  changes the process cwd, so prefer the default shared tree for parallel
  subagents and use `worktree = true` only for tasks that would otherwise
  conflict.

## Mode recommendation

`agent_core` listens for avante's `AvanteInputSubmitted` event and classifies
each prompt against the active mode's **realm**. If the prompt is a poor fit —
e.g. "implement this feature" while in `ask`, or "fix this bug" while in
`plan` — it suggests switching to the best-fit mode with a reason and an
interactive `Switch / Ignore` prompt.

Classification is **hybrid**:

1. **Heuristic** — a fast, offline keyword scorer (weighted phrase matching
   against each mode's `keywords`). High-confidence matches short-circuit with
   no network call.
2. **LLM fallback** — for low-confidence prompts, a one-shot classification
   request is sent through avante's own client. On any failure or timeout it
   degrades gracefully to the heuristic result.

Modes carry two realm-hint fields (`lua/agent_core/modes.lua`) that drive this:

- `keywords` — weighted lowercase phrases. A plain string has weight 1; use
  `{ "phrase", 2 }` for a stronger signal.
- `when_to_use` — a one-line reason shown in the switch prompt.

The active mode's `read_only` flag also feeds the heuristic: an imperative edit
verb submitted while in a read-only mode boosts the full-write modes so the
mismatch is surfaced more readily.

Commands: `:AgentRecommend [prompt]` (fall back to visual selection, then an
input prompt) and `:AgentRecommendToggle` (enable/disable the automatic hook).
Config keys live under `require("agent_core").setup({ recommend = { ... } })`.

## Agent autoswitch (provider/model router)

`agent_core` also listens for `AvanteInputSubmitted` and classifies each prompt
against the profiles' declared **strengths**. If a different profile is a
better fit — e.g. "summarize this document" while DeepSeek is active, or
"review the security architecture" while Gemini is active — it offers an
interactive `Switch / Ignore` prompt.

Routing is hybrid, mirroring the mode recommender:

1. **Heuristic** — weighted keyword scoring over each profile's `keywords`.
2. **LLM fallback** — one-shot classification through avante's own client for
   low-confidence prompts, degrading to the heuristic on failure/timeout.

Profiles carry three routing fields (`lua/agent_core/profiles.lua`):

- `keywords` — weighted lowercase phrases (a plain string weighs 1,
  `{ "phrase", 2 }` weighs 2).
- `when_to_use` — one-line reason shown in the switch prompt.
- `autoswitch = false` — excludes a profile from routing (the local
  `DeepSeek (local)` Ollama model is excluded so real work is never silently
  sent to a 1.3b model; select it manually via `:AgentSwitch`).

Default routing strengths:

| Profile           | Strengths                                              |
|-------------------|--------------------------------------------------------|
| `DeepSeek (cloud)`| general coding: implement, build, refactor, fix, test  |
| `Gemini`          | fast / long-context / multimodal: summarize, explain, image, research |
| `Claude`          | deep reasoning / architecture / security: design, audit, review, analyze |

Commands: `:AgentAutoSwitch [prompt]` (fall back to visual selection, then an
input prompt), `:AgentAutoSwitchToggle`, and keymap `<leader>ao`. Config keys
live under `require("agent_core").setup({ autoswitch = { ... } })`.

### Merged recommendations

The mode recommender and the agent autoswitch share one `AvanteInputSubmitted`
hook. When both fire on the same prompt (e.g. a task that needs both a
different mode and a different model), `agent_core.coordinator` merges them
into a **single** prompt with four options: `Switch both`, `Switch mode only`,
`Switch profile only`, or `Ignore`. With only one recommendation active, it
falls back to the plain `Switch / Ignore` prompt.

## Workspace registry

`agent_core` keeps a persistent registry of project roots so the agent can work
across several repos without you having to re-point it manually. The registry
lives in `<data>/agent_core/workspace.json` (a plain JSON array of
`{ path, name, summary, added_at }` entries) and only stores structural metadata
— paths and language summaries — never file contents or secrets.

- `:AgentWorkspaceAdd [path]` (or `<leader>aW`) — add the current dir (or a
  given path), detecting its git root and deriving a one-line summary.
- `:AgentWorkspaceScan [parent]` — find git repos under a parent folder
  (`config.workspace.scan_parent` or cwd) and register each.
- `:AgentWorkspaceRemove` — pick a project and drop it.
- `:AgentWorkspaceList` (`<leader>aw`) — list registered projects.
- `:AgentWorkspaceSwitch` (`<leader>aj`) — pick a project and `cd` into it
  (refreshing its brief).

The registry is injected into the system prompt via `get_workspace_prompt()`:
a compact index of `name`, `path`, and one-line summary per project, bounded by
`workspace.prompt_max_chars`. The active project keeps its full brief; for other
projects the agent uses the MCP tools on demand (see below).

## Multi-root indexing

Once projects are registered, the agent can search and reason across all of
them, not just the active repo. Two indexers cooperate:

- **ripvec** (`ripvec-mcp`) is natively multi-root: its retrieval tools
  (`search`, `find_similar`, `get_repo_map`, `reindex`) accept a `root`
  parameter and lazily mount/index that root. No per-project registration is
  needed — the agent just supplies the path it sees in the workspace index.
- **semnav** is strictly per-root (`index <root>` / `serve <root>`), so
  `agent_core` registers one `semnav-<slug>` MCP server per registered project
  that supports a semnav language (Go/Rust/JS/Python). `mcphub` starts these
  lazily (`auto_toggle_mcp_servers`), so N projects do not spawn N daemons at
  startup; tracked daemons are stopped on `VimLeavePre`.

`agent_core` manages the global `~/.config/mcphub/servers.json`, preserving any
servers you added manually and recomputing only its own `ripvec` + `semnav-*`
keys. Adding a project triggers a one-time `semnav index` if its graph DB is
missing. Add `.semnav/` and `.mcphub/` to `.gitignore` in opted-in repos.

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

- `mcphub.nvim` merges `~/.config/mcphub/servers.json` (global, managed by
  `agent_core.mcp_index` for multi-root) with any per-project
  `.mcphub/servers.json`.
- `ripvec` — semantic + BM25 + LSP search, natively multi-root via a `root`
  parameter; zero setup.
- `semnav` — LSP semantic graph, registered as one server per supported
  project. See [Multi-root indexing](#multi-root-indexing) for how the global
  file is managed and daemons are cleaned up.

  `semnav` needs the relevant LSP server on `PATH` (`gopls`, `rust-analyzer`,
  `pyright`, or `typescript-language-server`). Add `.semnav/` and `.mcphub/`
  to `.gitignore` in opted-in repos.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup (Windows/Cursor
and WSL/nvim), running the checks, and the Conventional Commits style.

## License

[MIT](LICENSE)
