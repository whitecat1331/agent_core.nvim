# agent_core.nvim

A Neovim plugin built on top of avante.nvim that helps users transition from
third-party IDEs such as VSCode and Cursor, and from traditional development to
agentic development, as seamlessly as possible. It bundles one-key switching
between provider/model/API-key profiles, behavior **modes** (ask / plan / debug /
agent / multi-task), an auto-generated project brief that is injected into the
system prompt, and a two-tier context strategy that pulls deep context on demand
via MCP tools.

<p align="center">
  <a href="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml"><img src="https://github.com/whitecat1331/agent_core.nvim/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/whitecat1331/agent_core.nvim/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

## What it does

1. **Profiles** — bundle a provider, model, API key, and optional persona
   together and switch between them with one key.
2. **Modes** — `ask`, `plan`, `debug`, `agent`, and `multi-task`
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
10. **Web access** — read-only `web_fetch` / `web_search` custom tools so the
    agent can pull current documentation and search results.
11. **GitHub context** — read-only `github` custom tool (PRs, issues, search via
    the `gh` CLI) for pulling PR/issue details into context.
12. **Notepads** — persistent user-authored markdown notes with a title index
    injected into the system prompt.
13. **Rules auto-injection** — `AGENTS.md` / `CLAUDE.md` and
    `.agent_core/rules/*.mdc|md` (project) plus `<data>/agent_core/rules/*.mdc|md`
    (user) are loaded into the system prompt with `.mdc` frontmatter
    (`description` / `globs` / `alwaysApply`) honored.
14. **Best-of-n** — fan one prompt out to N configured models and compare their
    outputs side-by-side.
15. **Plan artifacts** — `plan` mode writes a reviewable Markdown plan (with an
    ordered TODO checklist) to `.agent_core/plans/` and `:AgentPlanBuild` turns
    it into an agent run ("Build").
16. **Debug loop** — `debug` mode adds/removes temporary instrumentation around a
    reproduce → analyze → fix cycle, with one-command cleanup.
17. **Checkpoints** — `agent` mode can snapshot and roll back the working tree
    (non-intrusive `git diff --binary` patches plus an untracked-file manifest,
    no commits or stash).
18. **Tab autocomplete** — streaming ghost text (Ollama FIM fill-in-the-middle,
    accepted with a key) plus `:AgentPredictEdit` (instruction-less next-edit
    prediction) and `:AgentInlineEdit` (inline edit) — Tab parity.
19. **Local Bugbot** — `:AgentBugbot` reviews the working tree (or branch vs
    base) with parallel review workers and optionally autofixes in an isolated
    worktree and opens a PR.
20. **Agent memory** — persistent, agent-written memory (`remember` / `recall` /
    `forget`) that learns across runs, distinct from user-authored Notepads.
21. **Headless runner** — `agent_core.run(prompt, opts)` and `:AgentRun` run a
    single agent headlessly from git hooks / cron (local SDK + Automations parity).
22. **Lifecycle hooks** — `before/after_prompt`, `before/after_tool`, and
    `on_run_end` Lua callbacks plus `User` autocmds around agent_core tools.
23. **Write-capable GitHub** — the `github` tool adds allowlisted `create_pr` /
    `commit` / `comment` / `push` write actions (marked destructive).
24. **Cross-platform** — runs identically on Linux, macOS, and Windows via a
    shared `platform` helper (OS detection, binary resolution, path joining,
    shell-aware command joining); `get_os_hint()` gives the model the right
    shell/path instructions per OS.
25. **@-mentions** — expand `@codebase` / `@git` / `@web` / `@docs` tokens in a
    prompt into inline context (local analog of an attach UI).
26. **Image generation** — a `generate_image` tool that calls a configurable
    OpenAI-compatible images endpoint and returns the image URL(s).
27. **OS keychain** — API keys are stored in the OS keychain (macOS Keychain,
    Linux libsecret) with a 0600 JSON fallback (and on Windows).
28. **Real debugger** — a thin, adapter-agnostic bridge over `nvim-dap` that
    lets the AI drive a genuine interactive debugger (breakpoints, stepping,
    stack/scope/variable inspection, expression evaluation) with true
    debugger event parity.
29. **Model catalog** — a curated, versioned catalog of per-token cost,
    benchmark `quality_score`, and authoritative FIM/reasoning flags, shipped as
    data and refreshable via `:AgentCatalogUpdate` (field-allowlisted so a
    fetched catalog can never set keys/endpoints/trust).
30. **First-run setup wizard** — `:AgentSetup` (`<leader>aS`) detects env keys,
    stored keys, and local + remote Ollama, collects missing keys, persists the
    enabled-provider set, and optionally bootstraps policy + default profile
    from one AI call (catalog tags only).
31. **Agent skills** — discover `SKILL.md` procedures (project + user) and
    inject a compact metadata index into the system prompt; the model reads a
    skill's full body on demand with the `read_skill` tool.
32. **IDE import** — `:AgentImport` migrates rules/skills from another IDE
    (Cursor or VSCode) into neutral `.agent_core/` directories,
    non-destructively.
33. **Auto context attach** — `get_context_prompt()` injects the open buffer
    window, visual selection, and LSP diagnostics into the system prompt
    automatically, so the agent sees your current file/selection without any
    manual `@`-mention.
34. **Glob-scoped rules + `read_rule`** — rule frontmatter `globs` are honored
    at attach time (a glob-scoped rule is injected only when it matches the
    active file), and the `read_rule` tool reads any on-demand rule by name.
35. **Ask-the-user tool** — `ask_user` lets an agent ask a clarifying question
    mid-task and wait for the answer instead of guessing.
36. **User-invocable skills** — skills marked `user-invocable: true` can be
    run from `:AgentSkill` or the `run_skill` tool, with an argument substituted.
37. **Tab jump-in-file** — `:AgentNextLocation` predicts the next edit location
    and jumps the caret there.
38. **Richer @-mentions** — `@file <path>`, `@folder <path>`, and
    `@symbol <name>` join `@codebase` / `@git` / `@web` / `@docs`.
39. **Session history** — `:AgentHistory` lists prior avante sessions for resume.
40. **Custom modes** — user-defined modes via `config.modes.extra` or
    `<data>/agent_core/modes.json`.
41. **Automations** — scheduled/recurring headless prompts
    (`:AgentAutomationList/Add/Remove/Run`) that run through the runner.
42. **Browser control** — headless-browser `browser_open` / `browser_screenshot` /
    `browser_snapshot` tools (Playwright or Chrome/Edge).
43. **Command palette** — curated shell commands (one file per command) invoked
    through the constrained `run_command` tool, with a `:AgentCommand` picker.
44. **Image input / vision** — a `read_image` tool reads and describes an image
    (screenshot, diagram, photo, UI mock) or answers a question about it, via a
    vision-capable profile resolved from the registry's `vision` tag. Multimodal
    `llm_curl` support means image + text prompts work through agent_core's own
    paths, matching avante's `img-clip` + `render-markdown` interactive flow.
45. **Composer-style diff UX** — every agent edit (predictive edit, inline edit,
    coordinated edit, bugbot autofix) flows through a shared per-hunk
    accept/reject diff presenter with `:AgentDiffApply` / `:AgentDiffAccept` /
    `:AgentDiffReject`, checkpointed and undoable with `:AgentRollback`.
46. **Multi-file coordinated edits** — `:AgentCoordinatedEdit` (`<leader>aE`)
    gathers cross-file context for the symbol under the caret, asks an
    edit-capable profile for a structured JSON edit set, validates every path,
    checkpoints, applies, and presents a combined diff.

## Requirements

- Neovim 0.10+ (tested against 0.12) on Linux, macOS, or Windows (the plugin is
  platform-agnostic and auto-detects the OS, shell, and path style)
- [avante.nvim](https://github.com/avante-corp/avante.nvim) (for the chat UI)
- Optional: [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim) + a
  semantic indexer (`ripvec`, `semnav`) for on-demand retrieval
- Optional: [snacks.nvim](https://github.com/folke/snacks.nvim) for the profile
  picker (falls back to `vim.ui.select` when absent)

External CLIs used at runtime (resolved on PATH per-OS): `git`, `curl` (web +
FIM completion + image generation), `gh` (GitHub tool), `semnav` / `ripvec-mcp`
(MCP indexing), and `security` (macOS) / `secret-tool` (Linux) for the optional
keychain backend. The real-debugger feature also requires
[nvim-dap](https://github.com/mfussenegger/nvim-dap) plus a per-language debug
adapter (optional; see [Debug mode (real debugger)](#debug-mode-real-debugger)).

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

`agent_core` exposes `get_brief_prompt()`, `get_mode_prompt()`,
`get_context_prompt()`, `get_workspace_prompt()`, `get_rules_prompt()`,
`get_notepad_prompt()`, `get_skills_prompt()`, and `get_memory_prompt()` for the
system prompt, plus the active persona via `vim.g.agent_persona`.
`get_custom_tools()` returns **every** agent_core custom tool (run_agent, web,
github, plan, debug, checkpoint, bugbot, memory, skills, rules, ask, browser),
each already wrapped by lifecycle hooks, so wiring is one loop.
A minimal `avante.nvim` integration:

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
      for _, fn in ipairs({ "get_mode_prompt", "get_brief_prompt", "get_context_prompt",
                            "get_rules_prompt", "get_workspace_prompt", "get_notepad_prompt",
                            "get_skills_prompt", "get_memory_prompt" }) do
        local ok2, text = pcall(core[fn])
        if ok2 and text and text ~= "" then
          table.insert(parts, text)
        end
      end
    end
    return table.concat(parts, "\n\n")
  end,
  custom_tools = function()
    local tools = {}
    -- ... your other custom tools (e.g. mcphub's mcp_tool) ...
    local ok, core = pcall(require, "agent_core")
    if ok and core.get_custom_tools then
      for _, t in ipairs(core.get_custom_tools()) do
        table.insert(tools, t)
      end
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
| `:AgentNotepad` | `<leader>an` | Open a notepad (picker) |
| `:AgentNotepadNew` | — | Create a new notepad |
| `:AgentNotepadEdit` | — | Edit a notepad (picker) |
| `:AgentNotepadDelete` | — | Delete a notepad (picker) |
| `:AgentBestOfN` | `<leader>ab` | Compare a prompt across multiple agent profiles |
| `:AgentPlanBuild` | `<leader>aB` | Build (implement) the current/latest plan in agent mode |
| `:AgentPlanBuildNew` | — | Build the current/latest plan in a fresh agent session |
| `:AgentCheckpoint` | `<leader>ac` | Snapshot the working tree (git patch checkpoint) |
| `:AgentRollback` | — | Restore a checkpoint (git apply -R) |
| `:AgentDebugCleanup` | `<leader>ad` | Remove all recorded debug instrumentation |
| `:AgentDebugStart` | `<leader>aD` | Launch a debug session (real debugger via nvim-dap) |
| `:AgentDebugContinue` | — | Resume the debug session |
| `:AgentDebugStepOver` | — | Step over the current line |
| `:AgentDebugStepInto` | — | Step into the current call |
| `:AgentDebugStepOut` | — | Step out of the current function |
| `:AgentDebugStop` | — | Terminate the debug session |
| `:AgentDebugStatus` | — | Show adapters, launch configs, and session state |
| `:AgentPredictEdit` | `<leader>ae` | Predict the next edit (Tab) |
| `:AgentInlineEdit` | `<leader>ak` | Inline edit per instruction |
| `:AgentMentions` | `<leader>a@` | Expand @-mentions into context and show the result |
| `:AgentBugbot` | `<leader>ag` | Local Bugbot: review + optional autofix (`--autofix --base=X`) |
| `:AgentMemory` | `<leader>aM` | Show persistent agent memory |
| `:AgentRun` | `<leader>aR` | Run one prompt headlessly and print the answer |
| `:AgentPolicy` | `<leader>ay` | Show/set the model policy (alias or `knob=value`) |
| `:AgentRegistryList` | — | List every model backend in the registry |
| `:AgentRegistryAdd` | — | Add a remote model backend (`name provider model endpoint [trust]`) |
| `:AgentSetup` | `<leader>aS` | First-run setup wizard: keys, endpoints, policy |
| `:AgentCatalogUpdate` | — | Refresh the model catalog from `config.catalog.url` |
| `:AgentSkills` | — | List discovered agent skills |
| `:AgentSkill` | `<leader>at` | Run a user-invocable skill |
| `:AgentCommands` | — | List the command palette |
| `:AgentCommand` | `<leader>aC` | Run a command from the palette |
| `:AgentImport` | — | Import rules/skills from another IDE (Cursor or VSCode) |
| `:AgentNextLocation` | `<leader>aL` | Jump to the next predicted edit location |
| `:AgentHistory` | `<leader>aH` | List prior agent sessions |
| `:AgentAutomationList` | `<leader>aA` | List scheduled automations |
| `:AgentAutomationAdd` | — | Add a scheduled automation (prompt) |
| `:AgentAutomationRemove` | — | Remove a scheduled automation |
| `:AgentAutomationRun` | — | Run a scheduled automation now |
| `:AgentDiffApply` | `<leader>aa` | Apply the accepted hunks of the open diff |
| `:AgentDiffAccept` | `<leader>aY` | Accept the diff hunk under the caret |
| `:AgentDiffReject` | `<leader>aN` | Reject the diff hunk under the caret |
| `:AgentCoordinatedEdit` | `<leader>aE` | Apply a multi-file coordinated edit from the symbol under the caret |

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
  -- Rules auto-injection: AGENTS.md / CLAUDE.md + .agent_core/rules (project)
  -- and <data>/agent_core/rules (user).
  rules = {
    enabled = true,
    filenames = { "AGENTS.md", "CLAUDE.md" },
    project_rules_dir = ".agent_core/rules",
    user_rules_dir = nil, -- nil = <data>/agent_core/rules
    prompt_max_chars = 8000,
    auto_attach_globs = true, -- inject glob-scoped rules only when they match the active file
  },
  -- Auto context attachment: open buffer window, visual selection, and LSP
  -- diagnostics injected into the system prompt automatically.
  context = {
    enabled = true,
    max_lines = 200,
    max_chars = 6000,
    include_diagnostics = true,
    include_selection = true,
    include_buffer = true,
  },
  -- Agent skills: reusable SKILL.md procedures (project + user), indexed by
  -- metadata only; the model reads a skill's body on demand with read_skill.
  skills = {
    enabled = true,
    project_dir = ".agent_core/skills",
    user_dir = nil,       -- nil = <data>/agent_core/skills
    prompt_max_chars = 4000,
  },
  -- Command palette: curated shell commands (one file per command) invoked via
  -- the constrained run_command tool instead of free-form bash.
  commands = {
    enabled = true,
    project_dir = ".agent_core/commands",
    user_dir = nil,       -- nil = <data>/agent_core/commands
    prompt_max_chars = 3000,
  },
  -- Ask-the-user clarifying-questions tool.
  ask = {
    enabled = true,
  },
  -- Session history resume (lists/loads prior avante sessions).
  history = {
    enabled = true,
    dir = nil,            -- nil = avante history dir (probed) or <data>/agent_core/history
  },
  -- Scheduled/recurring headless agents.
  automation = {
    enabled = true,
    path = nil,           -- nil = <data>/agent_core/automations.json
  },
  -- Headless browser control (open / screenshot / snapshot).
  browser = {
    enabled = true,
    bin = nil,            -- nil = auto-detect (npx playwright, else chrome/edge/chromium)
  },
  -- Notepads: persistent user-authored markdown notes (title index injected).
  notepad = {
    dir = nil,               -- nil = <data>/agent_core/notepads
    prompt_max_chars = 3000,
  },
  -- Best-of-n: fan one prompt out to N profiles and compare their outputs.
  bestofn = {
    profiles = nil,          -- nil = every profile with autoswitch ~= false
    timeout_ms = 60000,
  },
  -- Plan mode: Markdown plan artifact + Build step.
  plan = {
    dir = ".agent_core/plans", -- where create_plan writes Markdown plans
    build_switch_mode = true, -- :AgentPlanBuild switches to agent mode first
  },
  -- Debug mode: runtime evidence channel.
  debug = {
    log_file = nil,          -- optional path the model can read for captured logs
    log_cmd = nil,           -- optional shell command whose output is captured
  },
  -- Real debugger (nvim-dap bridge): the AI drives breakpoints, stepping,
  -- stack/scope/variable inspection, and expression evaluation directly.
  dap = {
    timeout_ms = 15000,      -- max wait for a stop/terminate event before a tool returns
    max_frames = 20,         -- cap on stack frames returned per stop
    max_variables = 100,     -- cap on variables returned per scope
    max_output_chars = 4000, -- cap on captured debug-console output
  },
  -- Agent mode: non-intrusive git patch checkpoints.
  checkpoint = {
    dir = nil,               -- nil = <data>/agent_core/checkpoints
  },
  -- Tab autocomplete: FIM insert (blink.cmp source) + predictive edits.
  completion = {
    enabled = true,
    provider = "ollama",     -- "ollama" (FIM) or a profile provider name
    fim_model = "qwen2.5-coder:7b-instruct",
    edit_model = nil,        -- predictive-edit model; nil = active profile
    edit_profile = nil,      -- predictive-edit profile; nil = active profile
    ollama_endpoint = nil,   -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
    backends = nil,          -- nil = derive FIM backends from ollama discovery
    max_tokens = 64,
    debounce_ms = 150,
    context_chars = 4096,
    edit_context_lines = 60,
    recent_edits = 5,
    ghost_text = {
      enabled = true,       -- streaming FIM as inline ghost text (Tab)
      accept_key = "<C-l>", -- insert-mode key to accept the ghost text
    },
  },
  -- Unified model registry: trust tiers + role/value tags for every backend.
  registry = {
    path = nil,              -- nil = <data>/agent_core/registry.json
    ollama_endpoint = nil,   -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
    ollama_endpoints = nil,  -- extra remote Ollama endpoints (loopback always included)
    setup_path = nil,        -- nil = <data>/agent_core/setup.json
    auto_discover = true,    -- include `ollama list` results in the registry
  },
  -- Model-selection policy: three orthogonal knobs + aliases.
  policy = {
    model_policy = "balanced", -- balanced | fast | good | cheap
    trust_scope = "any",       -- any | private | local
    caution = "act_first",     -- act_first | ask_first
  },
  -- Curated model catalog: non-derivable metadata (cost/quality/authoritative
  -- flags) shipped as data and refreshable from a pinned URL.
  catalog = {
    url = nil,              -- nil = no fetch (bundled snapshot only)
    path = nil,             -- nil = <data>/agent_core/catalog.json
    auto_refresh = false,
  },
  -- First-run setup wizard (:AgentSetup).
  setup = {
    auto_prompt = true,     -- offer :AgentSetup on first load when unconfigured
    bootstrap = true,       -- run the optional AI suggestion after save
    bootstrap_profile = nil, -- nil = first keyed cloud profile, else local Ollama
  },
  -- Local Bugbot: review the working tree/branch and optionally autofix.
  bugbot = {
    base = "main",
    autofix = false,
    review_profile = nil,
    max_chunk_chars = 20000,
    max_subagents = 4,
    timeout_ms = 300000,
  },
  -- Persistent agent-written memory (learn across runs).
  memory = {
    path = nil,              -- nil = <data>/agent_core/memory.json
    prompt_max_chars = 2000,
  },
  -- Image generation (best-effort, configurable OpenAI-compatible endpoint) and
  -- vision input (read_image tool).
  image = {
    endpoint = "https://api.openai.com/v1/images/generations",
    model = "dall-e-3",
    api_key_name = "OPENAI_API_KEY",
    vision_profile = nil,      -- vision (image input) profile; nil = auto-detect
    vision_model = nil,        -- override model for vision calls; nil = profile's model
    max_image_bytes = 10 * 1024 * 1024, -- refuse to encode larger images
  },
  -- Shared diff UX (per-hunk accept/reject) for every agent edit.
  diff = {
    enabled = true,
    auto_checkpoint = true,    -- checkpoint before applying an edit
  },
  -- Multi-file coordinated edits (cross-file context + structured apply).
  edits = {
    enabled = true,
    edit_profile = nil,        -- profile for edit requests; nil = active profile
    edit_model = nil,          -- override model; nil = profile's model
    max_files = 8,             -- max files to include as context
    max_chars = 20000,         -- max context characters to send
    context_files = 5,         -- max grep-matched files (beyond the current file)
  },
  -- Headless scriptable runner (local SDK / Automations parity).
  runner = {
    timeout_ms = 120000,
  },
  -- Agent lifecycle hooks (Lua callbacks + User autocmds).
  hooks = {
    before_prompt = nil,     -- fun(data: { input: string })
    after_prompt = nil,
    before_tool = nil,       -- fun(data: { name: string, input: table })
    after_tool = nil,        -- fun(data: { name: string, error: string|nil })
    on_run_end = nil,        -- fun(data: table)
  },
  -- Tools treated as destructive: never auto-approved in full modes.
  destructive_tools = {
    "bash", "rollback", "checkpoint", "create_pr", "commit", "push", "bugbot",
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
| `plan`     | yes       | n/a                     | research + write a Markdown plan, then stop |
| `agent`    | no        | all except destructive  | autonomous build/edit + checkpoints |
| `debug`    | no        | all except destructive  | real debugger first (breakpoints/stepping) → instrumentation fallback |
| `multi-task` | no      | all except destructive  | parallel fan-out orchestration |

Read-only modes keep avante's read/search tools but disable every mutating
tool (`bash`, `create`, `edit_file`, `insert`, `replace_in_file`, `str_replace`,
`undo_edit`, `write_to_file`, `write_todos`, and the `run_agent` / plan / debug /
checkpoint custom tools), matching ask/plan behavior. A mode can
whitelist specific write tools via `allow_tools` (e.g. `plan` allow-lists
`create_plan`, `update_plan`, and `write_todos` so it can produce its artifact
without editing code); `M.switch` computes
`disabled = WRITE_TOOLS - allow_tools`.

The auto-approve list for full modes is computed dynamically as
`(all tools) - destructive_tools`, so it stays in sync as avante adds tools.
`bash` can still be destructive; move it into `destructive_tools` if you want
prompts for it. Set `auto_approve = "all"` on a mode to auto-approve everything.

The active mode is persisted and restored on startup (once avante is loaded).
Pass your own `modes` table to `setup()` to override the defaults. You can also
**add custom modes** without replacing the built-ins: set `modes.extra = { ... }`
or write `<data>/agent_core/modes.json` (an array, or `{ "modes": [...] }`).
A custom mode is the same shape as a built-in — `name`, `label`, `read_only`,
`system_prompt`, optional `keywords` / `when_to_use` / `allow_tools` — and
appears in `:AgentMode` and mode recommendation like any built-in.

## Plan mode (Markdown artifact + Build)

Plan mode produces a reviewable plan you approve before any code
changes. `agent_core.plan` mirrors this with two custom tools and two commands:

- `create_plan(title, content)` — writes a Markdown plan to `config.plan.dir`
  (default `.agent_core/plans/`) as `<slug>-<date>.md`. The `plan` persona instructs
  the model to research, ask clarifying questions and wait, then write the plan
  with exact file paths, an ordered `- [ ]` TODO checklist, and trade-offs —
  and then **stop** (no code edits).
- `update_plan(content[, path])` — rewrite the current plan in place.
- `:AgentPlanBuild [path]` (`<leader>aB`) — switch to `agent` mode and submit the
  plan content as the prompt ("Build").
- `:AgentPlanBuildNew [path]` — the same, but opens a fresh avante session
  (`new_chat = true`), best-effort "Build in New Agent".

`plan` mode is read-only for repo code, but `allow_tools` whitelists its own
plan/todo tools so the artifact can be written.

## Debug mode (instrumentation loop + cleanup)

Debug mode instruments the failing path, asks you to reproduce, reads
the resulting logs, fixes the root cause, then removes the scaffolding.
`agent_core.debug` provides the same loop with four custom tools:

- `add_debug_instrumentation(file, text)` — record the exact snippet the model
  just inserted, into `<data>/agent_core/debug/<root>.json` (data dir only, so
  it is safe in every mode).
- `request_reproduction(steps)` — signal instrumentation is complete; the
  persona tells the model to call it and **stop**, so you can reproduce and
  paste the output.
- `read_captured_logs` — tail `config.debug.log_file` and/or run
  `config.debug.log_cmd` so the model fetches runtime evidence itself after
  reproduction, without waiting for you to paste.
- `remove_debug_instrumentation` — delete every recorded snippet by exact text
  match (idempotent; the real fix is a separate edit, so cleanup never deletes
  it). `:AgentDebugCleanup` (`<leader>ad`) runs the same cleanup manually.

The `debug` persona walks the 6-step loop: (1) generate multiple hypotheses,
(2) add instrumentation, (3) request reproduction and wait, (4) analyze the
returned output, (5) make a focused fix, (6) verify and remove instrumentation.

A runtime-evidence channel is used instead of a long-running daemon; nvim uses chat plus
`config.debug.log_file` / `log_cmd` (read via the `read_captured_logs` tool) for
captured logs — same loop, no long-running daemon.

## Debug mode (real debugger)

On top of the instrumentation loop above, `agent_core.dap` adds a genuine
interactive debugger the AI drives end-to-end — the closest thing to an injected
"paused at `file:line`" event without forking avante. It is a thin,
adapter-agnostic controller over
[nvim-dap](https://github.com/mfussenegger/nvim-dap): it only speaks nvim-dap's
generic API, so **every** DAP adapter is supported with no per-language code in
agent_core.

The model drives the debugger through these custom tools (all wired via
`get_custom_tools()`):

| Tool | What it does |
|------|--------------|
| `debug_list_adapters` | List registered adapters + launch configs for the buffer |
| `debug_start` | Launch by config name or inline config; optional breakpoints; blocks until first stop |
| `debug_set_breakpoint` | Set a breakpoint at `file:line` (condition / logpoint / hit count) |
| `debug_clear_breakpoint` | Clear one breakpoint or all |
| `debug_continue` | Resume; blocks until the next stop or termination |
| `debug_step_over` / `debug_step_into` / `debug_step_out` | Step; block until the stop and return the new state |
| `debug_pause` | Interrupt a running process |
| `debug_get_state` | Non-blocking snapshot of the last stop + debug-console output |
| `debug_get_variables` | Expand a `variablesReference` into child variables |
| `debug_evaluate` | Evaluate an expression in the paused frame |
| `debug_stop` / `debug_restart` | Terminate / restart the session |

The blocking tools (`debug_start`, `debug_continue`, `debug_step_*`,
`debug_restart`) issue the DAP command and **hold** their `on_complete` until
the debugger actually stops, then return the full paused state (source line,
stack frames, scopes, locals, and captured console output). Because avante feeds
a `tool_result` straight back into the conversation, this is event-identical to
an injected "paused" message — no avante rewrite required. The tools stay
out of `destructive_tools`, so the debug loop runs uninterrupted in full modes.

The `debug` mode persona now **prefers the real debugger** when an adapter is
available for the language (discovered via `debug_list_adapters`): set
breakpoints at hypotheses, launch, step, inspect, evaluate, find the root cause,
and apply a minimal fix. When no adapter fits (hard-to-attach or non-DAP
scenarios like timing/network/async races), it falls back to the instrumentation
loop in the previous section.

`nvim-dap` is **soft-required**: without it (or a debug adapter) the tools return
a clear error and the instrumentation loop remains the fallback. Installing
`nvim-dap` and the per-language adapters is user-side; agent_core supplies only
the AI-facing controller.

### Adapter install (user config)

agent_core.dap is adapter-agnostic. Install `nvim-dap` plus the adapter for each
language you want to debug:

| Language | Adapter plugin | Debug adapter binary |
|----------|----------------|----------------------|
| Go | `nvim-dap-go` | [delve](https://github.com/go-delve/delve) |
| Python | `nvim-dap-python` | [debugpy](https://github.com/microsoft/debugpy) (`pip install debugpy`) |
| JS/Node | `nvim-dap` + mason | [vscode-js-debug](https://github.com/microsoft/vscode-js-debug) |
| Rust / C / C++ | `nvim-dap` + mason | [codelldb](https://github.com/vadimcn/codelldb) |
| Java | `nvim-jdtls` + `nvim-dap` | [java-debug](https://github.com/microsoft/java-debug) |
| C# / .NET | `nvim-dap` + mason | [netcoredbg](https://github.com/Samsung/netcoredbg) |
| Lua (Neovim) | `nvim-dap` | [one-small-step-for-vimkind](https://github.com/jbyuki/one-small-step-for-vimkind) |

### Sample launch configs

Define `dap.configurations` per filetype in your config (these are read by
`debug_list_adapters` and `debug_start`):

```lua
local dap = require("dap")
dap.configurations.go = {
  {
    type = "go",
    name = "Debug file",
    request = "launch",
    program = "${file}",
  },
}
dap.configurations.python = {
  {
    type = "python",
    name = "Launch file",
    request = "launch",
    program = "${file}",
    console = "integratedTerminal",
  },
}
dap.configurations.javascript = {
  {
    type = "pwa-node",
    name = "Launch file",
    request = "launch",
    program = "${file}",
    cwd = "${workspaceFolder}",
  },
}
```

Commands: `:AgentDebugStart [config]` (`<leader>aD`) launches a session (by
config name, or the default for the filetype); `:AgentDebugContinue`,
`:AgentDebugStepOver`, `:AgentDebugStepInto`, `:AgentDebugStepOut`, and
`:AgentDebugStop` drive it manually; `:AgentDebugStatus` prints the registered
adapters, launch configs, and the latest paused state.

## Checkpoints (Agent mode)

Agent mode supports checkpoints so a bad change can be reverted.
`agent_core.checkpoint` mirrors this without commits or stash:

- `checkpoint` tool / `:AgentCheckpoint [label]` (`<leader>ac`) — snapshot the
  working tree to `<data>/agent_core/checkpoints/<label>.patch` via
  `git diff --binary` (tracked changes) plus a sidecar `<label>.untracked.json`
  manifest of any untracked files, so rollback also removes files created after
  the snapshot and restores files that existed at snapshot time.
- `rollback` tool / `:AgentRollback [label]` — reverse the recorded patch with
  `git apply -R`, then restore/remove untracked files from the manifest (a
  picker lists snapshots when no label is given).

The `agent` persona reminds the model to checkpoint before large or risky
changes.

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
  changes the process cwd, so worktrees are **sequential-only**: a second
  worktree run is rejected while one is active. Use the default shared tree for
  parallel fan-out and `worktree = true` only for a single isolated task.

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

## Web access

`agent_core.web` exposes two read-only avante custom tools (wire them into
`custom_tools`, see the wiring example above):

- `web_fetch` — retrieve an http(s) URL and return readable plain text
  (HTML tags stripped). Use it to read documentation or web pages.
- `web_search` — best-effort DuckDuckGo search returning titles, URLs, and
  snippets. Rate-limited/blocked requests degrade gracefully.

Both run through `curl` with a user agent and a hard timeout, and are read-only,
so they are safe to auto-approve in full modes.

## GitHub context

`agent_core.github` exposes a single `github` custom tool that wraps the
[GitHub CLI](https://cli.github.com) (`gh`), plus `git` for commits/push:

- `action = "pr"` + `number` — pull a PR and its comments.
- `action = "issue"` + `number` — pull an issue and its comments.
- `action = "search"` + `query` (+ `search_type` = `prs`/`issues`/`code`/`repos`)
  — search GitHub.
- `action = "create_pr"` + `title` (+ `body`/`base`/`head`) — open a pull request.
- `action = "commit"` + `message` — `git add -A` + `git commit`.
- `action = "comment"` + `number` + `body` — comment on a PR.
- `action = "push"` — push the current branch.

Read actions build an allowlisted `gh` subcommand (never an arbitrary shell
string). Write actions (`create_pr` / `commit` / `push`) are explicit `gh`/`git`
subcommands built from discrete arguments and are added to `destructive_tools`,
so read-only modes cannot invoke them. Requires `gh` on `PATH` and an
authenticated remote (the agent's cwd is normally the repo root).

## Notepads

`agent_core.notepad` stores user-authored markdown notes under
`<data>/agent_core/notepads/` and injects a compact title index via
`get_notepad_prompt()`. The model reads a note's full content on demand, so
notes stay opt-in — attach only what a task needs. Commands: `:AgentNotepad`
(open), `:AgentNotepadNew` (create), `:AgentNotepadEdit`, `:AgentNotepadDelete`,
with keymap `<leader>an`. Notes are plain markdown files (portable and easy to
edit), and only their titles are ever auto-injected — never their content.

## Agent skills

`agent_core.skills` discovers reusable, self-contained procedures stored as
`SKILL.md` files, mirroring the "skills" pattern: a small metadata frontmatter
(`name`, `description`, `argument-hint`, `user-invocable`) plus a markdown body
of step-by-step instructions. Skills live under `.agent_core/skills/<name>/SKILL.md`
(project, committed alongside the repo) and `<data>/agent_core/skills/<name>/SKILL.md`
(user-global).

Only metadata is auto-injected: `get_skills_prompt()` emits a compact index
(name + description + argument hint) into the system prompt, bounded by
`skills.prompt_max_chars`. The model reads a skill's full body on demand with the
`read_skill` tool (also in `get_custom_tools()`), so skill bodies never bloat the
prompt. `:AgentSkills` lists every discovered skill with its scope and path.

Skills marked `user-invocable: true` are also **user-runnable**: `:AgentSkill`
(`<leader>at`) opens a picker of invocable skills, collects the argument hint,
and shows the invoked body (with `{{args}}` / `{arg}` placeholders substituted)
for review. The `run_skill` tool lets the model do the same.

## Command palette

`agent_core.commands` discovers curated shell commands stored as one file per
command — `.agent_core/commands/<name>.cmd.md` (project, committed) and
`<data>/agent_core/commands/<name>.cmd.md` (user-global) — mirroring the skills
layout. Each file has a small frontmatter (`name`, `description`, `trust`,
`argv`, `args`, `required`) plus an optional markdown body:

```markdown
---
name: run-tests
description: Run the test suite
trust: safe
argv:
  - pytest
  - -q
  - "{{pattern}}"
args:
  - pattern
required:
  - pattern
---
```

The model invokes commands through a single constrained `run_command` tool (in
`get_custom_tools()`): it emits a short command ID plus typed `args` instead of
generating a full free-form command string. The harness builds the `argv` array
deterministically (never shell-interpolated), so commands are cheap,
unambiguous, and injection-safe. `trust: safe` (default) commands are
enumerated in the tool and auto-approved; `trust: dangerous` commands are
excluded and left to the approval-gated `bash` breakout.

Only metadata is auto-injected: `get_commands_prompt()` emits a compact index
(name + description + args) bounded by `commands.prompt_max_chars`.
`:AgentCommands` lists every command; `:AgentCommand` (`<leader>aC`) picks and
runs one interactively.

## Rules auto-injection

`agent_core.rules` aggregates the instruction files agent-style editors honor —
`AGENTS.md` / `CLAUDE.md` at the project root plus
`.agent_core/rules/*.mdc|md` (project) and `<data>/agent_core/rules/*.mdc|md` (user) — into
one bounded system-prompt block via `get_rules_prompt()`, mirroring the rules
hierarchy (project rules first, then user rules). `.mdc` frontmatter is
parsed: `description` and `globs` are surfaced in the injected heading, and
`alwaysApply: false` (or a non-`always` `type`) injects only the rule's metadata
as an on-demand note instead of its full body. Config lives under the
`rules = { ... }` block and is capped by `rules.prompt_max_chars`.

`globs` are honored at attach time: with `rules.auto_attach_globs` on (default),
a rule that carries `globs` is injected in full only when the active file matches
one of them (`**/*.go`, `*.py`, etc.); otherwise it is listed as on-demand. The
`read_rule` tool (in `get_custom_tools()`) reads any rule's full body by label or
file basename when the task actually needs it.

## Import from another IDE

`agent_core.import` migrates an existing third-party IDE setup into
agent_core's neutral directories. It is the only place in the plugin that names
source-IDE on-disk paths, and it is **single-source** (you pick one IDE, not a
combined migration) and **non-destructive** (existing files are never
overwritten):

- **Cursor** — copies `.cursor/rules/*.mdc|md` (project + user),
  `.cursor/skills/*/SKILL.md` (project + user), `CURSOR.md`, and `.cursorrules`
  into `.agent_core/rules` / `.agent_core/skills`, rewriting the root
  instruction files to neutral names (`ide_instructions.md`,
  `legacy_instructions.md`).
- **VSCode** — imports only Copilot instructions
  (`.github/copilot-instructions.md` or `copilot-instructions.md`) as
  `.agent_core/rules/copilot_instructions.md`.

Run `:AgentImport` and pick the source (Snacks picker when available, otherwise
`vim.ui.select`).

## Best-of-n (multi-model comparison)

`agent_core.bestofn` fans one prompt out to N configured profiles and shows their
outputs side-by-side in a read-only scratch buffer, mirroring a best-of-n
comparison. Each profile is queried concurrently with its own provider/model/
API key through avante's own client (a per-run provider copy avoids mutating the
shared provider). `:AgentBestOfN [prompt]` (or `<leader>ab`)
runs the comparison; with no argument it uses the visual selection, then an
input prompt. By default it runs every profile with `autoswitch ~= false`;
override with `config.bestofn.profiles` (a list of names). Set
`config.bestofn.timeout_ms` to bound each model.

## Model registry + policy (model selection)

`agent_core.registry` is the single source of truth for every model backend nvim
can reach. Each entry carries the **role(s)** it serves (`primary` for chat,
`completion`/`edit` for Tab/edits, `classifier` for routing), a **trust tier**
(`local`, `private-remote`, or `third-party-cloud`), and **value tags** (`cost`,
`latency`, `fim`, `reasoning`, `quality_tier`). Local Ollama models are
auto-discovered from `ollama list`; remote backends are declared via
`config.completion.backends` or `:AgentRegistryAdd`.

`agent_core.policy` turns that registry into a selection policy from **three
orthogonal knobs** (no flat presets):

| Knob | Values | Meaning |
|------|--------|---------|
| `model_policy` | `balanced` (default) / `fast` / `good` / `cheap` | the iron triangle: quality vs latency vs cost |
| `trust_scope` | `any` (default) / `private` / `local` | data sovereignty: which trust tiers are allowed |
| `caution` | `act_first` (default) / `ask_first` | mutate directly, or plan/ask + expand destructive tools |

Set them via `config.policy.*`, the `:AgentPolicy` picker, or `:AgentPolicy
model_policy=cheap`. Named **aliases** compose all three knobs at once
(`:AgentPolicy privacy` = `balanced + private + act_first`, `cautious` =
`cheap + local + ask_first`, etc. — see `M.ALIASES`).

Everything else is **derived** from the knobs so they can't drift: the classifier
(`autoswitch`/`recommend` LLM fallback) is disabled when `trust_scope` excludes
cloud or under `cheap`; `destructive_tools` is expanded only by `ask_first`;
`max_tokens` is trimmed under `cheap`; `ask_first` biases plan/ask and `good`
biases plan. Selection order is `role capability → policy filter/weights →
content rank → health`, so a policy can pick *different* models per role (e.g.
`local` scope: local chat model + local FIM model + classifier disabled).

## Model catalog + first-run setup

Pricing and quality are **not derivable** at runtime — no probe returns a
model's per-token cost or benchmark score — so `agent_core.catalog` ships them
as a **curated, versioned catalog** (bundled snapshot) and lets you refresh them
from a pinned URL via `:AgentCatalogUpdate`. Each entry carries `cost_in_per_1m` /
`cost_out_per_1m`, `context_window`, `quality_score` (0..1), authoritative
`fim` / `insert_template` / `reasoning` flags, and a `latency_hint`. The policy
scoring uses these numeric fields directly (with a coarse-string fallback for
unknown user models), so `cheap` / `good` / `fast` are meaningful, not guessed.

The registry augments every declared chat profile with the catalog's numeric
fields and additionally **surfaces catalog-only models** (e.g. GPT-4o, Claude
Haiku) whose key is present in the environment — the deterministic answer to
"what other LLMs should I include". A fetched catalog is **field-allowlisted**:
it can only change non-security fields, never `api_key_name`, `endpoint`,
`trust`, or `name`/`roles`, so a compromised catalog cannot make the wizard read
an unexpected env var or point at a hostile endpoint.

`:AgentSetup` (`<leader>aS`) is the plug-and-play entry point. It detects what
you already have (env keys, keychain/JSON keys, local + remote Ollama via
per-endpoint `/api/tags`), shows a reviewable form of every chat-capable model
(toggleable, greyed when disabled, with derived cost/quality/trust tags),
collects the missing keys, and records remote Ollama endpoints (default trust
`private-remote`; `third-party-cloud` still triggers the one-time warning).
On save it persists the enabled-provider set to
`<data>/agent_core/setup.json` (which **wins** over live env detection so a key
removed from the environment later doesn't silently flip a profile), sets the
default active profile to the first keyed model, and — if `setup.bootstrap` is
on — makes **one** AI call over catalog tags only to suggest
`{ model_policy, trust_scope, caution, default_profile }`, presented as
Apply / Apply with edits / Skip. No AI means a deterministic
`balanced` / `any` / `act_first` fallback, so plug-and-play holds without any
network. On a fresh install with no `setup.json` and no active profile,
`setup.auto_prompt` (headless-safe) offers the wizard on first load.

To add a remote Ollama box (a GPU host over Tailscale/VPN) so it shows up in
the wizard and registry, either run `:AgentRegistryAdd` or list it under
`registry.ollama_endpoints`; discovered models are stamped with their endpoint
and `private-remote` trust automatically.

## Tab autocomplete (Tab parity)

`agent_core.completion` provides three pieces:

- **Ghost text** — a streaming inline suggestion rendered as an extmark
  `virt_text` at the caret, fed token-by-token by a local Ollama FIM model
  (default `qwen2.5-coder:7b-instruct`) via `POST /api/generate` with
  `stream: true`. The suggestion is **syntax-highlighted** via treesitter (per-
  token highlight groups derived from the buffer's filetype, with a dimmed
  fallback when no parser is available). Accept it with
  `config.completion.ghost_text.accept_key` (default `<C-l>`); it clears on
  caret movement or leaving insert mode.
  Note: some editors accept ghost text with Tab, but Tab is normally owned by
  `blink.cmp`, so the default here is `<C-l>` to avoid clobbering completion —
  set `accept_key = "<Tab>"` if you prefer.
- **FIM insert** — a blink.cmp source (`require("agent_core.completion").blink_source()`,
  or `module = "agent_core.completion"` in blink's `providers`) fed the final
  streamed completion as a dropdown fallback. Cloud providers fall back to a
  completion prompt through `agent_core.runner`.
- **Predictive edit** — `:AgentPredictEdit` (`<leader>ae`) predicts the next edit
  with no instruction; `:AgentInlineEdit [instruction]` (`<leader>ak`)
  rewrites a window around the caret per an explicit instruction. Both are
  grounded in the surrounding code, `vim.diagnostic.get()` diagnostics, and a
  buffer-local recent-edit log; they checkpoint first, present the change in the
  shared diff UX (accept/reject hunks), and apply it — `:AgentRollback` undoes
  it.
- **Jump-in-file** — `:AgentNextLocation` (`<leader>aL`) predicts the next edit
  *location* (a line number) and jumps the caret there, the "jump" gesture after
  accepting a predictive edit.

Wire the source in your `blink.cmp` `sources.providers` (see
`avante_blink.lua` in the example config) and set `config.completion.*` to pick
the FIM model and endpoint.

### FIM model requirement (important)

Ollama FIM (`POST /api/generate` with `suffix`) requires the model to ship an
**insert template** containing `{{ .Suffix }}`. Not every "coder" model has one:

- **Works out of the box**: `qwen2.5-coder:*`, `codellama:*`, `starcoder2:*`,
  `codegemma:*`, `deepseek-coder-v2:*`.
- **Does NOT**: base `deepseek-coder:6.7b` / `deepseek-coder:1.3b` (and the
  `-instruct` variants) — they are FIM-*trained*, but Ollama's packaged
  template omits the insert markers, so `suffix` is rejected with
  `"does not support insert"`. `deepseek-r1*` is a reasoning model, not FIM.

To use a local DeepSeek model for Tab, build a FIM-enabled alias (adds the
model's native FIM markers; a no-op for chat):

```bash
cat > Modelfile <<'EOF'
FROM deepseek-coder:1.3b
TEMPLATE """{{- if .Suffix }}<｜fim▁begin｜>{{ .Prompt }}<｜fim▁hole｜>{{ .Suffix }}<｜fim▁end｜>{{- else }}{{ .Prompt }}{{- end }}"""
PARAMETER stop "<｜fim▁begin｜>"
PARAMETER stop "<｜fim▁hole｜>"
PARAMETER stop "<｜fim▁end｜>"
PARAMETER num_ctx 4096
PARAMETER temperature 0.2
EOF
ollama create deepseek-coder-fim:1.3b -f Modelfile
```

### Benchmark (CPU-only Windows host)

Both candidates fill the gap correctly; the small model wins on latency, which
is what ghost text needs:

| model | tok/s | ~10-token ghost latency |
|---|---|---|
| `deepseek-coder-fim:1.3b` | ~27-31 | ~350ms |
| `deepseek-coder-fim:6.7b` | ~7.1 | ~1.4s |

**Recommendation**: on a CPU-only host use a 1.5b-class model
(`deepseek-coder-fim:1.3b` or `qwen2.5-coder:1.5b`); reserve the 6.7b-class for
GPU (a `private-remote` backend) or for larger fills where latency is
tolerable.

### Completion backends + health router

`config.completion.backends` (or the registry's auto-discovered Ollama models)
defines the pool of FIM backends. The policy picks the allowed trust tier
(hard, from `trust_scope`) and the preferred backend (weight, from
`model_policy`); a **health router** then walks candidates in policy order,
picks the first reachable endpoint (`/api/tags` with a short timeout), caches
the result for 30s, and **fails over to local** when the preferred backend is
down/slow. On switch it warms the model (keep-alive) so the first keystroke is
not cold. The router also records a rolling measured round-trip per backend and
stamps `latency_ms`, so the `fast` policy ranks on **observed** latency rather
than the catalog's static `latency_hint`. Example: a private GPU box over VPN
as the preferred backend, with automatic fallback to the local CPU model.

```lua
require("agent_core").setup({
  completion = {
    fim_model = "deepseek-coder-fim:1.3b", -- or qwen2.5-coder:1.5b
    backends = {
      { name = "gpu",   provider = "ollama", model = "deepseek-coder-fim:6.7b",
        endpoint = "http://100.64.0.2:11434", trust = "private-remote",
        fim = true, cost = "free", latency = "low", quality_tier = "high" },
      { name = "local", provider = "ollama", model = "deepseek-coder-fim:1.3b",
        endpoint = "http://127.0.0.1:11434", trust = "local",
        fim = true, cost = "free", latency = "low", quality_tier = "low" },
    },
  },
  policy = { trust_scope = "private" },
})
```

## Diff UX (Composer-style accept/reject)

`agent_core.diff` is the shared diff presenter every agent edit path funnels
through, so predictive edits, inline edits, multi-file coordinated edits, and
bugbot autofix all get the same review UX. It renders old/new lines as
per-hunk chunks and lets you accept or reject each hunk before applying; the
working tree is checkpointed first, so `:AgentRollback` undoes an applied edit
(and a cancelled coordinated edit rolls back automatically).

- `:AgentDiffApply` (`<leader>aa`) — apply the accepted hunks.
- `:AgentDiffAccept` (`<leader>aY`) — accept the hunk under the caret.
- `:AgentDiffReject` (`<leader>aN`) — reject the hunk under the caret.
- In the diff buffer, `a` toggles the hunk under the caret and `q` cancels.

In a headless session (no UI) the presenter auto-accepts every hunk so scripted
callers still get a deterministic apply. Set `config.diff.auto_checkpoint` to
`false` to skip the automatic checkpoint when the caller already created one.

## Multi-file coordinated edits

`agent_core.edits` predicts and applies a coordinated change across several
files at once — the "Tab v2" multi-file gesture. `:AgentCoordinatedEdit`
(`<leader>aE`) starts from the symbol under the caret, gathers cross-file
context (the current file plus up to `edits.context_files` ripgrep-matched
files, bounded by `edits.max_files` / `edits.max_chars`), and asks an
edit-capable profile to return a structured JSON edit set:

```json
[{ "path": "relative/path", "find": "exact existing text", "replace": "replacement" }]
```

Every path is validated to stay inside the repo root (absolute paths and `..`
traversal are rejected) and each `find` must match a literal block in its file.
The harness checkpoints, applies each edit, and presents a combined diff with
accept (keep) / cancel (`:AgentRollback`). Configure the edit model with
`edits.edit_profile` / `edits.edit_model`; `edits.enabled` disables the command.

## Local Bugbot

`agent_core.bugbot` runs a local bug-review agent. `:AgentBugbot [--autofix]
[--base=main]` (`<leader>ag`) captures the working-tree diff (`git diff HEAD`) or
a branch diff (`git diff <base>...HEAD`), fans out to parallel review workers
(single-shot LLM calls over diff chunks), and presents a severity-ranked report
(file/line, explanation, suggestion). With `--autofix`, it applies the fixes in
an isolated new-branch git worktree, shows the worktree diff for review (accept
to commit / reject to abort), then commits, pushes, and opens a PR via
`gh pr create`. All write paths are destructive and gated on `--autofix`. The
`bugbot` custom tool exposes the same review/autofix to the model.

## Agent memory (learn across runs)

`agent_core.memory` is agent-written, persistent memory — distinct from
user-authored Notepads. The `remember` / `recall` / `forget` custom tools let the
model store facts in `<data>/agent_core/memory.json` and recall them in later
runs. `get_memory_prompt()` injects a compact key index (never values) into the
system prompt; the model reads a value on demand. `:AgentMemory` (`<leader>aM`)
opens a read-only view of everything stored.

## Headless runner (local SDK / Automations parity)

`agent_core.runner` runs a single agent headlessly and returns its final answer,
so agents are scriptable from git hooks, cron, or `nvim --headless`:

```lua
require("agent_core").run("Fix the failing test", { mode = "debug" }, function(result)
  print(result.text)
end)
```

`agent_core.run(prompt, { profile=, mode=, model=, on_chunk= }, cb)` resolves a
profile, assembles the same system prompt the interactive agent gets, and streams
through avante's own client. `:AgentRun [prompt]` (`<leader>aR`) runs it
interactively. This is the local analog of a headless SDK runtime and
Automations (which run on a cloud VM).

## Lifecycle hooks

`agent_core.hooks` lets you extend agent_core with your own Lua. Set callbacks
under `config.hooks` (or listen for the matching `User` autocmd):

| Hook           | Autocmd                 | Fires when                                    |
|----------------|-------------------------|-----------------------------------------------|
| `before_prompt`| `AgentHookBeforePrompt` | a prompt is submitted (avante input)          |
| `after_prompt` | `AgentHookAfterPrompt`  | right after submission                        |
| `before_tool`  | `AgentHookBeforeTool`   | an agent_core custom tool runs                |
| `after_tool`   | `AgentHookAfterTool`    | an agent_core custom tool completes           |
| `on_run_end`   | `AgentHookRunEnd`       | a headless run completes                      |

`before/after_tool` wrap agent_core custom tools only (they are wired through
`get_custom_tools()`); avante built-ins (`bash`, `write_to_file`) are not wrapped
without an upstream avante fork.

## @-mentions (local analog of an attach UI)

You can `@`-attach context (codebase, web, docs, git, file, folder, symbol) to a
prompt. avante has no attach hook, so `agent_core.mentions` provides the local
analog: it expands `@codebase <query>` (ripgrep search), `@git <pr|issue> <n>`
(`gh` CLI), `@web <query>` (web_search), `@docs <path>` / `@file <path>` (local
file), `@folder <path>` (recursive file listing), and `@symbol <name>` (LSP
document symbols with a ripgrep fallback) tokens into inline context blocks.
`:AgentMentions [prompt]` (`<leader>a@`) expands the visual selection (or a typed
prompt) and opens the result in a scratch buffer for review;
`require("agent_core.mentions").expand(prompt, cb)` is the programmatic form.

## Image generation + vision

`agent_core.image` exposes two tools:

- `generate_image` — calls a configurable OpenAI-compatible images endpoint and
  returns the image URL(s). Configure `config.image = { endpoint, model,
  api_key_name }` (defaults to OpenAI's DALL-E 3).
- `read_image` — **image input / vision**: reads an image file (relative to the
  project root or absolute), base64-encodes it, and sends it to a
  vision-capable profile for a description or a specific question. Resolve the
  profile explicitly with `config.image.vision_profile`, override just the model
  with `config.image.vision_model`, or let agent_core auto-pick the first
  enabled registry entry tagged `vision` (catalog models like GPT-4o, Claude,
  Gemini, and Ollama vision models such as `llava` / `moondream`). The active
  profile is only used as a last resort when it is itself vision-capable — a
  text-only model (e.g. DeepSeek) is never silently sent an image, and
  `read_image` fails with a clear error instead. Images larger than
  `config.image.max_image_bytes` are refused.

For interactive chat, image input is already handled by avante's own attachment
path: install [img-clip.nvim](https://github.com/HakonHarnes/img-clip.nvim)
(paste/drag-drop an image) and add the `Avante` filetype to
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)
so pasted images render inline. `read_image` is the agent_core bridge for the
agent's own tool calls (headless runner, automations, and custom tools).

## Auto context attachment

`agent_core.context` builds a bounded `## Current context` system-prompt block
from the editor's live state — the active buffer window around the caret, the
current visual selection, and the LSP diagnostics for the buffer — so the agent
sees your current file, selection, and linter errors without any manual
`@`-mention. `get_context_prompt()` is the export to wire into avante's
`system_prompt` (it is already in the wiring example above), and it is bounded
by `context.max_lines` / `context.max_chars`. Each part can be toggled via
`context.include_buffer` / `include_selection` / `include_diagnostics`.

## Ask the user (clarifying questions)

`agent_core.ask` exposes an `ask_user` tool so an agent can ask a clarifying
question mid-task and wait for the answer instead of guessing. The question is
surfaced through `vim.ui.input` and the answer is returned to the model; in a
headless session (no UI) it fails fast with an actionable error so the agent can
proceed with a documented assumption rather than hanging. Enabled by default
(`ask.enabled`).

## Session history (resume)

`agent_core.history` lists and loads prior avante chat sessions so you can
resume them. `:AgentHistory` (`<leader>aH`) opens a scratch buffer listing
session ids; `M.list(dir)` / `M.load(dir, id)` are the programmatic form. The
store is the avante history directory (probed from `avante.history` when
available, else `<data>/agent_core/history`), overridable via `history.dir`.

## Automations (scheduled agents)

`agent_core.automation` persists recurring prompts to
`<data>/agent_core/automations.json` and schedules them with a `vim.uv` timer, so
a prompt can run on an interval (e.g. "every hour") — the local analog of
recurring Automations. Each run goes through `agent_core.runner` (same system
prompt as the interactive agent); the schedule survives restarts by re-arming
from the persisted list on startup.

- `:AgentAutomationAdd [prompt]` — add a prompt (with an optional repeat interval
  in minutes).
- `:AgentAutomationList` (`<leader>aA`) — list scheduled automations.
- `:AgentAutomationRemove` — pick and remove one.
- `:AgentAutomationRun` — pick and run one now.

## Browser control

`agent_core.browser` exposes three headless-browser tools — `browser_open`
(page title + URL), `browser_screenshot` (PNG saved to a path), and
`browser_snapshot` (readable page text). It uses Playwright (`npx playwright`)
when available, else Chrome/Edge/Chromium headless; set `browser.bin` to force a
specific CLI. Tools degrade to an actionable "browser unavailable" message rather
than erroring, and screenshots are written under
`<data>/agent_core/screenshots/` by default.

## Security

- **API keys are resolved env-first**: `profile.api_key` > `os.getenv(api_key_name)`
  > the OS keychain (macOS Keychain via `security`, Linux libsecret via
  `secret-tool`) > `~/.config/nvim/agent_keys.json` (chmod 0600). Windows
  `cmdkey` cannot read secrets back, so Windows stores in the JSON file.
  Prefer setting `DEEPSEEK_API_KEY` / `GEMINI_API_KEY` in a `chmod 600` file
  sourced by your shell. Never put real keys in `profiles.lua` or commit
  `agent_keys.json`.
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

## Testing

The plugin ships a dependency-free unit test harness (`tests/harness.lua`) and a
spec suite covering the pure logic of every module. Run it headlessly:

```bash
nvim --headless -u tests/minimal_init.lua "+lua require('tests.run')"
```

On success it prints `AGENT_CORE_TESTS_OK`; on any failure it exits non-zero.
The same suite runs in the pre-push hook and in GitHub Actions CI (see
[CONTRIBUTING.md](CONTRIBUTING.md) for how to add a spec).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup (Windows and
WSL/nvim), running the checks, and the Conventional Commits style.

## License

[MIT](LICENSE)
