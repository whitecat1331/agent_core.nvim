local M = {}

--- Scroll the snacks picker list to the active (`current`) item.
---@param picker table
---@param Snacks table
local function scroll_to_active(picker, Snacks)
  for i, item in ipairs(picker:items()) do
    if item.current then
      picker.list:view(i)
      local actions = Snacks.picker and Snacks.picker.actions
      if actions and actions.list_scroll_center then
        actions.list_scroll_center(picker)
      end
      break
    end
  end
end

--- Build snacks picker items for behavior modes. Pure when `active_name` is passed.
---@param modes table[]
---@param active_name string|nil
---@return table[]
function M.mode_picker_items(modes, active_name)
  local items = {}
  for _, m in ipairs(modes) do
    local is_active = active_name ~= nil and m.name == active_name
    local suffix = is_active and "  [active]" or ""
    items[#items + 1] = {
      text = string.format("%s  |  %s%s", m.label or m.name, m.read_only and "read-only" or "full", suffix),
      mode = m,
      current = is_active,
    }
  end
  return items
end

--- Build snacks picker items for chat models. Pure when `active` is passed.
---@param models table[]
---@param active {provider:string,model:string}|nil
---@return table[]
function M.model_picker_items(models, active)
  local items = {}
  for _, e in ipairs(models) do
    local is_active = active
      and e.provider == active.provider
      and e.model == active.model
    local suffix = is_active and "  [active]" or ""
    items[#items + 1] = {
      text = string.format("%s  |  %s  |  %s%s", e.model or "?", e.provider or "?", e.quality_tier or "?", suffix),
      entry = e,
      current = is_active,
    }
  end
  return items
end

--- Resolve the active provider/model for model picker highlighting.
---@return table|nil
local function active_model_entry()
  local Registry = require("agent_core.registry")
  local am = Registry.active_model()
  if am and am.provider and am.model then
    return am
  end
  local ok, rt = pcall(require, "agent_core.runtime")
  if ok then
    local s = rt.active_session()
    if s and s.provider and s.model then
      return { provider = s.provider, model = s.model }
    end
  end
  return nil
end

--- Open a picker to choose a profile, then invoke `cb(profile)`.
function M.pick_profile(cb)
  local Profiles = require("agent_core.profiles")
  local profiles = Profiles.all()

  local items = {}
  for _, p in ipairs(profiles) do
    table.insert(items, {
      text = string.format("%s  |  %s  |  %s", p.name, p.provider or "?", p.model or "?"),
      profile = p,
    })
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  -- snacks.nvim >=2025 exposes the picker via `pick` (also callable via
  -- `__call`), not a `.picker` field. Guard against both shapes and fall
  -- back to vim.ui.select if the API is unavailable.
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Profile",
      items = items,
      layout = { preview = false },
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.profile then
          cb(item.profile)
        end
      end,
      cancel = function()
        cb(nil)
      end,
    })
    return
  end

  -- Fallback when snacks isn't available.
  local choices = {}
  for _, p in ipairs(profiles) do
    table.insert(choices, p.name)
  end
  vim.ui.select(choices, { prompt = "Agent profile" }, function(choice)
    if not choice then
      return
    end
    local p = Profiles.find(choice)
    if p then
      cb(p)
    end
  end)
end

--- Open a picker to choose a mode, then invoke `cb(mode)`.
function M.pick_mode(cb)
  local Modes = require("agent_core.modes")
  local modes = Modes.all()
  local active = Modes.get_active()
  local items = M.mode_picker_items(modes, active)

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Mode",
      items = items,
      layout = { preview = false },
      live = true,
      focus = "list",
      format = function(item)
        return { { item.text } }
      end,
      on_show = function(picker)
        scroll_to_active(picker, Snacks)
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.mode then
          cb(item.mode)
        end
      end,
      cancel = function()
        cb(nil)
      end,
    })
    return
  end

  local choices = {}
  for _, m in ipairs(modes) do
    local tag = (m.name == active) and " [active]" or ""
    choices[#choices + 1] = (m.label or m.name) .. tag
  end
  vim.ui.select(choices, { prompt = "Agent mode" }, function(choice)
    if not choice then
      return
    end
    local label = choice:gsub(" %[active%]$", "")
    for _, m in ipairs(modes) do
      if (m.label or m.name) == label then
        cb(m)
        return
      end
    end
  end)
end

--- Open a picker to choose a chat model from the pooled registry (every eligible
--- primary/classifier entry across all providers), then invoke `cb(entry)`.
function M.pick_model(cb)
  local Registry = require("agent_core.registry")
  local models = Registry.eligible_models()
  local items = M.model_picker_items(models, active_model_entry())

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Model",
      items = items,
      layout = { preview = false },
      live = true,
      focus = "list",
      format = function(item)
        return { { item.text } }
      end,
      on_show = function(picker)
        scroll_to_active(picker, Snacks)
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.entry then
          cb(item.entry)
        end
      end,
      cancel = function()
        cb(nil)
      end,
    })
    return
  end

  local choices = {}
  for _, it in ipairs(items) do
    table.insert(choices, it.text)
  end
  vim.ui.select(choices, { prompt = "Agent model" }, function(choice)
    for _, it in ipairs(items) do
      if it.text == choice then
        cb(it.entry)
        return
      end
    end
    cb(nil)
  end)
end

return M
