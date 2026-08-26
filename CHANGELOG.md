# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
