local M = {}

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

  local items = {}
  for _, m in ipairs(modes) do
    table.insert(items, {
      text = string.format("%s  |  %s", m.label or m.name, m.read_only and "read-only" or "full"),
      mode = m,
    })
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Mode",
      items = items,
      layout = { preview = false },
      live = true,
      format = function(item)
        return { { item.text } }
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
    table.insert(choices, m.name)
  end
  vim.ui.select(choices, { prompt = "Agent mode" }, function(choice)
    if not choice then
      return
    end
    local m = Modes.find(choice)
    if m then
      cb(m)
    end
  end)
end

--- Open a picker to choose a chat model from the pooled registry (every eligible
--- primary/classifier entry across all providers), then invoke `cb(entry)`.
function M.pick_model(cb)
  local Registry = require("agent_core.registry")
  local models = Registry.eligible_models()

  local items = {}
  for _, e in ipairs(models) do
    table.insert(items, {
      text = string.format("%s  |  %s  |  %s", e.model or "?", e.provider or "?", e.quality_tier or "?"),
      entry = e,
    })
  end

  local ok, Snacks = pcall(require, "snacks.picker")
  if ok and type(Snacks) == "table" and type(Snacks.pick) == "function" then
    Snacks.pick({
      title = "Agent Model",
      items = items,
      layout = { preview = false },
      live = true,
      format = function(item)
        return { { item.text } }
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
