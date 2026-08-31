---@mod agent_core Agent orchestrator for Neovim
---@brief [[
--- Bundles: agent/key profiles with one-key switching, an indexer that
--- generates a committable project brief (AVANTE.md), and automatic brief
--- refresh on file changes.
---
--- Two-tier context: the brief is always injected into the system prompt
--- (cheap, structural), while semantic/structural retrieval happens on-demand
--- via MCP (ripvec) so the model only pulls deep context when it needs it.
---@brief ]]

local M = {}

require("agent_core.platform") -- ensure OS/binary/path helpers load with the module

--- Defaults. Override with require("agent_core").setup({ ... }).
M.config = {
  -- Filename for the generated project brief (written at the project root).
  brief_filename = "AVANTE.md",
  -- semnav binary (project-scoped semantic graph indexer; resolved via exepath).
  semnav_bin = "semnav",
  -- ripvec MCP binary (native multi-root semantic + BM25 + LSP search).
  ripvec_bin = "ripvec-mcp",
  -- Max characters of the brief injected into the system prompt (token budget).
  brief_prompt_max_chars = 8000,
  -- Debounce (ms) for auto-refreshing the brief after buffer writes.
  refresh_debounce_ms = 5000,
  -- Profiles. nil = defaults; a plain array = full replacement; or
  -- `{ extra = { ... } }` to append custom agents on top of the defaults.
  -- The JSON file `<data>/agent_core/profiles.json` (array, or
  -- `{ profiles = [...] }`) is ALWAYS appended on top of either form.
  profiles = nil,
  -- Modes; nil falls back to agent_core.modes defaults.
  modes = nil,
  -- Mode-realm recommendation: classify each submitted prompt and suggest a
  -- mode switch when the prompt is out of scope for the active mode.
  recommend = {
    enabled = true,
    confidence_threshold = 0.6,
    use_llm_fallback = true,
    min_prompt_length = 8,
  },
  -- Agent autoswitch: classify each submitted prompt against profile strengths
  -- and suggest a provider/model switch when a different profile is a better fit.
  autoswitch = {
    enabled = true,
    confidence_threshold = 0.6,
    use_llm_fallback = true,
    min_prompt_length = 8,
  },
  -- Workspace registry: multiple project roots so the agent can search and
  -- reason across every registered project (multi-root MCP indexing).
  workspace = {
    enabled = true,
    registry_dir = nil, -- nil = <data>/agent_core/workspace.json
    scan_parent = nil, -- optional parent dir auto-scanned for git repos
    prompt_max_chars = 6000,
    auto_index_on_add = true,
    auto_index_on_scan = true,
  },
  -- Rules auto-injection: aggregate AGENTS.md / CLAUDE.md plus
  -- .agent_core/rules/*.mdc (project) and <data>/agent_core/rules/*.mdc (user)
  -- into the system prompt. Bounded by prompt_max_chars.
  rules = {
    enabled = true,
    filenames = { "AGENTS.md", "CLAUDE.md" },
    project_rules_dir = ".agent_core/rules",
    user_rules_dir = nil, -- nil = <data>/agent_core/rules
    prompt_max_chars = 8000,
    auto_attach_globs = true, -- inject glob-scoped rules only when they match the active file
  },
  -- Auto context attachment: open buffer window, visual selection, and LSP
  -- diagnostics injected into the system prompt automatically. NOTE: this is
  -- *attach* context, unrelated to `runtime.context` (conversation compaction).
  context = {
    enabled = true,
    max_lines = 200,
    max_chars = 6000,
    include_diagnostics = true,
    include_selection = true,
    include_buffer = true,
  },
  -- Notepads: persistent user-authored markdown notes injected as a title
  -- index (Notepads). Full content is read on demand.
  notepad = {
    dir = nil, -- nil = <data>/agent_core/notepads
    prompt_max_chars = 3000,
  },
  -- Best-of-n: fan one prompt out to N profiles and compare their outputs.
  bestofn = {
    profiles = nil, -- nil = every profile with autoswitch ~= false
    timeout_ms = 60000,
  },
  -- Plan mode: Markdown plan artifact + Build step.
  plan = {
    dir = ".agent_core/plans", -- where create_plan writes Markdown plans
    build_switch_mode = true, -- :AgentPlanBuild switches to agent mode first
    ideas_file = nil, -- nil = .agent_core/plan_ideas.json (project-scoped idea backlog)
    remind = {
      enabled = true, -- master switch (startup popup + persistent badge)
      startup_popup = true, -- vim.notify once per session when items are outstanding
      indicator = true, -- persistent, collapsible floating badge
    },
  },
  -- Debug mode: instrumentation loop. Runtime evidence reaches the model via
  -- chat plus an optional log file/command (runtime-evidence channel).
  debug = {
    log_file = nil, -- optional path the model can read for captured logs
    log_cmd = nil, -- optional shell command whose output is captured as logs
  },
  -- Real debugger (nvim-dap bridge): the AI drives breakpoints, stepping,
  -- stack/scope/variable inspection, and expression evaluation directly.
  dap = {
    timeout_ms = 15000, -- max wait for a stop/terminate event before a tool returns
    max_frames = 20, -- cap on stack frames returned per stop
    max_variables = 100, -- cap on variables returned per scope
    max_output_chars = 4000, -- cap on captured debug-console output
  },
  -- Agent mode: non-intrusive git patch checkpoints.
  checkpoint = {
    dir = nil, -- nil = <data>/agent_core/checkpoints
  },
  -- Per-session edit journal: keep = lock in a turn, discard = revert the
  -- un-kept turns (Cursor-style per-turn Keep / Undo All).
  session_edits = {
    enabled = true,
    dir = nil, -- nil = <data>/agent_core/session_edits
  },
  -- Tab autocomplete: FIM insert (blink.cmp source) + predictive edits.
  completion = {
    enabled = true,
    provider = "ollama", -- "ollama" (FIM) or a profile provider name
    fim_model = "qwen2.5-coder:7b-instruct",
    edit_model = nil, -- predictive-edit model; nil = active profile
    edit_profile = nil, -- predictive-edit profile; nil = active profile
    ollama_endpoint = nil, -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
    backends = nil, -- nil = derive FIM backends from ollama discovery + legacy fallback
    max_tokens = 64,
    debounce_ms = 150,
    context_chars = 4096,
    edit_context_lines = 60,
    recent_edits = 5,
    ghost_text = {
      enabled = true, -- render streaming FIM as inline ghost text (Tab)
      accept_key = "<C-l>", -- insert-mode key to accept the ghost text
    },
  },
  -- Unified model registry: trust tiers + role/value tags for every backend.
  registry = {
    path = nil, -- nil = <data>/agent_core/registry.json
    ollama_endpoint = nil, -- nil = $OLLAMA_HOST or http://127.0.0.1:11434
    auto_discover = true, -- include `ollama list` results in the registry
  },
  -- Model-selection policy: three orthogonal knobs + aliases.
  policy = {
    model_policy = "balanced", -- balanced (= all three) | good | fast | cheap | {good,fast} (1-3 axes, min 1)
    trust_scope = "any", -- any | private | local
    caution = "act_first", -- act_first | ask_first
  },
  -- Curated model catalog: non-derivable metadata (cost/quality/authoritative
  -- flags) shipped as data and refreshable from a pinned URL.
  catalog = {
    url = nil, -- nil = no fetch (bundled snapshot only)
    path = nil, -- nil = <data>/agent_core/catalog.json
    auto_refresh = false,
  },
  -- First-run setup wizard (:AgentSetup).
  setup = {
    auto_prompt = true, -- offer :AgentSetup on first load when unconfigured
    bootstrap = false, -- run the optional AI suggestion after save (opt-in)
    bootstrap_profile = nil, -- nil = first keyed cloud profile, else local Ollama
  },
  -- Reusable skills: SKILL.md procedures (project + user), injected as a
  -- compact metadata index and read on demand via the `read_skill` tool.
  skills = {
    enabled = true,
    project_dir = ".agent_core/skills",
    user_dir = nil, -- nil = <data>/agent_core/skills
    prompt_max_chars = 4000,
  },
  -- Declarative command palette: curated shell commands (one file per command)
  -- invoked via the constrained `run_command` tool instead of free-form bash.
  commands = {
    enabled = true,
    project_dir = ".agent_core/commands",
    user_dir = nil, -- nil = <data>/agent_core/commands
    prompt_max_chars = 3000,
  },
  -- Ask-the-user clarifying-questions tool.
  ask = {
    enabled = true,
  },
  -- Session history resume (lists/loads prior sessions via the owned runtime
  -- history store; each record holds its own title + provider + model).
  history = {
    enabled = true,
    dir = nil, -- nil = <data>/agent_core/history
  },
  -- Scheduled/recurring headless agents.
  automation = {
    enabled = true,
    path = nil, -- nil = <data>/agent_core/automations.json
  },
  -- Headless browser control (open / screenshot / snapshot).
  browser = {
    enabled = true,
    bin = nil, -- nil = auto-detect (npx playwright, else chrome/edge/chromium)
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
    path = nil, -- nil = <data>/agent_core/memory.json
    prompt_max_chars = 2000,
  },
  -- Image generation + vision input (best-effort, configurable providers).
  image = {
    endpoint = "https://api.openai.com/v1/images/generations",
    model = "dall-e-3",
    api_key_name = "OPENAI_API_KEY",
    vision_profile = nil, -- vision (image input) profile; nil = auto-detect
    vision_model = nil, -- override model for vision calls; nil = profile's model
    max_image_bytes = 10 * 1024 * 1024,
    paste_guard = "block", -- guard interactive image pastes: "block" | "warn" | "auto_switch" | false
  },
  -- Shared diff UX (per-hunk accept/reject) for agent edits.
  diff = {
    enabled = true,
    auto_checkpoint = true,
  },
  -- Multi-file coordinated edits (cross-file context + structured apply).
  edits = {
    enabled = true,
    max_files = 8,
    max_chars = 20000,
    context_files = 5,
  },
  -- Headless scriptable runner (local SDK / Automations parity).
  runner = {
    timeout_ms = 120000,
  },
  -- Agent lifecycle hooks (Lua callbacks + User autocmds).
  hooks = {
    before_prompt = nil,
    after_prompt = nil,
    before_tool = nil,
    after_tool = nil,
    on_run_end = nil,
  },
  -- Tools treated as destructive: never auto-approved in full modes. The
  -- active mode's auto-approve list is computed as (all tools) - (these).
  destructive_tools = {
    "bash",
    "rollback",
    "checkpoint",
    "create_pr",
    "commit",
    "push",
    "bugbot",
  },
  -- Owned-runtime knobs (session loop, Agents Window UI, clipboard, tool
  -- toggles, context compaction, workflows). nil = agent_core.runtime.config
  -- defaults. NOTE: this `runtime.context` is conversation *compaction*
  -- (thresholds + cheaper summary model); the top-level `context` block above
  -- is *auto context attach* (buffer/selection/diagnostics). Unrelated.
  runtime = nil,
  -- Directories excluded from the brief's file tree.
  excluded_dirs = {
    ".git",
    "node_modules",
    ".venv",
    "venv",
    "__pycache__",
    "target",
    "dist",
    "build",
    ".next",
    ".nuxt",
    "vendor",
    ".ruff_cache",
    ".mypy_cache",
    ".pytest_cache",
  },
}

--- Resolve a prompt from a command's `args` string: use it verbatim, else fall
--- back to the current visual selection, else return "". Shared by the manual
--- recommendation / autoswitch / best-of-n commands.
---@param args string
---@return string
local function resolve_prompt_arg(args)
  local text = args or ""
  if text ~= "" then
    return text
  end
  local ok, start_line, start_col = pcall(vim.fn.getpos, "'<")
  local ok2, end_line, end_col = pcall(vim.fn.getpos, "'>")
  if ok and ok2 then
    local lines = vim.fn.getline(start_line, end_line)
    if #lines > 0 then
      lines[1] = string.sub(lines[1], start_col)
      lines[#lines] = string.sub(lines[#lines], 1, end_col)
      return table.concat(lines, "\n")
    end
  end
  return ""
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  -- WSL: prefer clip.exe before Lazy/plugins touch the clipboard (avoids xclip + DISPLAY=:0).
  local Platform = require("agent_core.platform")
  Platform.ensure_wsl_clipboard()
  require("agent_core.indexer").setup()
  require("agent_core.workspace").setup()
  require("agent_core.mcp_index").setup()
  require("agent_core.catalog").setup()
  require("agent_core.registry").setup()
  require("agent_core.policy").setup()
  require("agent_core.setup").setup()
  require("agent_core.skills").setup()
  require("agent_core.commands").setup()
  require("agent_core.import").setup()
  require("agent_core.context").setup()
  require("agent_core.ask").setup()
  require("agent_core.history").setup()
  require("agent_core.automation").setup()
  require("agent_core.browser").setup()
  require("agent_core.modes").setup()
  require("agent_core.recommend").setup()
  require("agent_core.autoswitch").setup()
  require("agent_core.coordinator").setup()
  require("agent_core.notepad").setup()
  require("agent_core.bestofn").setup()
  require("agent_core.debug").setup()
  require("agent_core.dap").setup()
  require("agent_core.checkpoint").setup()
  require("agent_core.session_edits").setup(M.config.session_edits)
  require("agent_core.completion").setup()
  require("agent_core.bugbot").setup()
  require("agent_core.memory").setup()
  require("agent_core.runner").setup()
  require("agent_core.hooks").setup()
  require("agent_core.image").setup()
  require("agent_core.diff").setup()
  require("agent_core.edits").setup()
  require("agent_core.plan_manager").setup()

  -- Merge owned-runtime knobs (session/ui/clipboard/tools/context/workflows)
  -- from the `runtime` config block into the runtime's schema.
  require("agent_core.runtime").setup(M.config.runtime)

  -- Persist open chat sessions on exit; restore + optional auto-open on startup.
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("AgentCoreSessions", { clear = true }),
    callback = function()
      pcall(function()
        require("agent_core.runtime").persist_open_sessions()
      end)
    end,
  })
  if #vim.api.nvim_list_uis() > 0 then
    local startup_done = false
    local function restore_on_startup()
      if startup_done then
        return
      end
      startup_done = true
      local ok, err = pcall(function()
        local rt = require("agent_core.runtime")
        local ui_cfg = rt.config.ui or {}
        local ide = require("agent_core.runtime.ui.ide")
        if ide.is_open() then
          return
        end
        local restored = rt.restore_sessions()
        if ui_cfg.auto_open or restored > 0 then
          if not rt.active_session() then
            rt.create_session({})
          end
          require("agent_core.runtime.ui").workspace()
        end
      end)
      if not ok then
        vim.notify("[agent_core] session restore failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
    if vim.fn.exists(":Lazy") == 2 then
      vim.api.nvim_create_autocmd("User", {
        pattern = "LazyDone",
        once = true,
        callback = function()
          Platform.ensure_wsl_clipboard()
          vim.defer_fn(restore_on_startup, 100)
        end,
      })
    else
      vim.api.nvim_create_autocmd("VimEnter", {
        once = true,
        callback = function()
          vim.defer_fn(restore_on_startup, 300)
        end,
      })
    end
  end

  vim.api.nvim_create_user_command("AgentSwitch", function(args)
    require("agent_core.profiles").switch_cmd(args.args ~= "" and args.args or nil)
  end, { nargs = "*", desc = "Switch agent/key profile (optionally by name)" })

  vim.api.nvim_create_user_command("AgentModel", function()
    require("agent_core.pickers").pick_model(function(entry)
      if entry then
        require("agent_core.profiles").switch_model(entry)
      end
    end)
  end, { desc = "Switch the active model from the pooled registry" })

  vim.api.nvim_create_user_command("AgentModelClear", function()
    require("agent_core.profiles").clear_model_override()
  end, { desc = "Reset the active model to the profile default" })

  vim.api.nvim_create_user_command("AgentMode", function()
    require("agent_core.pickers").pick_mode(function(mode)
      if mode then
        require("agent_core.modes").switch(mode)
      end
    end)
  end, { desc = "Switch agent mode (ask/plan/debug/agent/multitask)" })

  vim.api.nvim_create_user_command("AgentIndex", function()
    require("agent_core.indexer").refresh({ notify = true })
  end, { desc = "Regenerate the project brief (AVANTE.md)" })

  vim.api.nvim_create_user_command("AgentProfile", function()
    local Profiles = require("agent_core.profiles")
    local active = vim.g.agent_active_profile or Profiles.get_active() or "(none)"
    vim.notify("Agent profile: " .. active, vim.log.levels.INFO)
  end, { desc = "Show the active profile (read-only)" })

  vim.api.nvim_create_user_command("AgentPolicy", function(args)
    require("agent_core.policy").policy_cmd(args.args)
  end, { nargs = "*", desc = "Show or set the agent model policy (alias or knob=value)" })

  vim.api.nvim_create_user_command("AgentRegistryList", function()
    require("agent_core.registry").list_cmd()
  end, { desc = "List every model backend in the registry" })

  vim.api.nvim_create_user_command("AgentRegistryAdd", function(args)
    require("agent_core.registry").add_cmd(args.args)
  end, { nargs = "*", desc = "Add a remote model backend to the registry" })

  vim.api.nvim_create_user_command("AgentSetup", function()
    require("agent_core.setup").setup_cmd()
  end, { desc = "First-run setup wizard: keys, endpoints, policy" })

  vim.api.nvim_create_user_command("AgentSettingsClear", function(args)
    require("agent_core.reset").clear_cmd(args.bang)
  end, { bang = true, desc = "Wipe all agent_core state and API keys (first-install reset)" })

  vim.api.nvim_create_user_command("AgentKey", function(args)
    require("agent_core.keys").cmd(args.bang, args.args)
  end, { nargs = "*", bang = true, desc = "Set (or remove with !) a profile's API key" })

  vim.api.nvim_create_user_command("AgentProfileEnable", function(args)
    require("agent_core.registry").enable_cmd(args.args)
  end, { nargs = "*", desc = "Enable a chat profile (persisted setup override)" })

  vim.api.nvim_create_user_command("AgentProfileDisable", function(args)
    require("agent_core.registry").disable_cmd(args.args)
  end, { nargs = "*", desc = "Disable a chat profile (persisted setup override)" })

  vim.api.nvim_create_user_command("AgentEndpointList", function()
    require("agent_core.registry").endpoint_list_cmd()
  end, { desc = "List Ollama endpoints" })

  vim.api.nvim_create_user_command("AgentEndpointAdd", function(args)
    require("agent_core.registry").endpoint_add_cmd(args.args)
  end, { nargs = "*", desc = "Add a remote Ollama endpoint" })

  vim.api.nvim_create_user_command("AgentEndpointRemove", function(args)
    require("agent_core.registry").endpoint_remove_cmd(args.args)
  end, { nargs = "*", desc = "Remove a remote Ollama endpoint" })

  vim.api.nvim_create_user_command("AgentManager", function()
    require("agent_core.manager").open()
  end, { desc = "Manage profiles, modes, policy, and Ollama endpoints" })

  vim.api.nvim_create_user_command("AgentCatalogUpdate", function()
    require("agent_core.catalog").update_cmd()
  end, { desc = "Refresh the model catalog from config.catalog.url" })

  vim.api.nvim_create_user_command("AgentSkills", function()
    require("agent_core.skills").list_cmd()
  end, { desc = "List discovered agent skills" })

  vim.api.nvim_create_user_command("AgentSkill", function()
    require("agent_core.skills").invoke_cmd()
  end, { desc = "Run a user-invocable agent skill" })

  vim.api.nvim_create_user_command("AgentCommands", function()
    require("agent_core.commands").list_cmd()
  end, { desc = "List the command palette" })

  vim.api.nvim_create_user_command("AgentCommand", function()
    require("agent_core.commands").invoke_cmd()
  end, { desc = "Run a command from the palette" })

  vim.api.nvim_create_user_command("AgentDiffApply", function()
    require("agent_core.diff").apply_cmd()
  end, { desc = "Apply accepted diff hunks" })

  vim.api.nvim_create_user_command("AgentDiffAccept", function()
    require("agent_core.diff").accept_cmd()
  end, { desc = "Accept the diff hunk under the caret" })

  vim.api.nvim_create_user_command("AgentDiffReject", function()
    require("agent_core.diff").reject_cmd()
  end, { desc = "Reject the diff hunk under the caret" })

  vim.api.nvim_create_user_command("AgentCoordinatedEdit", function()
    require("agent_core.edits").coordinated_edit_cmd()
  end, { desc = "Apply a multi-file coordinated edit from the symbol under the caret" })

  vim.api.nvim_create_user_command("AgentImport", function()
    require("agent_core.import").import_cmd()
  end, { desc = "Import rules/skills from another IDE" })

  vim.api.nvim_create_user_command("AgentHistory", function()
    require("agent_core.history").list_cmd()
  end, { desc = "List prior agent sessions" })

  vim.api.nvim_create_user_command("AgentSessionBind", function(args)
    require("agent_core.history").session_bind_cmd(args.args)
  end, { nargs = "*", desc = "Bind the current session to a profile (restored on resume)" })

  vim.api.nvim_create_user_command("AgentRename", function(args)
    require("agent_core.history").rename_cmd(args.args)
  end, { nargs = "*", desc = "Rename the current agent session" })

  vim.api.nvim_create_user_command("AgentFork", function(args)
    require("agent_core.history").fork_cmd(args.args)
  end, { nargs = "*", desc = "Fork the current agent session into a new chat" })

  vim.api.nvim_create_user_command("AgentRewind", function(args)
    require("agent_core.history").rewind_cmd(args.args)
  end, { nargs = "*", desc = "Rewind the current agent session to an earlier message" })

  vim.api.nvim_create_user_command("AgentAutomationList", function()
    require("agent_core.automation").list_cmd()
  end, { desc = "List scheduled automations" })

  vim.api.nvim_create_user_command("AgentAutomationAdd", function(args)
    require("agent_core.automation").add_cmd(args.args)
  end, { nargs = "*", desc = "Add a scheduled automation (prompt)" })

  vim.api.nvim_create_user_command("AgentAutomationRemove", function()
    require("agent_core.automation").remove_cmd()
  end, { desc = "Remove a scheduled automation" })

  vim.api.nvim_create_user_command("AgentAutomationRun", function()
    require("agent_core.automation").run_cmd()
  end, { desc = "Run a scheduled automation now" })

  vim.api.nvim_create_user_command("AgentRecommend", function(args)
    local text = args.args
    if text == "" then
      -- Fall back to the current visual selection, then a prompt input.
      local ok, start_line, start_col = pcall(vim.fn.getpos, "'<")
      local ok2, end_line, end_col = pcall(vim.fn.getpos, "'>")
      if ok and ok2 then
        local lines = vim.fn.getline(start_line, end_line)
        if #lines > 0 then
          lines[1] = string.sub(lines[1], start_col)
          lines[#lines] = string.sub(lines[#lines], 1, end_col)
          text = table.concat(lines, "\n")
        end
      end
    end
    if text == "" then
      vim.ui.input({ prompt = "Agent recommend (prompt): " }, function(input)
        if input and input ~= "" then
          require("agent_core.recommend").recommend_manual(input)
        end
      end)
    else
      require("agent_core.recommend").recommend_manual(text)
    end
  end, { nargs = "*", desc = "Recommend a mode for a prompt" })

  vim.api.nvim_create_user_command("AgentRecommendToggle", function()
    local Rec = require("agent_core.recommend")
    Rec.config.enabled = not Rec.config.enabled
    vim.notify("Agent mode recommendation: " .. (Rec.config.enabled and "enabled" or "disabled"), vim.log.levels.INFO)
  end, { desc = "Toggle mode recommendation on/off" })

  vim.api.nvim_create_user_command("AgentAutoSwitch", function(args)
    local text = args.args
    if text == "" then
      -- Fall back to the current visual selection, then a prompt input.
      local ok, start_line, start_col = pcall(vim.fn.getpos, "'<")
      local ok2, end_line, end_col = pcall(vim.fn.getpos, "'>")
      if ok and ok2 then
        local lines = vim.fn.getline(start_line, end_line)
        if #lines > 0 then
          lines[1] = string.sub(lines[1], start_col)
          lines[#lines] = string.sub(lines[#lines], 1, end_col)
          text = table.concat(lines, "\n")
        end
      end
    end
    if text == "" then
      vim.ui.input({ prompt = "Agent autoswitch (prompt): " }, function(input)
        if input and input ~= "" then
          require("agent_core.autoswitch").autoswitch_manual(input)
        end
      end)
    else
      require("agent_core.autoswitch").autoswitch_manual(text)
    end
  end, { nargs = "*", desc = "Recommend an agent profile for a prompt" })

  vim.api.nvim_create_user_command("AgentAutoSwitchToggle", function()
    local As = require("agent_core.autoswitch")
    As.config.enabled = not As.config.enabled
    vim.notify("Agent autoswitch: " .. (As.config.enabled and "enabled" or "disabled"), vim.log.levels.INFO)
  end, { desc = "Toggle agent autoswitch on/off" })

  vim.api.nvim_create_user_command("AgentWorkspaceAdd", function(args)
    local path = args.args
    if path == "" then
      path = vim.fn.getcwd()
    end
    require("agent_core.workspace").add(path, { notify = true })
  end, { nargs = "*", desc = "Add a project to the workspace registry" })

  vim.api.nvim_create_user_command("AgentWorkspaceRemove", function()
    require("agent_core.workspace").remove()
  end, { desc = "Remove a project from the workspace registry" })

  vim.api.nvim_create_user_command("AgentWorkspaceScan", function(args)
    local parent = args.args
    if parent == "" then
      parent = M.config.workspace.scan_parent or vim.fn.getcwd()
    end
    require("agent_core.workspace").scan(parent, { notify = true })
  end, { nargs = "*", desc = "Scan a folder for git repos and register them" })

  vim.api.nvim_create_user_command("AgentWorkspaceList", function()
    require("agent_core.workspace").list(true)
  end, { desc = "List registered workspace projects" })

  vim.api.nvim_create_user_command("AgentWorkspaceSwitch", function()
    require("agent_core.workspace").switch()
  end, { desc = "Switch to a registered workspace project" })

  vim.api.nvim_create_user_command("AgentNotepad", function()
    require("agent_core.notepad").edit()
  end, { desc = "Open a notepad (picker)" })

  vim.api.nvim_create_user_command("AgentNotepadNew", function()
    require("agent_core.notepad").new()
  end, { desc = "Create a new notepad" })

  vim.api.nvim_create_user_command("AgentNotepadEdit", function()
    require("agent_core.notepad").edit()
  end, { desc = "Edit a notepad (picker)" })

  vim.api.nvim_create_user_command("AgentNotepadDelete", function()
    require("agent_core.notepad").remove()
  end, { desc = "Delete a notepad (picker)" })

  vim.api.nvim_create_user_command("AgentBestOfN", function(args)
    local text = resolve_prompt_arg(args.args)
    if text == "" then
      vim.ui.input({ prompt = "Best-of-n (prompt): " }, function(input)
        if input and input ~= "" then
          require("agent_core.bestofn").bestofn_manual(input)
        end
      end)
    else
      require("agent_core.bestofn").bestofn_manual(text)
    end
  end, { nargs = "*", desc = "Compare a prompt across multiple agent profiles" })

  vim.api.nvim_create_user_command("AgentPlanBuild", function(args)
    require("agent_core.plan").build(args.args ~= "" and args.args or nil, { new_chat = false })
  end, { nargs = "*", desc = "Build (implement) the current/latest plan in agent mode" })

  vim.api.nvim_create_user_command("AgentPlanBuildNew", function(args)
    require("agent_core.plan").build(args.args ~= "" and args.args or nil, { new_chat = true })
  end, { nargs = "*", desc = "Build the current/latest plan in a fresh agent session" })

  vim.api.nvim_create_user_command("AgentPlans", function()
    require("agent_core.plan_manager").open()
  end, { desc = "Open the plan + idea manager" })

  vim.api.nvim_create_user_command("AgentPlanIdea", function(args)
    require("agent_core.plan_manager").add_idea_cmd(args.args ~= "" and args.args or nil)
  end, { nargs = "*", desc = "Add an idea to the plan backlog" })

  vim.api.nvim_create_user_command("AgentPlansToggle", function()
    require("agent_core.plan_manager").toggle()
  end, { desc = "Toggle between the plan manager and the reminder badge" })

  vim.api.nvim_create_user_command("AgentCheckpoint", function(args)
    require("agent_core.checkpoint").checkpoint_cmd(args.args ~= "" and args.args or nil)
  end, { nargs = "*", desc = "Snapshot the working tree (git patch checkpoint)" })

  vim.api.nvim_create_user_command("AgentRollback", function(args)
    require("agent_core.checkpoint").rollback_cmd(args.args ~= "" and args.args or nil)
  end, { nargs = "*", desc = "Restore a checkpoint (git apply -R)" })

  vim.api.nvim_create_user_command("AgentKeep", function()
    require("agent_core.session_edits").keep_cmd()
  end, { desc = "Keep the current turn's edits (advance the discard baseline)" })

  vim.api.nvim_create_user_command("AgentDiscard", function()
    require("agent_core.session_edits").discard_cmd()
  end, { desc = "Discard this chat's edits since the last keep" })

  vim.api.nvim_create_user_command("AgentDebugCleanup", function()
    require("agent_core.debug").cleanup()
  end, { desc = "Remove all recorded debug instrumentation" })

  vim.api.nvim_create_user_command("AgentDebugStart", function(args)
    require("agent_core.dap").start_cmd(args.args)
  end, { nargs = "*", desc = "Launch a debug session (real debugger, nvim-dap)" })

  vim.api.nvim_create_user_command("AgentDebugContinue", function()
    require("agent_core.dap").continue_cmd()
  end, { desc = "Resume the current debug session" })

  vim.api.nvim_create_user_command("AgentDebugStepOver", function()
    require("agent_core.dap").step_over_cmd()
  end, { desc = "Step over (debugger)" })

  vim.api.nvim_create_user_command("AgentDebugStepInto", function()
    require("agent_core.dap").step_into_cmd()
  end, { desc = "Step into (debugger)" })

  vim.api.nvim_create_user_command("AgentDebugStepOut", function()
    require("agent_core.dap").step_out_cmd()
  end, { desc = "Step out (debugger)" })

  vim.api.nvim_create_user_command("AgentDebugStop", function()
    require("agent_core.dap").stop_cmd()
  end, { desc = "Terminate the current debug session" })

  vim.api.nvim_create_user_command("AgentDebugStatus", function()
    require("agent_core.dap").status_cmd()
  end, { desc = "Show debug adapters, configs, and session state" })

  vim.api.nvim_create_user_command("AgentPredictEdit", function()
    require("agent_core.completion").predict_edit_cmd()
  end, { desc = "Predict the next edit (Tab)" })

  vim.api.nvim_create_user_command("AgentInlineEdit", function(args)
    require("agent_core.completion").inline_edit_cmd(args.args)
  end, { nargs = "*", desc = "Inline edit per instruction" })

  vim.api.nvim_create_user_command("AgentNextLocation", function()
    require("agent_core.completion").next_location_cmd()
  end, { desc = "Jump to the next predicted edit location" })

  vim.api.nvim_create_user_command("AgentBugbot", function(args)
    require("agent_core.bugbot").bugbot_cmd(args.args)
  end, { nargs = "*", desc = "Local Bugbot: review + optional autofix (--autofix --base=X)" })

  vim.api.nvim_create_user_command("AgentMemory", function()
    require("agent_core.memory").show()
  end, { desc = "Show persistent agent memory" })

  vim.api.nvim_create_user_command("AgentCheatsheet", function()
    require("agent_core.cheatsheet").open()
  end, { desc = "Show the agent_core command + keymap cheat sheet" })

  vim.api.nvim_create_user_command("AgentRun", function(args)
    require("agent_core.runner").run_cmd(args.args)
  end, { nargs = "*", desc = "Run one prompt headlessly and print the answer" })

  vim.api.nvim_create_user_command("AgentMentions", function(args)
    require("agent_core.mentions").mentions_cmd(args.args)
  end, { nargs = "*", desc = "Expand @-mentions into context and show the result" })

  vim.api.nvim_create_user_command("AgentChat", function(args)
    local rt = require("agent_core.runtime")
    local ui = require("agent_core.runtime.ui")
    if not rt.active_session() then
      rt.create_session({})
    end
    local prompt = args.args
    if prompt and prompt ~= "" then
      rt.submit(prompt, { open = false })
    end
    ui.workspace()
  end, { nargs = "*", desc = "Open the IDE chat layout (optionally submit a prompt)" })

  vim.api.nvim_create_user_command("AgentIde", function()
    require("agent_core.runtime.ui").workspace()
  end, { desc = "Open or refresh the Cursor-style IDE chat layout" })

  vim.api.nvim_create_user_command("AgentIdeClose", function()
    require("agent_core.runtime.ui").close_workspace()
  end, { desc = "Close the IDE chat layout splits" })

  vim.api.nvim_create_user_command("AgentNew", function(args)
    local rt = require("agent_core.runtime")
    local ui = require("agent_core.runtime.ui")
    local prompt = args.args
    if prompt and prompt ~= "" then
      rt.submit(prompt, { new = true, open = false })
      ui.workspace()
    else
      local s = rt.create_session({})
      rt.focus_session(s.id)
      ui.workspace()
    end
  end, { nargs = "*", desc = "Start a fresh chat session" })

  vim.keymap.set("n", "<leader>a ", "<cmd>AgentChat<cr>", { desc = "Open IDE chat layout" })
  vim.keymap.set("n", "<leader>a<Space>", "<cmd>AgentChat<cr>", { desc = "Open IDE chat layout" })
  vim.keymap.set("n", "<leader>a;", "<cmd>AgentIdeClose<cr>", { desc = "Close IDE chat layout" })
  vim.keymap.set("n", "<leader>aT", "<cmd>AgentNew<cr>", { desc = "Start a fresh chat session" })
  vim.keymap.set("n", "<leader>aP", "<cmd>AgentSwitch<cr>", { desc = "Switch agent profile" })
  vim.keymap.set("n", "<leader>aI", "<cmd>AgentIndex<cr>", { desc = "Index project (brief)" })
  vim.keymap.set("n", "<leader>ap", "<cmd>AgentProfile<cr>", { desc = "Show active agent profile" })
  vim.keymap.set("n", "<leader>ay", "<cmd>AgentPolicy<cr>", { desc = "Set agent model policy" })
  vim.keymap.set("n", "<leader>aS", "<cmd>AgentSetup<cr>", { desc = "First-run setup wizard" })
  vim.keymap.set("n", "<leader>am", "<cmd>AgentMode<cr>", { desc = "Switch agent mode" })
  vim.keymap.set("n", "<leader>ao", "<cmd>AgentAutoSwitch<cr>", { desc = "Recommend agent profile for prompt" })
  vim.keymap.set("n", "<leader>aw", "<cmd>AgentWorkspaceList<cr>", { desc = "List workspace projects" })
  vim.keymap.set("n", "<leader>aW", "<cmd>AgentWorkspaceAdd<cr>", { desc = "Add project to workspace" })
  vim.keymap.set("n", "<leader>aj", "<cmd>AgentWorkspaceSwitch<cr>", { desc = "Switch workspace project" })
  vim.keymap.set("n", "<leader>an", "<cmd>AgentNotepad<cr>", { desc = "Open a notepad" })
  vim.keymap.set("n", "<leader>ab", "<cmd>AgentBestOfN<cr>", { desc = "Compare a prompt across profiles" })
  vim.keymap.set("n", "<leader>aB", "<cmd>AgentPlanBuild<cr>", { desc = "Build the current plan" })
  vim.keymap.set("n", "<leader>aq", "<cmd>AgentPlans<cr>", { desc = "Manage plans and ideas" })
  vim.keymap.set("n", "<leader>aQ", "<cmd>AgentPlansToggle<cr>", { desc = "Toggle plan/idea reminder badge" })
  vim.keymap.set("n", "<leader>ac", "<cmd>AgentCheckpoint<cr>", { desc = "Snapshot working tree (checkpoint)" })
  vim.keymap.set("n", "<leader>aK", "<cmd>AgentKeep<cr>", { desc = "Keep current turn's edits" })
  vim.keymap.set("n", "<leader>aX", "<cmd>AgentDiscard<cr>", { desc = "Discard edits since last keep" })
  vim.keymap.set("n", "<leader>ad", "<cmd>AgentDebugCleanup<cr>", { desc = "Remove debug instrumentation" })
  vim.keymap.set("n", "<leader>aD", "<cmd>AgentDebugStart<cr>", { desc = "Launch debug session (real debugger)" })
  vim.keymap.set("n", "<leader>ae", "<cmd>AgentPredictEdit<cr>", { desc = "Predictive edit (Tab)" })
  vim.keymap.set("n", "<leader>ak", "<cmd>AgentInlineEdit<cr>", { desc = "Inline edit per instruction" })
  vim.keymap.set("n", "<leader>a@", "<cmd>AgentMentions<cr>", { desc = "Expand @-mentions into context" })
  vim.keymap.set("n", "<leader>a?", "<cmd>AgentCheatsheet<cr>", { desc = "Show command + keymap cheat sheet" })
  vim.keymap.set("n", "<leader>aR", "<cmd>AgentRun<cr>", { desc = "Run a prompt headlessly" })
  vim.keymap.set("n", "<leader>aM", "<cmd>AgentMemory<cr>", { desc = "Show agent memory" })
  vim.keymap.set("n", "<leader>ag", "<cmd>AgentBugbot<cr>", { desc = "Local Bugbot review" })
  vim.keymap.set("n", "<leader>at", "<cmd>AgentSkill<cr>", { desc = "Run a user-invocable skill" })
  vim.keymap.set("n", "<leader>aC", "<cmd>AgentCommand<cr>", { desc = "Run a command from the palette" })
  vim.keymap.set("n", "<leader>aL", "<cmd>AgentNextLocation<cr>", { desc = "Jump to next predicted edit location" })
  vim.keymap.set("n", "<leader>aH", "<cmd>AgentHistory<cr>", { desc = "List prior agent sessions" })
  vim.keymap.set("n", "<leader>ah", "<cmd>AgentSessionBind<cr>", { desc = "Bind session to a profile" })
  vim.keymap.set("n", "<leader>ar", "<cmd>AgentRename<cr>", { desc = "Rename the current session" })
  vim.keymap.set("n", "<leader>aF", "<cmd>AgentFork<cr>", { desc = "Fork the current session" })
  vim.keymap.set("n", "<leader>aU", "<cmd>AgentRewind<cr>", { desc = "Rewind the current session" })
  vim.keymap.set("n", "<leader>aA", "<cmd>AgentAutomationList<cr>", { desc = "List scheduled automations" })
  vim.keymap.set("n", "<leader>aa", "<cmd>AgentDiffApply<cr>", { desc = "Apply accepted diff hunks" })
  vim.keymap.set("n", "<leader>aY", "<cmd>AgentDiffAccept<cr>", { desc = "Accept diff hunk" })
  vim.keymap.set("n", "<leader>aN", "<cmd>AgentDiffReject<cr>", { desc = "Reject diff hunk" })
  vim.keymap.set("n", "<leader>aE", "<cmd>AgentCoordinatedEdit<cr>", { desc = "Multi-file coordinated edit" })

  -- Reminder startup popup: once per session, nudge about outstanding plans and
  -- undrafted ideas. Headless-guarded (mirrors setup.lua's auto-prompt guard).
  if #vim.api.nvim_list_uis() == 0 then
    return
  end
  local plan_cfg = M.config.plan or {}
  local remind = plan_cfg.remind or {}
  if remind.enabled ~= false and remind.startup_popup ~= false then
    vim.schedule(function()
      local summary = require("agent_core.plan").summary()
      local outstanding = summary.unfinished + summary.ideas
      if outstanding > 0 then
        local parts = {}
        if summary.unfinished > 0 then
          parts[#parts + 1] = string.format("%d unfinished plan%s", summary.unfinished, summary.unfinished == 1 and "" or "s")
        end
        if summary.ideas > 0 then
          parts[#parts + 1] = string.format("%d idea%s", summary.ideas, summary.ideas == 1 and "" or "s")
        end
        vim.notify("agent_core: " .. table.concat(parts, ", ") .. " — :AgentPlans", vim.log.levels.INFO)
      end
    end)
  end
end

--- Returns the project brief text to inject into the system prompt,
--- or "" when no brief exists. Bounded by config.brief_prompt_max_chars.
function M.get_brief_prompt()
  local Indexer = require("agent_core.indexer")
  local path = Indexer.brief_path()
  if not path or vim.fn.filereadable(path) ~= 1 then
    return ""
  end

  local content = table.concat(vim.fn.readfile(path), "\n")
  if #content > M.config.brief_prompt_max_chars then
    content = content:sub(1, M.config.brief_prompt_max_chars) .. "\n\n[... brief truncated ...]"
  end
  return "## Project brief (auto-generated, see " .. M.config.brief_filename .. ")\n\n" .. content
end

--- Returns the active mode persona for the system prompt, or "" when no mode
--- is set. Wire this into the owned runtime's system-prompt assembly alongside get_brief_prompt().
function M.get_mode_prompt()
  return require("agent_core.modes").get_mode_prompt()
end

--- Returns the active profile persona for the system prompt, or "" when none
--- is set. Wire this into build_system_prompt alongside get_mode_prompt().
function M.get_profile_persona()
  return require("agent_core.profiles").get_persona()
end

--- Returns the compact multi-root workspace index for the system prompt, or ""
--- when no projects are registered. Wire this into the owned runtime's system-prompt assembly after
--- get_brief_prompt().
function M.get_workspace_prompt()
  return require("agent_core.workspace").get_workspace_prompt()
end

--- Returns the aggregated project + user rules block for the system prompt, or
--- "" when no rule files exist. Wire this into the owned runtime's system-prompt assembly.
function M.get_rules_prompt()
  return require("agent_core.rules").get_rules_prompt()
end

--- Returns the auto-attached editor context block (open buffer window, visual
--- selection, LSP diagnostics) for the system prompt, or "" when empty.
--- Wire this into the owned runtime's system-prompt assembly.
function M.get_context_prompt()
  return require("agent_core.context").get_context_prompt()
end

--- Returns the compact notepad index (titles only) for the system prompt, or ""
--- when no notes exist. Wire this into the owned runtime's system-prompt assembly.
function M.get_notepad_prompt()
  return require("agent_core.notepad").get_notepad_prompt()
end

--- Returns the compact agent-memory index (keys only) for the system prompt, or
--- "" when no memories exist. Wire this into the owned runtime's system-prompt assembly.
function M.get_memory_prompt()
  return require("agent_core.memory").get_memory_prompt()
end

--- Returns the compact skill index (name + description + argument hint) for the
--- system prompt, or "" when no skills exist. Wire this into the owned runtime's system-prompt assembly.
function M.get_skills_prompt()
  return require("agent_core.skills").get_skills_prompt()
end

--- Returns the compact command-palette index (name + description + args) for the
--- system prompt, or "" when no commands exist. Wire this into the owned
--- runtime's system-prompt assembly.
function M.get_commands_prompt()
  return require("agent_core.commands").get_commands_prompt()
end

--- Returns a short OS/shell/path hint for the system prompt so the model uses
--- the correct shell and path style on Linux, macOS, and Windows.
function M.get_os_hint()
  return require("agent_core.platform").os_hint()
end

--- Run one prompt headlessly and call cb({ text=, error=, profile= }). `opts`
--- may set profile / mode / model / on_chunk. The local analog of a headless
--- SDK runtime and Automations.
---@param prompt string
---@param opts table|nil
---@param cb fun(result: table)
function M.run(prompt, opts, cb)
  require("agent_core.runner").run(prompt, opts, cb)
end

--- Returns every agent_core custom tool, each wrapped by lifecycle hooks, ready
--- to spread into the owned runtime's tool registry (agent_core.runtime.tools).
--- Centralizes wiring so the runtime gets the full tool set from one place.
---@return AgentTool[]
function M.get_custom_tools()
  local hooks = require("agent_core.hooks")
  local tools = {}
  local function add(factory)
    if not factory then
      return
    end
    local ok, tool = pcall(factory)
    if ok and tool then
      tools[#tools + 1] = hooks.wrap(tool)
    end
  end

  local ok_mt, mt = pcall(require, "agent_core.multitask")
  if ok_mt then
    add(mt.run_agent_tool)
  end
  local ok_w, web = pcall(require, "agent_core.web")
  if ok_w then
    add(web.web_fetch_tool)
    add(web.web_search_tool)
  end
  local ok_g, gh = pcall(require, "agent_core.github")
  if ok_g then
    add(gh.github_tool)
  end
  local ok_p, plan = pcall(require, "agent_core.plan")
  if ok_p then
    add(plan.create_plan_tool)
    add(plan.update_plan_tool)
  end
  local ok_d, dbg = pcall(require, "agent_core.debug")
  if ok_d then
    add(dbg.add_debug_instrumentation_tool)
    add(dbg.remove_debug_instrumentation_tool)
    add(dbg.request_reproduction_tool)
    add(dbg.read_captured_logs_tool)
  end
  local ok_dap, dapm = pcall(require, "agent_core.dap")
  if ok_dap then
    add(dapm.debug_list_adapters_tool)
    add(dapm.debug_start_tool)
    add(dapm.debug_set_breakpoint_tool)
    add(dapm.debug_clear_breakpoint_tool)
    add(dapm.debug_continue_tool)
    add(dapm.debug_step_over_tool)
    add(dapm.debug_step_into_tool)
    add(dapm.debug_step_out_tool)
    add(dapm.debug_pause_tool)
    add(dapm.debug_get_state_tool)
    add(dapm.debug_get_variables_tool)
    add(dapm.debug_evaluate_tool)
    add(dapm.debug_stop_tool)
    add(dapm.debug_restart_tool)
  end
  local ok_c, cp = pcall(require, "agent_core.checkpoint")
  if ok_c then
    add(cp.checkpoint_tool)
    add(cp.rollback_tool)
  end
  local ok_b, bb = pcall(require, "agent_core.bugbot")
  if ok_b then
    add(bb.bugbot_tool)
  end
  local ok_m, mem = pcall(require, "agent_core.memory")
  if ok_m then
    add(mem.remember_tool)
    add(mem.recall_tool)
    add(mem.forget_tool)
  end
  local ok_s, sk = pcall(require, "agent_core.skills")
  if ok_s then
    add(sk.read_skill_tool)
    add(sk.run_skill_tool)
  end
  local ok_cmd, commands = pcall(require, "agent_core.commands")
  if ok_cmd then
    add(commands.run_command_tool)
  end
  local ok_r, rl = pcall(require, "agent_core.rules")
  if ok_r then
    add(rl.read_rule_tool)
  end
  local ok_ask, ask = pcall(require, "agent_core.ask")
  if ok_ask then
    add(ask.ask_user_tool)
  end
  local ok_br, br = pcall(require, "agent_core.browser")
  if ok_br then
    add(br.browser_open_tool)
    add(br.browser_screenshot_tool)
    add(br.browser_snapshot_tool)
  end
  local ok_i, img = pcall(require, "agent_core.image")
  if ok_i then
    add(img.generate_image_tool)
    add(img.read_image_tool)
  end
  return tools
end

return M
