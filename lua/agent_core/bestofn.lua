---@mod agent_core.bestofn Best-of-n multi-model comparison
---@brief [[
--- Fans a single prompt out to N configured profiles and presents their outputs
--- side-by-side in a scratch buffer, mirroring a best-of-n comparison. Each profile
--- is queried concurrently with its own provider/model/API key through the owned
--- provider transport (no direct HTTP), using a per-run provider copy so the
--- shared provider model is never mutated. Results are gathered in profile order,
--- then shown in a single read-only buffer so the user can scroll, compare, and
--- copy the winning answer.
---@brief ]]

local M = {}

---@class AgentBestOfNConfig
---@field profiles string[]|nil profile names to run (nil = every profile with autoswitch ~= false)
---@field timeout_ms integer per-model hard timeout
M.config = {
  profiles = nil,
  timeout_ms = 60000,
}

local Profiles ---@type agent_core.profiles

local function get_profiles()
  if not Profiles then
    Profiles = require("agent_core.profiles")
  end
  return Profiles
end

--- Resolve the profiles to run. Defaults to every profile that opts into
--- automatic routing (autoswitch ~= false).
---@return table[]
function M.resolve_profiles()
  local cfg = require("agent_core").config
  local bo = cfg.bestofn or {}
  local names = bo.profiles or M.config.profiles

  local all = get_profiles().all()
  if names and #names > 0 then
    local wanted = {}
    for _, n in ipairs(names) do
      wanted[n] = true
    end
    local out = {}
    for _, p in ipairs(all) do
      if wanted[p.name] then
        out[#out + 1] = p
      end
    end
    return out
  end

  local out = {}
  for _, p in ipairs(all) do
    if p.autoswitch ~= false and p.provider and p.model then
      out[#out + 1] = p
    end
  end
  return out
end

--- Run one profile against the prompt and deliver its output via cb.
--- Delegates to the owned runner single-shot primitive, so each profile's
--- provider/model/API key stream concurrently with no shared mutable state.
---@param profile table
---@param system_prompt string
---@param user_prompt string
---@param cb fun(result: {text:string|nil, error:string|nil})
local function run_profile(profile, system_prompt, user_prompt, cb)
  require("agent_core.runner").llm_curl(profile, {
    system_prompt = system_prompt,
    user_prompt = user_prompt,
    timeout_ms = M.config.timeout_ms or 60000,
  }, cb)
end

--- Run `prompt` across every resolved profile concurrently, then deliver the
--- accumulated results (in profile order) via cb.
---@param prompt string
---@param cb fun(results: {name:string,provider:string,model:string,text:string|nil,error:string|nil}[])
function M.run(prompt, cb)
  local profiles = M.resolve_profiles()
  if #profiles == 0 then
    vim.notify(
      "Best-of-n: no eligible profiles (set config.bestofn.profiles or add autoswitch-enabled profiles)",
      vim.log.levels.WARN
    )
    cb({})
    return
  end

  -- Ground the comparison with the project brief (cheap, structural) when it
  -- exists, so coding tasks get real codebase context across every model.
  local parts = { "You are a senior software engineer. Provide a thorough, self-contained answer." }
  local ok_core, core = pcall(require, "agent_core")
  if ok_core and core.get_brief_prompt then
    local brief = core.get_brief_prompt()
    if brief and brief ~= "" then
      parts[#parts + 1] = brief
    end
  end
  local system_prompt = table.concat(parts, "\n\n")

  local results = {}
  local remaining = #profiles
  for idx, p in ipairs(profiles) do
    run_profile(p, system_prompt, prompt, function(result)
      results[idx] = {
        name = p.name,
        provider = p.provider,
        model = p.model,
        text = result.text,
        error = result.error,
      }
      remaining = remaining - 1
      if remaining == 0 then
        local ordered = {}
        for i = 1, #profiles do
          ordered[i] = results[i]
        end
        cb(ordered)
      end
    end)
  end
end

--- Render the results into a read-only scratch buffer for side-by-side review.
---@param results {name:string,provider:string,model:string,text:string|nil,error:string|nil}[]
function M.present(results)
  if not results or #results == 0 then
    return
  end

  local lines = { "# Best-of-n results", "" }
  for i, r in ipairs(results) do
    lines[#lines + 1] = string.format("## %d. %s (%s / %s)", i, r.name, r.provider, r.model or "?")
    lines[#lines + 1] = ""
    if r.error then
      lines[#lines + 1] = "> ERROR: " .. r.error
    elseif r.text then
      for _, l in ipairs(vim.split(r.text, "\n")) do
        lines[#lines + 1] = l
      end
    else
      lines[#lines + 1] = "> (empty response)"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Public entry point backing :AgentBestOfN. Runs the comparison and presents
--- the results when complete.
---@param text string
function M.bestofn_manual(text)
  if not text or text == "" then
    return
  end
  vim.notify("Best-of-n: running " .. #M.resolve_profiles() .. " model(s)…", vim.log.levels.INFO)
  M.run(text, function(results)
    M.present(results)
    vim.notify("Best-of-n: complete (" .. #results .. " result(s))", vim.log.levels.INFO)
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.bestofn or {})
end

return M
