---@mod agent_core.runner Headless single-agent runner (local SDK / Automations parity)
---@brief [[
--- Runs a single agent headlessly and returns its final answer, so agent_core can
--- be scripted from git hooks, cron, or `nvim --headless` — the local analog of
--- a headless SDK runtime and Automations. `M.run(prompt, opts, cb)` resolves
--- a profile, assembles the same system prompt the interactive agent gets
--- (mode persona + brief + rules + notepad + memory), and streams through
--- avante's own `Llm.curl` client (no direct HTTP), so it honors every configured
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

--- Env-first API-key resolution and export, mirroring profiles.switch.
---@param profile table
local function export_key(profile)
  if profile.api_key_name and profile.api_key_name ~= "" then
    local Keys = require("agent_core.keys")
    local key = profile.api_key or os.getenv(profile.api_key_name) or Keys.get(profile.name)
    if key and key ~= "" then
      vim.fn.setenv(profile.api_key_name, key)
      vim.fn.setenv("AVANTE_" .. profile.api_key_name, key)
    end
  end
end

--- Build the user-message content for a completion call. When `opts.images` is
--- present (a list of `{ data, media_type }` base64 image parts), produce the
--- multimodal array form avante accepts; otherwise keep the plain string form
--- every existing caller relies on. Exported for unit testing.
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

--- Single-shot chat completion through avante's own client. `opts.images`
--- (optional) is a list of `{ data, media_type }` base64 image parts, enabling
--- multimodal/vision prompts; it has no effect on the plain-text path.
---@param profile table
---@param opts { system_prompt:string, user_prompt:string, on_chunk:fun(chunk:string)|nil, images:table[]|nil }
---@param cb fun(result: { text:string|nil, error:string|nil })
function M.llm_curl(profile, opts, cb)
  local ok_llm, Llm = pcall(require, "avante.llm")
  if not ok_llm or not Llm.curl then
    cb({ error = "avante.llm not available" })
    return
  end
  local ok_prov, Providers = pcall(require, "avante.providers")
  if not ok_prov then
    cb({ error = "avante.providers not available" })
    return
  end

  export_key(profile)

  local provider = Providers[profile.provider]
  if not provider then
    cb({ error = "provider not found: " .. tostring(profile.provider) })
    return
  end

  local original_model = provider.model
  if profile.model then
    provider.model = profile.model
  end

  local response = ""
  local done = false
  local function finish(result, err)
    if done then
      return
    end
    done = true
    provider.model = original_model
    cb({ text = result, error = err })
  end

  local timeout_ms = M.config.timeout_ms or 120000
  vim.defer_fn(function()
    finish(nil, "timed out after " .. tostring(timeout_ms) .. "ms")
  end, timeout_ms)

  local ok = pcall(Llm.curl, {
    provider = provider,
    prompt_opts = {
      system_prompt = opts.system_prompt,
      messages = {
        { role = "user", content = M.build_user_content(opts) },
      },
    },
    handler_opts = {
      on_start = function() end,
      on_chunk = function(chunk)
        if chunk then
          response = response .. chunk
          if opts.on_chunk then
            opts.on_chunk(chunk)
          end
        end
      end,
      on_stop = function(stop_opts)
        if stop_opts and stop_opts.error ~= nil then
          finish(nil, tostring(stop_opts.error))
          return
        end
        finish(response ~= "" and response or nil, nil)
      end,
    },
  })
  if not ok then
    finish(nil, "avante.llm.curl failed")
  end
end

--- Assemble the system prompt the interactive agent would receive (mode persona +
--- brief + rules + notepad + memory), bounded to a reasonable default.
---@param mode_name string|nil
---@return string
function M.build_system_prompt(mode_name)
  local parts = { "You are a senior software engineer. Provide a thorough, self-contained answer." }

  local core = require("agent_core")
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

  local function add(fn)
    if not fn then
      return
    end
    local ok, text = pcall(fn)
    if ok and text and text ~= "" then
      parts[#parts + 1] = text
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
