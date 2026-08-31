---@mod agent_core.runtime.config Owned runtime configuration schema.
---@brief [[
--- Owned config schema for the runtime: per-session defaults, Agents Window UI
--- prefs, clipboard/image-input limits, and tool toggles. Profiles, modes, and
--- personas are NOT duplicated here — they stay in agent_core.profiles /
--- agent_core.modes and are resolved at runtime; the runtime only holds the
--- knobs previously buried in the retired runtime's own config.
---
--- `M.merge(user)` deep-merges a user table over the defaults (the same shape
--- agent_core.setup uses), so this is pure and headless-testable.
---@brief ]]

local M = {}

---@type table
M.defaults = {
  -- Per-session agent-loop defaults.
  session = {
    max_iterations = 25,
    temperature = nil, -- nil = provider default
    max_tokens = nil, -- nil = provider default
    timeout_ms = 120000,
  },
  -- Agents Window + IDE layout preferences.
  ui = {
    enabled = true,
    border = "rounded",
    max_panes = 9,
    indicator = true, -- show the per-pane model indicator
    ide_layout = true, -- split-based Cursor IDE panes (vs floating workspace)
    chat_width = 38, -- columns for the chat message column
    agents_width = 28, -- columns for the far-right Agents sidebar
    composer_height = 6, -- rows for the composer split
    auto_open = false, -- open IDE chat layout on startup
    restore_sessions = true, -- reload open chats from the last session
  },
  -- Clipboard / image-input limits.
  clipboard = {
    max_image_bytes = 10 * 1024 * 1024,
    media_type = "image/png",
  },
  -- Owned tool toggles: a table of tool-name -> boolean. When a tool is present
  -- and false, the owned registry omits it from the provider descriptors.
  tools = {},
  -- Context editing + compaction (two thresholds; cheaper compaction model).
  context = {
    soft_threshold = 16000, -- tokens: trigger a summary via the compaction model
    hard_threshold = 32000, -- tokens: force-drop the oldest messages
    keep_last_turns = 2, -- recent turns always kept intact
    compaction_provider = nil, -- cheaper model for the summary (nil = primary)
    compaction_model = nil,
  },
  -- Successive-prompt workflows engine.
  workflows = {
    dir = nil, -- default: <data>/agent_core/workflows
    max_steps = 20,
  },
}

--- Deep-merge a user table over the defaults (defaults are never mutated).
---@param user table|nil
---@return table
function M.merge(user)
  return vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), user or {})
end

--- The owned registry helper: filter a list of normalized tool descriptors by
--- the config.tools toggles. A tool disabled in config.tools is dropped.
---@param descriptors table[]
---@param cfg table
---@return table[]
function M.filter_tools(descriptors, cfg)
  local toggles = cfg and cfg.tools or {}
  local out = {}
  for _, d in ipairs(descriptors or {}) do
    if toggles[d.name] ~= false then
      out[#out + 1] = d
    end
  end
  return out
end

return M
