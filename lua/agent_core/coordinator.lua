---@mod agent_core.coordinator Recommendation merger.
---@brief [[
--- Single entry point for prompt-driven recommendations. Registers one
--- `AvanteInputSubmitted` autocmd, runs the mode recommender and the agent
--- autoswitch in parallel, and merges their results into a single interactive
--- prompt (switch both / switch one / ignore) instead of two sequential prompts.
---@brief ]]

local M = {}

--- Build the prompt string for the merged select.
--- @param mode {to:string, reason:string, apply:fun()}|nil
--- @param profile {to:string, reason:string, apply:fun()}|nil
--- @return string
function M.build_prompt(mode, profile)
  local parts = {}
  if mode then
    parts[#parts + 1] = "mode -> " .. mode.to .. " (" .. mode.reason .. ")"
  end
  if profile then
    parts[#parts + 1] = "profile -> " .. profile.to .. " (" .. profile.reason .. ")"
  end
  return "Agent recommendation: " .. table.concat(parts, "; ")
end

--- Present 0-2 decisions in a single interactive prompt.
--- @param results {mode?: {to:string, reason:string, apply:fun()}, profile?: {to:string, reason:string, apply:fun()}}
function M.present(results)
  results = results or {}
  local mode = results.mode
  local profile = results.profile

  local options = {}

  if mode and profile then
    options = {
      {
        label = "Switch both: " .. mode.to .. " + " .. profile.to,
        apply = function()
          mode.apply()
          profile.apply()
        end,
      },
      {
        label = "Switch mode only: " .. mode.to,
        apply = function()
          mode.apply()
        end,
      },
      {
        label = "Switch profile only: " .. profile.to,
        apply = function()
          profile.apply()
        end,
      },
      { label = "Ignore", apply = function() end },
    }
  elseif mode then
    options = {
      {
        label = "Switch mode to " .. mode.to,
        apply = function()
          mode.apply()
        end,
      },
      { label = "Ignore", apply = function() end },
    }
  elseif profile then
    options = {
      {
        label = "Switch profile to " .. profile.to,
        apply = function()
          profile.apply()
        end,
      },
      { label = "Ignore", apply = function() end },
    }
  else
    return
  end

  local labels = {}
  for _, o in ipairs(options) do
    labels[#labels + 1] = o.label
  end

  vim.ui.select(labels, { prompt = M.build_prompt(mode, profile) }, function(choice)
    for _, o in ipairs(options) do
      if o.label == choice then
        o.apply()
        break
      end
    end
  end)
end

--- Run the mode recommender and the agent autoswitch in parallel, then present
--- a single merged prompt once both have produced a result (or nil).
--- @param request string
function M.evaluate(request)
  local Recommend = require("agent_core.recommend")
  local AutoSwitch = require("agent_core.autoswitch")

  local results = {}
  local remaining = 2
  local done = { mode = false, profile = false }

  local function collect(kind)
    return function(decision)
      if done[kind] then
        return
      end
      done[kind] = true
      if decision then
        results[kind] = decision
      end
      remaining = remaining - 1
      if remaining <= 0 then
        vim.schedule(function()
          M.present(results)
        end)
      end
    end
  end

  local ok_mode, err_mode = pcall(Recommend.classify, request, collect("mode"))
  if not ok_mode then
    vim.notify("[AGENT] mode recommend failed: " .. tostring(err_mode), vim.log.levels.WARN)
    collect("mode")(nil)
  end

  local ok_prof, err_prof = pcall(AutoSwitch.classify, request, collect("profile"))
  if not ok_prof then
    vim.notify("[AGENT] autoswitch failed: " .. tostring(err_prof), vim.log.levels.WARN)
    collect("profile")(nil)
  end
end

function M.setup()
  if M._registered then
    return
  end
  M._registered = true
  vim.api.nvim_create_autocmd("User", {
    pattern = "AvanteInputSubmitted",
    callback = function()
      local ev = vim.v.event
      local request = ev and ev.request
      if type(request) ~= "string" or request == "" then
        return
      end
      M.evaluate(request)
    end,
  })
end

return M
