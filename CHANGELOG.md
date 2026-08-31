# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Cursor-style chat workspace (`:AgentChat`, `<leader>a<Space>`): a persistent
  three-pane surface — chat list (open + searchable history) on the left, the
  active chat's message view on the right, and a multi-line composer at the
  bottom. The composer sends with Enter (Shift+Enter = newline) and exposes
  `<C-n>` new chat, `<C-m>` model picker, `<C-d>` mode picker, `<C-s>` stop,
  and `<C-x><C-o>` for the @-mention / slash-command menu. `:AgentNew`
  (`<leader>aT`) starts a fresh session.
- In-chat model switching persisted per-session: picking a model in the
  composer applies it to the current session and writes it onto the session
  record, so resuming a chat restores its model.
- Stream cancellation end-to-end: the transport handle is threaded through the
  providers to `Session:cancel()`, exposed as Stop in the composer/message view.
  Cancelled turns finish with a `cancelled` status and are never persisted.
- Collapsible tool-call blocks: tool results render as `## Tool · <name>` marker
  folds, and pane buffers enable `foldmethod=marker`.
- `history.delete_session` / `history.persist_model` and the runtime
  `remove_session` helper backing chat-list rename/delete.

- `agent_core.registry`: unified model registry with trust tiers (`local`,
  `private-remote`, `third-party-cloud`), role tags (`primary` / `completion` /
  `edit` / `classifier`), and value tags (`cost`, `latency`, `fim`,
  `reasoning`, `quality_tier`). Local Ollama models are auto-discovered from
  `/api/tags`; remote backends are declared with a one-time third-party-cloud
  warning. Adds `:AgentRegistryList` / `:AgentRegistryAdd` commands.
- `agent_core.policy`: model selection from three orthogonal knobs
  (`model_policy`, `trust_scope`, `caution`) plus named aliases
  (`privacy`, `cautious`, `question_first`, `quality`, `speed`, `cost_first`).
  Derived behavior (classifier gate, expanded `destructive_tools`, token
  trimming, mode bias) is computed from the knobs so they cannot drift. Adds
  the `:AgentPolicy` command and `<leader>ay` keymap.
- Completion backend router (`agent_core.completion`): `backends` config plus a
  policy-driven, health-based selector with 30s caching, auto-failover to
  local, and keep-alive warm-on-switch.
- Policy wiring into `autoswitch` (trust/hard filter + policy re-rank +
  classifier gate), `recommend` (mode bias + classifier gate), and `modes`
  (`effective_destructive_tools`).
- Value tags on the default profiles in `profiles.lua` so chat profiles
  participate in policy filtering.
- `agent_core.catalog`: curated, versioned model catalog (per-1M cost,
  `quality_score`, authoritative `fim`/`insert_template`/`reasoning` flags,
  context window, latency hint) shipped as a bundled snapshot and refreshable
  via `:AgentCatalogUpdate`. A fetched catalog is field-allowlisted so it can
  never set `api_key_name` / `endpoint` / `trust`.
- `agent_core.setup`: first-run wizard (`:AgentSetup`, `<leader>aS`) that detects
  env/keys/remote Ollama, collects missing keys in a reviewable form, persists
  the enabled-provider set, and optionally bootstraps policy + default profile
  from a single AI call (catalog tags only). Auto-offers on first load when
  unconfigured (headless-safe).
- Multi-endpoint Ollama discovery in `agent_core.registry`: per-endpoint cache,
  endpoint + trust stamping (`local` loopback, `private-remote` otherwise), and
  a `registry.ollama_endpoints` list for remote GPU boxes.
- Numeric policy scoring in `agent_core.policy`: `POLICY_DEFS` now rank on
  `cost_in_per_1m`/`cost_out_per_1m`, `quality_score`, and measured latency,
  with coarse-string fallback for unknown user models.
- Rolling measured latency in `agent_core.completion`: the health router records
  observed round-trips and stamps `latency_ms` so the `fast` policy ranks on
  real latency, not just the catalog hint.
- Agent skills (`agent_core.skills`): discover `SKILL.md` procedures (project +
  user), parse frontmatter (`name` / `description` / `argument-hint` /
  `user-invocable`), inject a metadata-only index via `get_skills_prompt()`,
  expose the `read_skill` tool, and list them with `:AgentSkills`.
- IDE import (`agent_core.import`): one-time, non-destructive migration of
  rules/skills from Cursor or VSCode into neutral `.agent_core/` directories
  (single-source picker, `:AgentImport`). All source-IDE on-disk paths are
  confined to this module.
- Auto context attachment (`agent_core.context`): a bounded `## Current context`
  system-prompt block from the open buffer window, the visual selection, and LSP
  diagnostics, exported as `get_context_prompt()` and gated by the `context`
  config block.
- Glob-scoped rules + `read_rule` (`agent_core.rules`): `globs` frontmatter is
  honored at attach time (`rules.auto_attach_globs`, on by default) so a rule is
  injected in full only when the active file matches; the `read_rule` tool reads
  any rule's full body on demand.
- Ask-the-user tool (`agent_core.ask`): an `ask_user` custom tool surfaces a
  clarifying question through `vim.ui.input` and returns the answer (headless-safe).
- User-invocable skills (`agent_core.skills`): `M.invocable()` / `M.invoke()`,
  a `run_skill` tool, and `:AgentSkill` (`<leader>at`) run a skill by name with
  an argument, substituting `{{args}}` / `{arg}` placeholders.
- Tab jump-in-file (`agent_core.completion`): `M.predict_next_location()` and
  `:AgentNextLocation` (`<leader>aL`) predict the next edit line and jump the
  caret there.
- Richer @-mentions (`agent_core.mentions`): `@file` / `@folder` / `@symbol`
  providers (file read, recursive listing, LSP document symbols with ripgrep
  fallback) join the existing `@codebase` / `@git` / `@web` / `@docs`.
- Session history (`agent_core.history`): `M.list()` / `M.load()` and
  `:AgentHistory` (`<leader>aH`) list and resume prior agent chat sessions.
  `:AgentRename` (`<leader>ar`), `:AgentFork` (`<leader>aF`),
  `:AgentRewind` (`<leader>aU`), and `:AgentSessionBind` (`<leader>ah`) add
  Cursor-style chat navigation: rename, branch, jump-back-to-a-message, and
  per-session model recall on resume.
- Custom modes (`agent_core.modes`): user-defined modes via `modes.extra` or
  `<data>/agent_core/modes.json`, merged with the built-ins (a plain array still
  replaces them) and surfaced in `:AgentMode` + mode recommendation.
- Custom profiles (`agent_core.profiles`): user-defined routable agents via
  `profiles.extra` or `<data>/agent_core/profiles.json`, merged with the
  defaults (deduped by name; a plain array still replaces them). A custom
  profile can carry its own `endpoint` (reaching the registry + completion
  backends), `trust`, and `keywords`/`when_to_use` for autoswitch routing, with
  missing capability tags defaulted from the provider. The `GPU Ollama
  (qwen2.5-coder)` agent is no longer bundled in the catalog — it is seeded as
  the canonical example in the user's `profiles.json`.
- Plan + idea manager (`agent_core.plan` + `agent_core.plan_manager`): plans
  now carry a `status` in their Markdown frontmatter (`draft` → `in_progress` →
  `completed` → `abandoned` → `draft`; missing frontmatter reads as `draft`),
  `:AgentPlanBuild` marks a plan `in_progress`, and `:AgentPlans` (`<leader>aq`)
  opens a scratch-buffer manager listing unfinished plans, completed/abandoned
  plans, and a project-scoped ideas backlog (`.agent_core/plan_ideas.json`).
  `:AgentPlanIdea [title]` adds an idea; promoting one writes a real plan and
  removes it from the backlog. `plan.list()` / `read_status` / `set_status` /
  `cycle_status` and `add_idea` / `remove_idea` / `promote_idea` back the UI.
- Plan + idea reminders (`agent_core.plan` + `agent_core.plan_manager`): a
  once-per-session `vim.notify` startup popup plus a persistent, collapsible
  floating badge (`agent_core · N unfinished plan(s) · M idea(s)`) that surfaces
  outstanding plans and undrafted ideas, project-scoped and gated by
  `config.plan.remind` (`enabled` / `startup_popup` / `indicator`). In the
  badge `<CR>`/`e` expand to `:AgentPlans` and `q`/`<Esc>` dismiss for the
  session; `:AgentPlansToggle` (`<leader>aQ`) toggles. Every plan/idea mutation
  emits a `User AgentPlanChanged` autocmd so both surfaces auto-refresh (and
  re-surface after a 0 → non-zero transition) with no reload or `:cd` required.
- Per-turn keep / discard (`agent_core.session_edits`): journals every
  `write_to_file` / `str_replace` the active chat makes, so `:AgentKeep`
  (`<leader>aK`) locks in a turn and `:AgentDiscard` (`<leader>aX`) reverts the
  un-kept turns in LIFO order (deleting created files, restoring overwritten
  files). Complements whole-tree checkpoints with Cursor-style per-turn Undo
  All. Configurable via `config.session_edits`; journals live at
  `<data>/agent_core/session_edits/<session_id>.json`.
- Command + keymap cheat sheet (`agent_core.cheatsheet`): `:AgentCheatsheet`
  (`<leader>a?`) opens a floating, grouped reference of every `Agent*` command
  and its currently-mapped key. The key column is introspected from live
  keymap state at render time (not a hardcoded table), so user `vim.keymap.set`
  remaps are reflected on reopen or `r`; `q`/`<Esc>` closes.
- Automations (`agent_core.automation`): recurring prompts persisted to
  `<data>/agent_core/automations.json` and scheduled via `vim.uv` timers, with
  `:AgentAutomationList/Add/Remove/Run` (`<leader>aA`); each run goes through
  `agent_core.runner`.
- Browser control (`agent_core.browser`): `browser_open` / `browser_screenshot` /
  `browser_snapshot` headless-browser tools (Playwright or Chrome/Edge fallback).
- Multimodal image input (`agent_core.image` + `agent_core.runner`): a
  `read_image` vision tool reads/describes an image (or answers a question about
  it) through a vision-capable profile. `runner.llm_curl` now accepts an
  `images` list (base64 + media type) and builds the multimodal array-form
  content the owned runtime expects. Adds the `vision` capability tag to the catalog/
  registry, `registry.for_capability("vision")` + `registry.is_vision(model)`,
  and `image` config keys (`vision_profile` / `vision_model` /
  `max_image_bytes`). A text-only model is never silently sent an image —
  `read_image` refuses with a clear error when no vision-capable profile
  resolves.
- Interactive image-paste guard (`agent_core.image`): `install_paste_guard()`
  guards interactive pastes via the owned clipboard bridge so pasting an image
  into a chat whose active model cannot see images (e.g. DeepSeek) is handled
  per `image.paste_guard` (`"block"` / `"warn"` / `"auto_switch"` / `false`),
  with pure `paste_allowed` / `guard_paste` helpers that are unit-tested.
- Composer-style diff UX (`agent_core.diff`): a shared per-hunk accept/reject
  presenter for every edit path. `completion.apply_edit` and bugbot autofix
  route through it; adds `:AgentDiffApply` / `:AgentDiffAccept` /
  `:AgentDiffReject` commands and `<leader>aa` / `<leader>aY` / `<leader>aN`
  keymaps. Pure helpers (`compute_hunks` / `merge` / `render` / `toggle`) are
  headless-safe and unit-tested.
- Syntax-highlighted ghost text (`agent_core.completion`): ghost text now
  derives per-token highlight groups from treesitter (with a dimmed fallback
  when no parser is available) instead of a single `Comment` highlight.
- Multi-file coordinated edits (`agent_core.edits`): `:AgentCoordinatedEdit`
  (`<leader>aE`) gathers cross-file context for the symbol under the caret,
  requests a structured JSON edit set, validates every path inside the repo
  root, checkpoints, applies, and presents a combined diff with accept/cancel
  (rollback via `:AgentRollback`).
- Owned-runtime config surface (`runtime` block): `agent_core.setup({ runtime =
  {...} })` now merges `session` / `ui` / `clipboard` / `tools` / `context`
  (conversation compaction) / `workflows` knobs into
  `agent_core.runtime.config`, so the Phase 6 features are user-configurable
  instead of locked to defaults. The top-level `context` block remains auto
  *attach* context (buffer/selection/diagnostics) — distinct from
  `runtime.context` compaction.
- Slash commands + context variables wired into `runtime.submit`: `/plan`,
  `/mode`, `/profile`, `/workflow`, and `/agent` dispatch at submit time (mode
  or profile switch, workflow run, or fresh-session submit), and `@file` /
  `@git` / `#buffer` / `@selection` / `@lsp` tokens expand before the prompt
  reaches the agent loop.
- Owned MCP tool bridge wired into `runtime.submit`: `runtime.mcp` now loads
  `~/.config/mcphub/servers.json` (best-effort), discovers each server's tools
  via `tools/list`, and merges them into the agent tool set (`discover_all` +
  `call_tool`), so ripvec/semnav search tools reach the model directly.
- First-install reset (`:AgentSettingsClear[!]`): wipes all global
  agent_core state — API keys (OS keychain + `agent_keys.json`), the active
  profile/mode, and the entire `<data>/agent_core/` tree — returning the plugin
  to its out-of-the-box state. `!` skips the confirmation prompt. Project-scoped
  files (`.agent_core/`, `AVANTE.md`, `.semnav/`, `.mcphub/`) are untouched.

### Changed

- **Single model list.** `lua/agent_core/catalog_snapshot.lua` is now the sole
  source of truth for every model backend: identity, capability tags (cost,
  quality_score, fim/insert_template, reasoning, vision, context_window,
  latency_hint), and — for entries that double as chat agents — the persona +
  routing fields (description, system_prompt, autoswitch, keywords,
  when_to_use). `agent_core.profiles` now projects the entries that carry a
  system_prompt into the profile list (deriving cost/quality_tier/latency from
  the catalog), so `profiles.lua` and `catalog_snapshot.lua` can no longer
  drift. Local Ollama agents carry unified `primary`+`completion`+`edit` roles.

- **Owned agent runtime (avante.nvim retired).** `agent_core.nvim` is now fully
  self-contained: `lua/agent_core/runtime/` provides the provider transport
  (`transport.lua` + `providers/*` for DeepSeek/OpenAI-compat, Anthropic,
  Gemini, and Ollama), a per-session agent loop (`session.lua`), a tool registry
  (`tools/`), owned history persistence (`history/`), the multi-pane Agents
  Window grid (`ui/`), and clipboard→vision bridging (`clipboard.lua`). Every
  `require("avante.*")` was swapped to `agent_core.runtime` and `avante.nvim`
  was dropped from the dependency list. Provider/model are now **per-session**
  fields (not a process-global), so N sessions can stream on N different models
  concurrently, and `run_agent` subagents fan out in parallel instead of the
  old sequential `active_overrides` guard.

- `agent_core.policy` `model_policy` is now an axis selection: `balanced`
  (default) or any 1-3 of `good` / `fast` / `cheap`. Selecting all three is
  equivalent to `balanced`; an empty selection is rejected. Two axes intersect
  their hard filters and sum their scores. `cheap` now enforces a cost ceiling
  (rejects the `expensive` tier).

- Brand-neutral on-disk layout: rules/plans/skills now live under
  `.agent_core/` and `<data>/agent_core/`; `.cursor/` interop (rules, skills,
  `CURSOR.md`, `.cursorrules`) is handled only by `agent_core.import`. Neovim
  caret API/event names (`nvim_win_get_cursor`, `CursorMoved`, ...) are
  isolated behind `agent_core.platform` (`get_caret` / `set_caret` / `events`),
  and internal caret variables/comments are renamed to "caret".

- Behavior modes (`ask`, `plan`, `debug`, `agent`, `multi-task`)
  with `:AgentMode` / `<leader>am`, per-mode tool policy (read-only vs full),
  dynamic auto-approve (all tools minus `destructive_tools`), and startup
  restore.
- `agent_core.multitask` `run_agent` tool: write-capable parallel subagents on
  the owned agent loop, with an optional `tools` allowlist and detached git
  worktree isolation.
- `get_mode_prompt()` export and `modes` / `destructive_tools` config keys.
- Mode-realm recommendation: hybrid classification (offline keyword heuristic
  + one-shot LLM fallback) hooked into the owned `AgentInputSubmitted` event,
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
- Web access (`agent_core.web`): read-only `web_fetch` (URL -> readable text)
  and `web_search` (DuckDuckGo) custom tools, both running through `curl`
  with a user agent and hard timeout.
- GitHub context (`agent_core.github`): a read-only `github` custom tool
  wrapping the `gh` CLI to pull PRs, issues, and search results into context via
  an allowlisted subcommand (no arbitrary shell execution).
- Notepads (`agent_core.notepad`): persistent user-authored markdown notes under
  `<data>/agent_core/notepads/`, a title index injected via `get_notepad_prompt()`,
  and `:AgentNotepad` / `:AgentNotepadNew` / `:AgentNotepadEdit` /
  `:AgentNotepadDelete` commands plus the `<leader>an` keymap.
- Rules auto-injection (`agent_core.rules`): aggregates `AGENTS.md` /
  `CLAUDE.md` and `.agent_core/rules/*.mdc|md` (project + user) into a
  bounded system-prompt block via `get_rules_prompt()`, mirroring the rules
  hierarchy.
- Best-of-n (`agent_core.bestofn`): fans one prompt out to N configured profiles
  and shows their outputs side-by-side in a scratch buffer, with `:AgentBestOfN`
  (`<leader>ab`) and `bestofn` config keys (`profiles`, `timeout_ms`).
- Plan mode artifact (`agent_core.plan`): `create_plan` / `update_plan` custom
  tools write an editable Markdown plan (with file paths, an ordered TODO
  checklist, and trade-offs) to `config.plan.dir` (default `.agent_core/plans/`),
  and `:AgentPlanBuild` / `:AgentPlanBuildNew` (`<leader>aB`) switch to agent
  mode and submit the plan for implementation ("Build" / "Build in New
  Agent"). Plan mode stays read-only for code but allow-lists its own plan tools.
- Debug instrumentation loop (`agent_core.debug`): `add_debug_instrumentation` /
  `remove_debug_instrumentation` / `request_reproduction` custom tools plus a
  `:AgentDebugCleanup` command and `<leader>ad` keymap, tracking temporary
  logging in `<data>/agent_core/debug/` and removing it by exact text match so
  the real fix is never deleted. The debug persona now runs the 6-step
  hypothesize → instrument → reproduce → analyze → fix → cleanup loop.
- Agent checkpoints (`agent_core.checkpoint`): non-intrusive `git diff --binary`
  snapshots (no commits/stash) via the `checkpoint` / `rollback` custom tools
  and `:AgentCheckpoint` / `:AgentRollback` commands plus `<leader>ac`, with a
  registry picker for choosing which snapshot to restore with `git apply -R`.
- Mode engine reconciliation: `WRITE_TOOLS` now matches the owned built-in tool
  names (`bash`, `create`, `edit_file`, `insert`, `replace_in_file`, `str_replace`,
  `undo_edit`, `write_to_file`, `write_todos`) plus the new custom tools, and
  `destructive_tools` defaults to `{ "bash", "rollback" }`. Read-only modes gain
  a per-mode `allow_tools` whitelist (`disabled = WRITE_TOOLS - allow_tools`).
- Tab autocomplete (`agent_core.completion`): a blink.cmp source (`blink_source()`
  or `module = "agent_core.completion"`) that predicts code via Ollama
  fill-in-the-middle (`POST /api/generate`), plus `:AgentPredictEdit` (`<leader>ae`)
  for linter-aware predictive edits grounded in LSP diagnostics and a recent-edit
  log, checkpointing first and showing a diff before applying.
- Local Bugbot (`agent_core.bugbot`): `:AgentBugbot [--autofix] [--base=X]`
  (`<leader>ag`) reviews the working tree or branch diff with parallel review
  workers and presents a severity-ranked report; `--autofix` applies fixes in an
  isolated new-branch worktree, commits, pushes, and opens a PR via `gh pr create`.
- Persistent agent memory (`agent_core.memory`): `remember` / `recall` / `forget`
  custom tools storing facts in `<data>/agent_core/memory.json`, a key index
  injected via `get_memory_prompt()`, and `:AgentMemory` (`<leader>aM`).
- Headless runner (`agent_core.runner`): `agent_core.run(prompt, opts, cb)` and
  `:AgentRun` (`<leader>aR`) run a single agent headlessly from git hooks / cron,
  the local analog of a headless SDK runtime and Automations.
- Agent lifecycle hooks (`agent_core.hooks`): `before/after_prompt`,
  `before/after_tool`, and `on_run_end` Lua callbacks plus `User` autocmds
  (`AgentHookBeforePrompt`, `AgentHookBeforeTool`, etc.) around agent_core tools.
- Write-capable GitHub tooling: the `github` tool gains allowlisted `create_pr` /
  `commit` / `comment` / `push` write actions (explicit `gh`/`git` subcommands),
  with `create_pr` / `commit` / `push` added to `destructive_tools`.
- `get_custom_tools()` export: returns every agent_core custom tool (run_agent,
  web, github, plan, debug, checkpoint, bugbot, memory, skills, rules, ask,
  browser) already wrapped by hooks, so the owned runtime's tool registry
  consumes them in one loop.
- Cross-platform layer (`agent_core.platform`): OS detection, absolute-path
  detection (POSIX/drive/UNC), binary resolution, path joining, and a
  shell-aware command joiner. `curl`/`semnav`/`ripvec-mcp` binary resolution and
  the indexer's non-git fallback are now portable across Linux, macOS, and
  Windows, and `get_os_hint()` supplies the correct shell/path instructions to
  the system prompt.
- Unit test suite (`tests/`): a dependency-free Lua harness (`describe`/`it` plus
  assertion helpers) and spec files covering the pure logic of every module
  (platform, modes, profiles, recommend, autoswitch, web, slugify, notepad,
  bugbot, indexer, memory). Wired into the pre-push hook and a new `tests` CI
  job on `ubuntu-latest` + `windows-latest`. Several previously-private pure
  helpers (e.g. `web.parse_ddg`, `notepad.title_for`, `bugbot.chunk_diff`,
  `indexer.language_counts`) were promoted to module exports to make them
  testable.
- Checkpoints capture untracked files: `agent_core.checkpoint` now snapshots
  `git ls-files --others --exclude-standard` into a sidecar
  `<label>.untracked.json` manifest, and rollback deletes files created after
  the snapshot and restores files that existed at snapshot time.
- Streaming FIM + ghost text: `agent_core.completion` streams Ollama
  `/api/generate` NDJSON (with `stream: true`) and renders a real inline
  ghost-text suggestion (extmark `virt_text`) accepted via
  `config.completion.ghost_text.accept_key` (default `<C-l>`), clearing on
  caret movement.
- Debug runtime-evidence channel: `agent_core.debug.read_evidence()` tails
  `config.debug.log_file` and/or runs `config.debug.log_cmd`, exposed to the
  model via a new `read_captured_logs` custom tool.
- Worktree guard: `run_agent` worktrees are now sequential-only (an in-flight
  counter rejects a second concurrent worktree run and steers the model to
  `worktree = false`).
- Rules frontmatter parsing: `agent_core.rules.parse_frontmatter()` extracts
  `description` / `globs` / `alwaysApply` from `.mdc` files; non-`always` rules
  inject only their metadata.
- Concurrent best-of-n: `agent_core.bestofn` fans profiles out in parallel using
  a per-run provider copy (no shared provider mutation).
- Inline-edit / predictive-edit split: `:AgentPredictEdit` is now an
  instruction-less next-edit prediction, and `:AgentInlineEdit` (`<leader>ak`)
  is the instruction-driven inline rewrite.
- OS keychain backend: `agent_core.keys` stores secrets in macOS Keychain
  (`security`) or Linux libsecret (`secret-tool`) before falling back to the
  0600 JSON file; `M.backend()` reports the active backend.
- @-mention providers (`agent_core.mentions`): expands `@codebase` / `@git` /
  `@web` / `@docs` tokens via `:AgentMentions` (`<leader>a@`) or
  `M.expand(prompt, cb)`.
- Image generation (`agent_core.image`): a `generate_image` custom tool that
  calls a configurable OpenAI-compatible images endpoint and returns image URLs.
- Real-debugger bridge (`agent_core.dap`): a thin, adapter-agnostic controller
  over `nvim-dap` that gives the model true debugger parity — set/clear
  breakpoints, launch, step over/into/out, pause, restart, inspect threads, stack
  frames, scopes, and variables, and evaluate expressions. The blocking tools
  (`debug_start` / `debug_continue` / `debug_step_*`) hold their `on_complete`
  until the debugger actually stops and then return the full paused state, so the
  `tool_result` is the injection channel (no upstream fork). `nvim-dap` is
  soft-required: without it (or an adapter) the tools error cleanly and the
  existing instrumentation loop remains the fallback. Ships `:AgentDebugStart` /
  `:AgentDebugContinue` / `:AgentDebugStepOver` / `:AgentDebugStepInto` /
  `:AgentDebugStepOut` / `:AgentDebugStop` / `:AgentDebugStatus` (`<leader>aD`
  for start) and a `dap` config block.

### Fixed

- `agent_core.notepad.title_for` no longer spans multiple lines when the first
  heading is followed by body content (the `^…$` pattern matched across `%s`
  newlines, returning the whole note instead of just the heading text).
- `agent_core.platform.resolve_bin` no longer mangles Windows-style absolute
  paths (`C:\tools\curl.exe`) on POSIX hosts by passing them through `expand()`;
  it now returns absolute paths unchanged and only expands `~`.
- `agent_core.dap.setup()` now merges `config.dap` (previously the `dap` config
  block was accepted but never applied, so custom `timeout_ms` / `max_frames` /
  `max_variables` / `max_output_chars` were silently ignored).

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
