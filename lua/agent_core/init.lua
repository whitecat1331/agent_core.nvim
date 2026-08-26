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
  -- Max characters of the brief injected into the system prompt (token budget).
  brief_prompt_max_chars = 8000,
  -- Debounce (ms) for auto-refreshing the brief after buffer writes.
  refresh_debounce_ms = 5000,
  -- Profiles; nil falls back to agent_core.profiles defaults.
  profiles = nil,
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

  vim.api.nvim_create_user_command("AgentSwitch", function()
    require("agent_core.pickers").pick_profile(function(profile)
      require("agent_core.profiles").switch(profile)
    end)
  end, { desc = "Switch agent/key profile" })

  vim.api.nvim_create_user_command("AgentIndex", function()
    require("agent_core.indexer").refresh({ notify = true })
  end, { desc = "Regenerate the project brief (AVANTE.md)" })

  vim.api.nvim_create_user_command("AgentProfile", function()
    local Profiles = require("agent_core.profiles")
    local active = vim.g.agent_active_profile or Profiles.get_active() or "(none)"
    vim.notify("Agent profile: " .. active, vim.log.levels.INFO)
  end, { desc = "Show the active agent profile" })

  vim.keymap.set("n", "<leader>aP", "<cmd>AgentSwitch<cr>", { desc = "Switch agent profile" })
  vim.keymap.set("n", "<leader>aI", "<cmd>AgentIndex<cr>", { desc = "Index project (brief)" })
  vim.keymap.set("n", "<leader>ap", "<cmd>AgentProfile<cr>", { desc = "Show active agent profile" })
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

return M
