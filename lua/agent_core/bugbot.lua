---@mod agent_core.bugbot Local bug review: autonomous review + autofix
---@brief [[
--- A local bug-review agent: review the working tree (or a branch vs base)
--- and produce a severity-ranked findings report, optionally applying fixes in an
--- isolated git worktree and opening a PR. Review fans out to parallel review
--- workers (single-shot LLM calls over diff chunks), each returning structured
--- findings; a lead synthesizes them into a report buffer. Autofix runs a single
--- write-capable subagent in a new-branch worktree, commits, pushes, and opens a
--- PR via `gh pr create`. All write paths are destructive and gated on --autofix.
---@brief ]]

local M = {}

M.config = {
  base = "main",
  autofix = false,
  review_profile = nil, -- profile for review workers; nil = active profile
  max_chunk_chars = 20000,
  max_subagents = 4,
}

---@param args string[]
---@return string
local function syslist(args)
  local out = vim.fn.systemlist(args)
  return table.concat(out, "\n")
end

---@param args string[]
---@return boolean ok
---@return string output
local function syslist_ok(args)
  local out = syslist(args)
  return vim.v.shell_error == 0, out
end

--- Capture the diff to review: base..HEAD when a base is given, else the
--- working tree (staged + unstaged) via `git diff HEAD`.
---@param base string|nil
---@param cb fun(diff: string|nil, err: string|nil)
function M.capture_diff(base, cb)
  local args
  if base and base ~= "" then
    args = { "git", "diff", base .. "...HEAD" }
  else
    args = { "git", "diff", "HEAD" }
  end
  local ok, out = syslist_ok(args)
  if not ok then
    cb(nil, "git diff failed: " .. out)
    return
  end
  if out == "" and not (base and base ~= "") then
    -- No working-tree diff; fall back to staged-only.
    local ok2, out2 = syslist_ok({ "git", "diff", "--staged" })
    if ok2 then
      out = out2
    end
  end
  cb(out, nil)
end

--- Split a diff into chunks of at most max_chars.
---@param diff string
---@param max_chars integer
---@return string[]
function M.chunk_diff(diff, max_chars)
  local chunks = {}
  local current = {}
  local current_len = 0
  for line in (diff .. "\n"):gmatch("(.-)\n") do
    if current_len + #line + 1 > max_chars and #current > 0 then
      chunks[#chunks + 1] = table.concat(current, "\n")
      current = {}
      current_len = 0
    end
    current[#current + 1] = line
    current_len = current_len + #line + 1
  end
  if #current > 0 then
    chunks[#chunks + 1] = table.concat(current, "\n")
  end
  return chunks
end

local REVIEW_SYSTEM =
  [[You are a meticulous code reviewer (local Bugbot). Analyze the diff and report concrete, actionable findings as a JSON array. Each finding: {"severity": "high"|"medium"|"low", "file": "path", "line": 0, "title": "short", "explanation": "why this is a problem", "suggestion": "concrete fix"}. Only report real issues; return [] if the diff is clean. Output ONLY the JSON array.]]

--- Parse findings JSON from a review worker's text.
---@param text string
---@return table[]
function M.parse_findings(text)
  local ok, data = pcall(vim.json.decode, text)
  if ok and type(data) == "table" then
    local out = {}
    for _, f in ipairs(data) do
      if type(f) == "table" then
        out[#out + 1] = f
      end
    end
    return out
  end
  -- Best-effort: if not JSON, return a single low-severity note.
  return {}
end

--- Review a diff, fanning out to parallel workers, and deliver findings.
---@param diff string
---@param cb fun(findings: table[], err: string|nil)
function M.review(diff, cb)
  if not diff or diff == "" then
    cb({}, "no diff to review")
    return
  end
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.review_profile)
  if not profile then
    cb({}, "no profile resolved for review")
    return
  end

  local chunks = M.chunk_diff(diff, M.config.max_chunk_chars or 20000)
  if #chunks == 0 then
    cb({}, nil)
    return
  end

  local findings = {}
  local pending = #chunks
  local failed = false
  for i, chunk in ipairs(chunks) do
    Runner.llm_curl(profile, {
      system_prompt = REVIEW_SYSTEM,
      user_prompt = "Review this diff chunk (part " .. i .. " of " .. #chunks .. "):\n\n" .. chunk,
    }, function(result)
      if result.error then
        failed = true
      elseif result.text then
        for _, f in ipairs(M.parse_findings(result.text)) do
          findings[#findings + 1] = f
        end
      end
      pending = pending - 1
      if pending == 0 then
        cb(findings, failed and "one or more review workers failed" or nil)
      end
    end)
  end
end

--- Render a findings report in a scratch buffer.
---@param findings table[]
function M.present(findings)
  local lines = { "# Bugbot review", "", "Findings: " .. tostring(#findings), "" }
  local order = { high = 1, medium = 2, low = 3 }
  table.sort(findings, function(a, b)
    return (order[a.severity] or 4) < (order[b.severity] or 4)
  end)
  for i, f in ipairs(findings) do
    local loc = (f.file or "?") .. (f.line and f.line > 0 and (":" .. tostring(f.line)) or "")
    lines[#lines + 1] = string.format("## %d. [%s] %s", i, f.severity or "?", f.title or "issue")
    lines[#lines + 1] = "- File: `" .. loc .. "`"
    lines[#lines + 1] = "- " .. (f.explanation or "")
    if f.suggestion then
      lines[#lines + 1] = "- Suggestion: " .. f.suggestion
    end
    lines[#lines + 1] = ""
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
  vim.api.nvim_open_win(buf, true, { split = "right" })
end

--- Create a detached/new-branch worktree under <root>/.agent_core/worktrees/.
---@param root string
---@param base string
---@return string|nil dir
---@return string|nil err
local function create_worktree(root, base)
  local ok, top = syslist_ok({ "git", "-C", root, "rev-parse", "--show-toplevel" })
  if not ok or top == "" then
    return nil, "not a git repository"
  end
  root = top:gsub("[\r\n]", "")

  local base_dir = vim.fn.fnamemodify(root, ":h") .. "/.agent_core/worktrees"
  vim.fn.mkdir(base_dir, "p")
  local branch = "agent-core/bugbot-fix-" .. tostring(os.time())
  local dir = base_dir .. "/bugbot-" .. tostring(os.time())

  local out = syslist({ "git", "-C", root, "worktree", "add", "-b", branch, dir, base or "HEAD" })
  if vim.v.shell_error ~= 0 then
    return nil, "git worktree add failed: " .. out
  end
  return dir, nil
end

--- Autofix: run a write-capable subagent in a new-branch worktree, commit, push,
--- and open a PR.
---@param findings table[]
---@param cb fun(result: string|nil, err: string|nil)
function M.autofix(findings, cb)
  if not findings or #findings == 0 then
    cb(nil, "no findings to autofix")
    return
  end

  local root = vim.fn.getcwd()
  local dir, err = create_worktree(root, M.config.base or "main")
  if not dir then
    cb(nil, err)
    return
  end

  local fix_lines = {}
  for _, f in ipairs(findings) do
    fix_lines[#fix_lines + 1] = string.format(
      "- [%s] %s: %s (fix: %s)",
      f.severity or "?",
      f.file or "?",
      f.title or "issue",
      f.suggestion or "no suggestion"
    )
  end
  local fix_prompt = "Apply the following review fixes:\n\n" .. table.concat(fix_lines, "\n")

  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.review_profile)
  if not profile then
    cb(nil, "no profile resolved for autofix")
    return
  end
  local Session = require("agent_core.runtime.session")
  local tools = require("agent_core.runtime.tools").full_set(require("agent_core").get_custom_tools())

  local original_cwd = vim.fn.getcwd()
  vim.fn.chdir(dir)

  local result = ""
  local done = false
  local function finish(res, err2)
    if done then
      return
    end
    done = true
    vim.fn.chdir(original_cwd)
    cb(res, err2)
  end

  vim.defer_fn(function()
    finish(nil, "autofix subagent timed out")
  end, M.config.timeout_ms or 300000)

  Session.new({
    provider = profile.provider,
    model = profile.model,
    api_key = Runner.resolve_key(profile),
    endpoint = profile.endpoint,
    api_key_name = profile.api_key_name,
  }):run({
    system_prompt = string.format(
      [[You are a code-fix subagent. Working directory: %s

TASK:
%s

Apply each fix using your edit tools, then call `attempt_completion` with a summary.]],
      dir,
      fix_prompt
    ),
    user_input = "start",
    tools = tools,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        if msg.role == "tool" and msg.name == "attempt_completion" then
          result = msg.content
        end
      end
    end,
    on_complete = function(loop_err)
      if loop_err ~= nil then
        finish(nil, "autofix subagent failed: " .. vim.inspect(loop_err))
        return
      end
      local base = M.config.base or "main"
      local branch = vim.fn.trim(syslist({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }))
      syslist_ok({ "git", "-C", dir, "add", "-A" })
      syslist_ok({ "git", "-C", dir, "diff", "--cached", "--quiet" })
      if vim.v.shell_error == 0 then
        finish("no changes to commit after autofix", nil)
        return
      end

      local function commit_and_pr()
        local ok_commit, commit_out = syslist_ok({ "git", "-C", dir, "commit", "-m", "fix: apply bugbot autofixes" })
        if not ok_commit then
          finish(nil, "commit failed: " .. commit_out)
          return
        end
        local ok_push, push_out = syslist_ok({ "git", "-C", dir, "push", "-u", "origin", branch })
        if not ok_push then
          finish(nil, "push failed: " .. push_out)
          return
        end
        local body = "Autofixes applied by local Bugbot:\n\n" .. table.concat(fix_lines, "\n")
        local pr_args =
          { "gh", "pr", "create", "--base", base, "--head", branch, "--title", "fix: bugbot autofixes", "--body", body }
        local pr_out = syslist(pr_args)
        if vim.v.shell_error ~= 0 then
          finish(nil, "gh pr create failed: " .. pr_out)
          return
        end
        finish("PR opened: " .. pr_out, nil)
      end

      -- Headless (tool/automation) path: commit without an interactive preview.
      if #vim.api.nvim_list_uis() == 0 then
        commit_and_pr()
        return
      end

      local diff_text = syslist({ "git", "-C", dir, "diff", "--cached" })
      require("agent_core.diff").present_text({
        text = diff_text,
        label = "bugbot-autofix",
        on_apply = commit_and_pr,
        on_dismiss = function()
          finish(nil, "autofix preview dismissed")
        end,
      })
    end,
  })
end

--- Backing for :AgentBugbot.
---@param arg string
function M.bugbot_cmd(arg)
  local autofix = false
  local base = M.config.base
  if arg and arg ~= "" then
    for token in arg:gmatch("%S+") do
      if token == "--autofix" then
        autofix = true
      elseif token:sub(1, 7) == "--base=" then
        base = token:sub(8)
      end
    end
  end

  vim.notify("Bugbot: capturing diff…", vim.log.levels.INFO)
  M.capture_diff(base, function(diff, err)
    if err then
      vim.notify("Bugbot: " .. err, vim.log.levels.ERROR)
      return
    end
    if diff == "" then
      vim.notify("Bugbot: no diff to review", vim.log.levels.WARN)
      return
    end
    vim.notify(
      "Bugbot: reviewing (" .. #M.chunk_diff(diff, M.config.max_chunk_chars or 20000) .. " chunk(s))…",
      vim.log.levels.INFO
    )
    M.review(diff, function(findings, rerr)
      if rerr then
        vim.notify("Bugbot: " .. rerr, vim.log.levels.WARN)
      end
      M.present(findings)
      if autofix and #findings > 0 then
        vim.notify("Bugbot: applying autofixes…", vim.log.levels.INFO)
        M.autofix(findings, function(res, aerr)
          if aerr then
            vim.notify("Bugbot: " .. aerr, vim.log.levels.ERROR)
          else
            vim.notify("Bugbot: " .. res, vim.log.levels.INFO)
          end
        end)
      end
    end)
  end)
end

---@type AgentTool
local bugbot = {
  name = "bugbot",
  description = "Run a local Bugbot review of the current working tree (or branch vs base) and return findings. "
    .. "Set action='autofix' to also apply fixes in an isolated worktree and open a PR (destructive).",
  param = {
    type = "table",
    fields = {
      { name = "action", description = "'review' (default) or 'autofix'.", type = "string", optional = true },
      {
        name = "base",
        description = "Base branch to diff against (default 'main').",
        type = "string",
        optional = true,
      },
    },
    required = {},
    usage = {
      action = "review or autofix",
      base = "Base branch for the diff",
    },
  },
  returns = {
    { name = "result", description = "Findings report or PR URL.", type = "string" },
    { name = "error", description = "Error message if the review failed.", type = "string", optional = true },
  },
}
---@type AgentToolFunc<{ action?: string, base?: string }>
function bugbot.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local base = input.base or M.config.base
  M.capture_diff(base, function(diff, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    if diff == "" then
      opts.on_complete("No diff to review.", nil)
      return
    end
    M.review(diff, function(findings, rerr)
      local lines = { "Bugbot findings: " .. tostring(#findings) }
      for i, f in ipairs(findings) do
        lines[#lines + 1] = string.format("%d. [%s] %s: %s", i, f.severity or "?", f.file or "?", f.title or "issue")
      end
      local summary = table.concat(lines, "\n")
      if input.action == "autofix" and #findings > 0 then
        M.autofix(findings, function(res, aerr)
          if aerr then
            opts.on_complete(summary .. "\n\nautofix error: " .. aerr, nil)
          else
            opts.on_complete(summary .. "\n\n" .. res, nil)
          end
        end)
        return
      end
      opts.on_complete(summary, rerr)
    end)
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.bugbot or {})
end

function M.bugbot_tool()
  return bugbot
end

return M
