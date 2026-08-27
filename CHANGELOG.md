# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Cursor-style behavior modes (`ask`, `plan`, `debug`, `agent`, `multi-task`)
  with `:AgentMode` / `<leader>am`, per-mode tool policy (read-only vs full),
  dynamic auto-approve (all tools minus `destructive_tools`), and startup
  restore.
- `agent_core.multitask` `run_agent` tool: write-capable parallel subagents on
  avante's agent loop, with an optional `tools` allowlist and detached git
  worktree isolation.
- `get_mode_prompt()` export and `modes` / `destructive_tools` config keys.
- Mode-realm recommendation: hybrid classification (offline keyword heuristic
  + one-shot LLM fallback) hooked into avante's `AvanteInputSubmitted` event,
  with an interactive Switch/Ignore prompt, `:AgentRecommend` and
  `:AgentRecommendToggle` commands, and a `recommend` config block. Modes now
  carry `keywords` and `when_to_use` realm hints.
- Agent autoswitch (provider/model router): hybrid classification against
  profile strengths (`keywords` / `when_to_use` / `autoswitch` fields), an
  interactive Switch/Ignore prompt, `:AgentAutoSwitch` / `:AgentAutoSwitchToggle`
  commands and `<leader>ao` keymap, a `Claude` profile, and an `autoswitch`
  config block.
- `agent_core.coordinator`: merges simultaneous mode + profile recommendations
  into a single prompt (`Switch both` / `Switch mode only` / `Switch profile
  only` / `Ignore`) instead of two sequential prompts.
- Workspace registry (`agent_core.workspace`): persistently register multiple
  project roots and switch between them, with a compact index
  (`get_workspace_prompt()`) injected into the system prompt, plus
  `:AgentWorkspaceAdd` / `:AgentWorkspaceRemove` / `:AgentWorkspaceScan` /
  `:AgentWorkspaceList` / `:AgentWorkspaceSwitch` commands and `<leader>aW` /
  `<leader>aw` / `<leader>aj` keymaps.
- Multi-root MCP indexing (`agent_core.mcp_index`): manages the global
  `~/.config/mcphub/servers.json` to register `ripvec` (native multi-root via a
  `root` parameter) and one `semnav-<slug>` server per supported project, runs a
  one-time `semnav index`, and stops tracked daemons on `VimLeavePre`.
- Generalized indexer helpers `root_for(dir)`, `file_list_for(root)`, and
  `summary_for(root)` so any directory can be rooted and summarized.

## [0.1.0] - 2026-08-26

### Added

- Agent/key profiles with one-key switching (`:AgentSwitch`).
- Project brief indexer generating a committable, structural `AVANTE.md`
  (`:AgentIndex`) with debounced auto-refresh on save.
- Two-tier context strategy: brief always injected, deep context on demand.
- `:AgentProfile` command and `<leader>aP` / `<leader>aI` / `<leader>ap` keymaps.
- Env-first API-key resolution with a 0600 `agent_keys.json` fallback.
- Per-project `semnav` opt-in with `VimLeavePre` daemon cleanup.
- MIT license, CI, security gates, and contributing documentation.

[Unreleased]: https://github.com/whitecat1331/agent_core.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/whitecat1331/agent_core.nvim/releases/tag/v0.1.0
