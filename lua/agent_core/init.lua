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
  -- Profiles; nil falls back to agent_core.profiles defaults.
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
  -- Tools treated as destructive: never auto-approved in full modes. The
  -- active mode's auto-approve list is computed as (all tools) - (these).
  destructive_tools = {
    "delete_path",
    "move_path",
    "write_global_file",
    "run_python",
    "git_commit",
  },
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

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})

  require("agent_core.indexer").setup()
  require("agent_core.workspace").setup()
  require("agent_core.mcp_index").setup()
  require("agent_core.modes").setup()
  require("agent_core.recommend").setup()
  require("agent_core.autoswitch").setup()
  require("agent_core.coordinator").setup()

  vim.api.nvim_create_user_command("AgentSwitch", function()
    require("agent_core.pickers").pick_profile(function(profile)
      require("agent_core.profiles").switch(profile)
    end)
  end, { desc = "Switch agent/key profile" })

  vim.api.nvim_create_user_command("AgentMode", function()
    require("agent_core.pickers").pick_mode(function(mode)
      require("agent_core.modes").switch(mode)
    end)
  end, { desc = "Switch agent mode (ask/plan/debug/agent/multitask)" })

  vim.api.nvim_create_user_command("AgentIndex", function()
    require("agent_core.indexer").refresh({ notify = true })
  end, { desc = "Regenerate the project brief (AVANTE.md)" })

  vim.api.nvim_create_user_command("AgentProfile", function()
    local Profiles = require("agent_core.profiles")
    local active = vim.g.agent_active_profile or Profiles.get_active() or "(none)"
    vim.notify("Agent profile: " .. active, vim.log.levels.INFO)
  end, { desc = "Show the active agent profile" })

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

  vim.keymap.set("n", "<leader>aP", "<cmd>AgentSwitch<cr>", { desc = "Switch agent profile" })
  vim.keymap.set("n", "<leader>aI", "<cmd>AgentIndex<cr>", { desc = "Index project (brief)" })
  vim.keymap.set("n", "<leader>ap", "<cmd>AgentProfile<cr>", { desc = "Show active agent profile" })
  vim.keymap.set("n", "<leader>am", "<cmd>AgentMode<cr>", { desc = "Switch agent mode" })
  vim.keymap.set("n", "<leader>ao", "<cmd>AgentAutoSwitch<cr>", { desc = "Recommend agent profile for prompt" })
  vim.keymap.set("n", "<leader>aw", "<cmd>AgentWorkspaceList<cr>", { desc = "List workspace projects" })
  vim.keymap.set("n", "<leader>aW", "<cmd>AgentWorkspaceAdd<cr>", { desc = "Add project to workspace" })
  vim.keymap.set("n", "<leader>aj", "<cmd>AgentWorkspaceSwitch<cr>", { desc = "Switch workspace project" })
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
--- is set. Wire this into avante's system_prompt alongside get_brief_prompt().
function M.get_mode_prompt()
  return require("agent_core.modes").get_mode_prompt()
end

--- Returns the compact multi-root workspace index for the system prompt, or ""
--- when no projects are registered. Wire this into avante's system_prompt after
--- get_brief_prompt().
function M.get_workspace_prompt()
  return require("agent_core.workspace").get_workspace_prompt()
end

return M
