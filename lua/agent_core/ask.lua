---@mod agent_core.ask Ask-the-user clarifying-questions tool
---@brief [[
--- Exposes an `ask_user` avante custom tool so an agent can ask the user a
--- clarifying question mid-task and wait for the answer, instead of guessing.
--- This is the local analog of an agent's "ask clarifying questions" tool. The
--- question is surfaced through vim.ui.input and the answer is returned to the
--- model; in a headless session (no UI) it fails fast with an actionable error
--- so the agent can proceed with a documented assumption instead of hanging.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
}

---@type AvanteLLMTool
local ask_user = {
  name = "ask_user",
  description = "Ask the user a clarifying question and wait for their answer. "
    .. "Use when a task is ambiguous and the answer would change the approach.",
  param = {
    type = "table",
    fields = {
      { name = "question", description = "The question to ask the user.", type = "string" },
    },
    required = { "question" },
    usage = {
      question = "Question to ask",
    },
  },
  returns = {
    { name = "answer", description = "The user's answer (empty if they dismissed the prompt).", type = "string" },
    { name = "error", description = "Error message if the prompt could not be shown.", type = "string", optional = true },
  },
}

---@type AvanteLLMToolFunc<{ question: string }>
function ask_user.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local question = input.question
  if not question or question == "" then
    opts.on_complete(nil, "question is required")
    return
  end
  if M.config.enabled == false then
    opts.on_complete(nil, "ask_user is disabled")
    return
  end
  if #vim.api.nvim_list_uis() == 0 then
    opts.on_complete(nil, "no UI available (headless); state your assumption and proceed")
    return
  end
  if opts.on_log then
    opts.on_log("asking: " .. question)
  end
  vim.schedule(function()
    vim.ui.input({ prompt = "Agent: " .. question .. " " }, function(answer)
      opts.on_complete(answer or "", nil)
    end)
  end)
end

function M.ask_user_tool()
  return ask_user
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.ask or {})
end

return M
