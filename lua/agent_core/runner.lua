---@mod agent_core.runner Headless single-agent runner (local SDK / Automations parity)
---@brief [[
--- Runs a single agent headlessly and returns its final answer, so agent_core can
--- be scripted from git hooks, cron, or `nvim --headless` — the local analog of
--- a headless SDK runtime and Automations. `M.run(prompt, opts, cb)` resolves
--- a profile, assembles the same system prompt the interactive agent gets
--- (mode persona + brief + rules + notepad + memory), and streams through
--- the owned provider transport (no direct HTTP), so it honors every configured
--- provider. `M.llm_curl` is the low-level single-shot primitive shared by the
--- completion engine and bugbot review fan-out.
---@brief ]]

local M = {}

M.config = {
  timeout_ms = 120000,
}

--- Resolve the profile to run. `name` may be a profile name, or nil to use the
--- active profile (falling back to the first autoswitch-enabled profile).
---@param name string|nil
---@return table|nil
function M.resolve_profile(name)
  local Profiles = require("agent_core.profiles")
  if name and name ~= "" then
    return Profiles.find(name)
  end
  local active = Profiles.get_active()
  if active then
    local p = Profiles.find(active)
    if p then
      return p
    end
  end
  for _, p in ipairs(Profiles.all()) do
    if p.autoswitch ~= false and p.provider and p.model then
      return p
    end
  end
  return nil
end

--- Env-first API-key resolution (explicit profile key > environment > keys store).
--- The owned runtime passes the resolved key directly to the provider transport,
--- so nothing needs to be exported into the process environment.
---@param profile table
---@return string|nil
function M.resolve_key(profile)
  if not profile then
    return nil
  end
  if profile.api_key and profile.api_key ~= "" then
    return profile.api_key
  end
  if profile.api_key_name and profile.api_key_name ~= "" then
    local key = os.getenv(profile.api_key_name)
    if key and key ~= "" then
      return key
    end
    local ok, Keys = pcall(require, "agent_core.keys")
    if ok then
      local k = Keys.get(profile.name)
      if k and k ~= "" then
        return k
      end
    end
  end
  return nil
end

--- Build the user-message content for a completion call. When `opts.images` is
--- present (a list of `{ data, media_type }` base64 image parts), produce the
--- multimodal array form the owned runtime accepts; otherwise keep the plain
--- string form every existing caller relies on. Exported for unit testing.
---@param opts table
---@return string|table
function M.build_user_content(opts)
  opts = opts or {}
  local images = opts.images
  if not images or #images == 0 then
    return opts.user_prompt
  end
  local parts = { { type = "text", text = opts.user_prompt or "" } }
  for _, img in ipairs(images) do
    parts[#parts + 1] = {
      type = "image",
      source = {
        type = "base64",
        media_type = img.media_type or "image/png",
        data = img.data or "",
      },
    }
  end
  return parts
end

--- Single-shot chat completion through the owned provider registry. `opts.images`
--- (optional) is a list of `{ data, media_type }` base64 image parts, enabling
--- multimodal/vision prompts; it has no effect on the plain-text path.
---@param profile table
---@param opts { system_prompt:string, user_prompt:string, on_chunk:fun(chunk:string)|nil, images:table[]|nil, timeout_ms?:number }
---@param cb fun(result: { text:string|nil, error:string|nil })
function M.llm_curl(profile, opts, cb)
  local Providers = require("agent_core.runtime.providers")

  local done = false
  local function finish(result, err)
    if done then
      return
    end
    done = true
    cb({ text = result, error = err })
  end

  local timeout_ms = opts.timeout_ms or M.config.timeout_ms or 120000
  vim.defer_fn(function()
    finish(nil, "timed out after " .. tostring(timeout_ms) .. "ms")
  end, timeout_ms)

  local ok, err = Providers.stream({
    provider = profile.provider,
    model = require("agent_core.profiles").effective_model(profile),
    api_key = M.resolve_key(profile),
    endpoint = profile.endpoint,
    api_key_name = profile.api_key_name,
    system = opts.system_prompt,
    messages = {
      { role = "user", content = M.build_user_content(opts) },
    },
    timeout_ms = timeout_ms,
    on_chunk = opts.on_chunk,
    on_stop = function(res)
      if res.error then
        finish(nil, tostring(res.error))
        return
      end
      finish(res.text ~= "" and res.text or nil, nil)
    end,
  })
  if not ok then
    finish(nil, tostring(err))
  end
end

--- Assemble the system prompt the interactive agent would receive (profile
--- persona + mode persona + brief + rules + notepad + memory), bounded to a
--- reasonable default.
---@param mode_name string|nil
---@return string
function M.build_system_prompt(mode_name)
  local parts = { "You are a senior software engineer. Provide a thorough, self-contained answer." }

  local core = require("agent_core")

  local function add(fn)
    if not fn then
      return
    end
    local ok, text = pcall(fn)
    if ok and text and text ~= "" then
      parts[#parts + 1] = text
    end
  end

  add(core.get_profile_persona) -- profile identity, before mode behavior

  if mode_name and mode_name ~= "" then
    local mode = require("agent_core.modes").find(mode_name)
    if mode and mode.system_prompt then
      parts[#parts + 1] = mode.system_prompt
    end
  elseif core.get_mode_prompt then
    local m = core.get_mode_prompt()
    if m and m ~= "" then
      parts[#parts + 1] = m
    end
  end

  add(core.get_brief_prompt)
  add(core.get_context_prompt)
  add(core.get_rules_prompt)
  add(core.get_notepad_prompt)
  add(core.get_memory_prompt)
  add(core.get_commands_prompt)

  return table.concat(parts, "\n\n")
end

--- Run one prompt headlessly and deliver the final answer.
---@param prompt string
---@param opts { profile:string|nil, mode:string|nil, model:string|nil, on_chunk:fun(chunk:string)|nil }|nil
---@param cb fun(result: { text:string|nil, error:string|nil, profile:string|nil })
function M.run(prompt, opts, cb)
  opts = opts or {}
  if not prompt or prompt == "" then
    cb({ error = "empty prompt" })
    return
  end

  local profile = M.resolve_profile(opts.profile)
  if not profile then
    cb({ error = "no profile resolved (configure a profile or set an active one)" })
    return
  end
  if opts.model then
    profile = vim.tbl_deep_extend("force", vim.deepcopy(profile), { model = opts.model })
  end

  local system_prompt = M.build_system_prompt(opts.mode)
  M.llm_curl(profile, {
    system_prompt = system_prompt,
    user_prompt = prompt,
    on_chunk = opts.on_chunk,
  }, function(result)
    result.profile = profile.name
    cb(result)
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.runner or {})
end

--- Backing for :AgentRun (interactive). With no argument, prompts for input.
---@param arg string
function M.run_cmd(arg)
  local text = arg
  if not text or text == "" then
    vim.ui.input({ prompt = "Agent run (prompt): " }, function(input)
      if input and input ~= "" then
        M.run(input, nil, function(result)
          if result.error then
            vim.notify("AgentRun: " .. result.error, vim.log.levels.ERROR)
          else
            vim.notify("AgentRun complete (" .. tostring(result.profile) .. ")", vim.log.levels.INFO)
            vim.print(result.text or "")
          end
        end)
      end
    end)
    return
  end
  vim.notify("AgentRun: running…", vim.log.levels.INFO)
  M.run(text, nil, function(result)
    if result.error then
      vim.notify("AgentRun: " .. result.error, vim.log.levels.ERROR)
    else
      vim.notify("AgentRun complete (" .. tostring(result.profile) .. ")", vim.log.levels.INFO)
      vim.print(result.text or "")
    end
  end)
end

return M
