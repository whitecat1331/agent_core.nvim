---@mod agent_core.debug Debug-mode instrumentation loop + cleanup
---@brief [[
--- Debug mode: instead of guessing at a fix, the model
--- generates hypotheses, adds temporary instrumentation, and asks the user to
--- reproduce the bug. Three read-friendly custom tools back the loop:
---   add_debug_instrumentation    record the exact snippet the model just added
---   request_reproduction         signal the user should reproduce now, then stop
---   remove_debug_instrumentation delete every recorded snippet (cleanup)
--- Instrumentation is tracked in <data>/agent_core/debug/<root>.json and removed
--- by exact text match, so the real fix (a separate edit) is never deleted.
--- A runtime-evidence channel:
--- `read_captured_logs` tails config.debug.log_file and/or runs config.debug.log_cmd
--- so the model fetches logs itself after reproduction instead of waiting on a paste.
---@brief ]]

local M = {}

--- Directory where session trackers live.
---@return string
function M.dir()
  return vim.fn.stdpath("data") .. "/agent_core/debug"
end

--- Filesystem-safe slug for a project root.
---@param s string
---@return string
function M.slugify(s)
  s = s:lower()
  s = s:gsub("[^%w%-]+", "-")
  s = s:gsub("-+", "-"):gsub("^-+", ""):gsub("-+$", "")
  if s == "" then
    s = "session"
  end
  return s
end

--- Session tracker path for the active project root.
---@return string
function M.session_path()
  local root = require("agent_core.indexer").root()
  return M.dir() .. "/" .. M.slugify(root) .. ".json"
end

--- Load recorded instrumentation entries (list), or {} on any error.
---@return {file:string,text:string,added_at:integer}[]
function M.load()
  local f = io.open(M.session_path(), "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" then
    return {}
  end
  return data
end

--- Persist instrumentation entries.
---@param entries table[]
---@return boolean
function M.save(entries)
  vim.fn.mkdir(M.dir(), "p")
  local f = io.open(M.session_path(), "w")
  if not f then
    return false
  end
  f:write(vim.json.encode(entries))
  f:close()
  return true
end

--- Remove all recorded instrumentation by exact text match. Returns the number
--- of snippets removed and the number of entries left (already absent/edited).
---@return integer removed
---@return integer remaining
function M.remove_all()
  local entries = M.load()
  local removed = 0
  local remaining = {}
  for _, e in ipairs(entries) do
    local ok = false
    if e.file and e.text and vim.fn.filereadable(e.file) == 1 then
      local content = table.concat(vim.fn.readfile(e.file), "\n")
      if content:find(e.text, 1, true) then
        local replaced = content:gsub(vim.pesc(e.text), "", 1)
        -- Collapse the blank gap left behind to a single blank line.
        replaced = replaced:gsub("\n\n\n+", "\n\n")
        local f = io.open(e.file, "w")
        if f then
          f:write(replaced)
          f:close()
          removed = removed + 1
          ok = true
        end
      end
    end
    if not ok then
      remaining[#remaining + 1] = e
    end
  end
  M.save(remaining)
  return removed, #remaining
end

---@type AvanteLLMTool
local add_debug_instrumentation = {
  name = "add_debug_instrumentation",
  description = "Record a temporary instrumentation snippet you just inserted so it can be removed later. "
    .. "Pass the exact file path and the exact text you added (one or more lines). The snippet must already "
    .. "exist in the file.",
  param = {
    type = "table",
    fields = {
      {
        name = "file",
        description = "The file you instrumented (absolute or repo-relative path).",
        type = "string",
      },
      {
        name = "text",
        description = "The exact instrumentation text you inserted (verbatim, including indentation).",
        type = "string",
      },
    },
    required = { "file", "text" },
    usage = {
      file = "Instrumented file path",
      text = "Exact inserted instrumentation text",
    },
  },
  returns = {
    {
      name = "result",
      description = "Confirmation that the snippet was recorded",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the snippet was not found in the file",
      type = "string",
      optional = true,
    },
  },
}

---@type AvanteLLMToolFunc<{ file: string, text: string }>
function add_debug_instrumentation.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local file = input.file
  local text = input.text
  if not file or file == "" then
    return nil, "file is required"
  end
  if not text or text == "" then
    return nil, "text is required"
  end
  local abs = vim.fn.fnamemodify(file, ":p")
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "file not found: " .. abs
  end
  local content = table.concat(vim.fn.readfile(abs), "\n")
  if not content:find(text, 1, true) then
    return nil, "text not found in " .. abs .. "; pass the exact snippet you inserted"
  end
  local entries = M.load()
  entries[#entries + 1] = { file = abs, text = text, added_at = os.time() }
  M.save(entries)
  if opts.on_log then
    opts.on_log("recorded instrumentation in: " .. abs)
  end
  opts.on_complete("Recorded instrumentation in " .. abs .. " (" .. #entries .. " total snippet(s))", nil)
end

---@type AvanteLLMTool
local remove_debug_instrumentation = {
  name = "remove_debug_instrumentation",
  description = "Remove every recorded instrumentation snippet (cleanup). Removes only the exact text that was "
    .. "recorded, so your actual fix is never deleted. Call this after the fix is verified.",
  param = {
    type = "table",
    fields = {},
    usage = {},
  },
  returns = {
    {
      name = "result",
      description = "Summary of how many snippets were removed",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if cleanup failed",
      type = "string",
      optional = true,
    },
  },
}

function remove_debug_instrumentation.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local removed, remaining = M.remove_all()
  opts.on_complete(string.format("Removed %d instrumentation snippet(s); %d already absent.", removed, remaining), nil)
end

---@type AvanteLLMTool
local request_reproduction = {
  name = "request_reproduction",
  description = "Signal that instrumentation is complete and the user should now reproduce the bug. Call this and "
    .. "then STOP, so the user can run the reproduction steps and paste the resulting logs/output back to you.",
  param = {
    type = "table",
    fields = {
      {
        name = "steps",
        description = "The exact reproduction steps for the user to follow.",
        type = "string",
        optional = true,
      },
    },
    usage = {
      steps = "Reproduction steps for the user",
    },
  },
  returns = {
    {
      name = "result",
      description = "Instructions to relay to the user",
      type = "string",
    },
  },
}

---@type AvanteLLMToolFunc<{ steps?: string }>
function request_reproduction.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  vim.g.agent_debug_awaiting_repro = true
  local steps = input.steps or "the steps you outlined"
  opts.on_complete(
    "Instrumentation is in place. STOP and ask the user to reproduce the bug using these steps:\n"
      .. steps
      .. "\n\nThen wait for the user to paste the resulting logs/output before continuing.",
    nil
  )
end

--- Run cleanup and notify (backs :AgentDebugCleanup).
function M.cleanup()
  local removed, remaining = M.remove_all()
  vim.notify(
    string.format("Debug cleanup: removed %d instrumentation snippet(s); %d already absent.", removed, remaining),
    vim.log.levels.INFO
  )
end

--- Read runtime evidence for the active project: tail the configured log file
--- and/or run the configured log command. Returns "" when neither is configured
--- or both are empty.
---@return string
function M.read_evidence()
  local dbg = require("agent_core").config.debug or {}
  local chunks = {}

  if dbg.log_file and dbg.log_file ~= "" then
    local path = vim.fn.expand(dbg.log_file)
    if vim.fn.filereadable(path) == 1 then
      local lines = vim.fn.readfile(path)
      local max_lines = 200
      local start = math.max(1, #lines - max_lines + 1)
      local tail = {}
      for i = start, #lines do
        tail[#tail + 1] = lines[i]
      end
      chunks[#chunks + 1] = "[log_file: " .. path .. "]\n" .. table.concat(tail, "\n")
    end
  end

  if dbg.log_cmd and dbg.log_cmd ~= "" then
    local out = vim.fn.system(dbg.log_cmd)
    if vim.v.shell_error == 0 and out ~= "" then
      chunks[#chunks + 1] = "[log_cmd: " .. dbg.log_cmd .. "]\n" .. out
    end
  end

  return table.concat(chunks, "\n\n")
end

---@type AvanteLLMTool
local read_captured_logs = {
  name = "read_captured_logs",
  description = "Read captured runtime evidence: the tail of the configured log file and/or the output of the "
    .. "configured log command. Use this after the user reproduces the bug so you can analyze the logs directly "
    .. "instead of waiting for the user to paste them.",
  param = {
    type = "table",
    fields = {},
    usage = {},
  },
  returns = {
    {
      name = "logs",
      description = "The captured log output (log file tail and/or command output)",
      type = "string",
    },
    {
      name = "error",
      description = "Error message when no runtime evidence is configured",
      type = "string",
      optional = true,
    },
  },
}

---@type AvanteLLMToolFunc<{}>
function read_captured_logs.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local evidence = M.read_evidence()
  if evidence == "" then
    opts.on_complete(nil, "no runtime evidence configured; set config.debug.log_file or config.debug.log_cmd")
    return
  end
  opts.on_complete(evidence, nil)
end

function M.setup()
  vim.fn.mkdir(M.dir(), "p")
end

--- Return the add_debug_instrumentation custom tool.
function M.add_debug_instrumentation_tool()
  return add_debug_instrumentation
end

--- Return the remove_debug_instrumentation custom tool.
function M.remove_debug_instrumentation_tool()
  return remove_debug_instrumentation
end

--- Return the request_reproduction custom tool.
function M.request_reproduction_tool()
  return request_reproduction
end

--- Return the read_captured_logs custom tool.
function M.read_captured_logs_tool()
  return read_captured_logs
end

return M
