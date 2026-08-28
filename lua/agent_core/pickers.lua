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
      format = function(item)
        return { { item.text } }
      end,
      confirm = function(picker, item)
        picker:close()
        if item and item.mode then
          cb(item.mode)
        end
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

return M
