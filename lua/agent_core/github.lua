---@mod agent_core.github GitHub context + write tool for avante (via the `gh` CLI)
---@brief [[
--- Exposes a single `github` avante custom tool that wraps the GitHub CLI (`gh`)
--- to pull PRs, issues, and search results into context, plus allowlisted write
--- actions (create_pr, commit, comment, push). Read actions never mutate; write
--- actions are explicitly allowlisted `gh`/`git` subcommands built from discrete
--- arguments (never an arbitrary shell string), and are marked destructive via
--- agent_core's `destructive_tools` so read-only modes cannot invoke them.
--- Requires `gh` on PATH and an authenticated remote (the agent's cwd is normally
--- the repo root).
---@brief ]]

local M = {}

local TIMEOUT_MS = 30000

---@param args string[]
---@param cb fun(stdout: string|nil, err: string|nil)
local function run_gh(args, cb)
  local bin = vim.fn.exepath("gh")
  if bin == "" then
    cb(nil, "gh CLI not found on PATH; install it (https://cli.github.com) and authenticate with `gh auth login`")
    return
  end
  local full = { bin }
  for _, a in ipairs(args) do
    full[#full + 1] = a
  end
  vim.system(full, { text = true, timeout = TIMEOUT_MS }, function(obj)
    if obj.code == 0 then
      cb(obj.stdout or "", nil)
    else
      local err = (obj.stderr and obj.stderr ~= "") and obj.stderr or ("gh exited " .. tostring(obj.code))
      cb(nil, err)
    end
  end)
end

---@param args string[]
---@param cb fun(stdout: string|nil, err: string|nil)
local function run_git(args, cb)
  local bin = vim.fn.exepath("git")
  if bin == "" then
    cb(nil, "git CLI not found on PATH")
    return
  end
  local full = { bin }
  for _, a in ipairs(args) do
    full[#full + 1] = a
  end
  vim.system(full, { text = true, timeout = TIMEOUT_MS }, function(obj)
    if obj.code == 0 then
      cb(obj.stdout or "", nil)
    else
      local err = (obj.stderr and obj.stderr ~= "") and obj.stderr or ("git exited " .. tostring(obj.code))
      cb(nil, err)
    end
  end)
end

---@type AvanteLLMTool
local github = {
  name = "github",
  description = "Query GitHub for pull requests, issues, and search results, and perform allowlisted "
    .. "write actions (create_pr, commit, comment, push) via the `gh`/`git` CLIs. "
    .. "Read actions: 'pr' (view PR), 'issue' (view issue), 'search' (search code/prs/issues/repos). "
    .. "Write actions are destructive and require an authenticated remote.",
  param = {
    type = "table",
    fields = {
      {
        name = "action",
        description = "What to do: 'pr', 'issue', 'search', 'create_pr', 'commit', 'comment', or 'push'.",
        type = "string",
      },
      {
        name = "number",
        description = "PR or issue number (required for action 'pr', 'issue', or 'comment').",
        type = "integer",
        optional = true,
      },
      {
        name = "query",
        description = "Search query (required for action 'search'), e.g. 'repo:owner/repo is:open bug'.",
        type = "string",
        optional = true,
      },
      {
        name = "search_type",
        description = "What to search: 'prs', 'issues', 'code', or 'repos' (default 'prs').",
        type = "string",
        optional = true,
      },
      {
        name = "title",
        description = "PR title (required for action 'create_pr').",
        type = "string",
        optional = true,
      },
      {
        name = "body",
        description = "PR or comment body (optional).",
        type = "string",
        optional = true,
      },
      {
        name = "base",
        description = "Base branch for a PR (default: repository default branch).",
        type = "string",
        optional = true,
      },
      {
        name = "head",
        description = "Head branch for a PR (default: current branch).",
        type = "string",
        optional = true,
      },
      {
        name = "message",
        description = "Commit message (required for action 'commit').",
        type = "string",
        optional = true,
      },
    },
    required = { "action" },
    usage = {
      action = "One of: pr, issue, search, create_pr, commit, comment, push",
      number = "PR or issue number (for action pr/issue/comment)",
      query = "Search query (for action search)",
      search_type = "Search domain: prs, issues, code, repos",
      title = "PR title (for action create_pr)",
      body = "PR or comment body",
      base = "PR base branch",
      head = "PR head branch",
      message = "Commit message (for action commit)",
    },
  },
  returns = {
    {
      name = "output",
      description = "The GitHub CLI output (PR/issue body, comments, or search results)",
      type = "string",
    },
    {
      name = "error",
      description = "Error message if the query failed",
      type = "string",
      optional = true,
    },
  },
}

---@type AvanteLLMToolFunc<{ action: string, number?: integer, query?: string, search_type?: string, title?: string, body?: string, base?: string, head?: string, message?: string }>
function github.func(input, opts)
  if not opts.on_complete then
    return nil, "on_complete not provided"
  end
  local action = input.action
  if not action or action == "" then
    return nil, "action is required (one of: pr, issue, search, create_pr, commit, comment, push)"
  end

  local args
  local runner = run_gh
  if action == "pr" then
    local number = tonumber(input.number)
    if not number then
      return nil, "number is required for action 'pr'"
    end
    args = { "pr", "view", tostring(number), "--comments" }
  elseif action == "issue" then
    local number = tonumber(input.number)
    if not number then
      return nil, "number is required for action 'issue'"
    end
    args = { "issue", "view", tostring(number), "--comments" }
  elseif action == "search" then
    local query = input.query
    if not query or query == "" then
      return nil, "query is required for action 'search'"
    end
    local search_type = input.search_type or "prs"
    if not vim.tbl_contains({ "prs", "issues", "code", "repos" }, search_type) then
      return nil, "search_type must be one of: prs, issues, code, repos"
    end
    args = { "search", search_type, query, "--limit", "20" }
  elseif action == "create_pr" then
    local title = input.title
    if not title or title == "" then
      return nil, "title is required for action 'create_pr'"
    end
    args = { "pr", "create", "--title", title }
    if input.body and input.body ~= "" then
      args[#args + 1] = "--body"
      args[#args + 1] = input.body
    end
    if input.base and input.base ~= "" then
      args[#args + 1] = "--base"
      args[#args + 1] = input.base
    end
    if input.head and input.head ~= "" then
      args[#args + 1] = "--head"
      args[#args + 1] = input.head
    end
  elseif action == "comment" then
    local number = tonumber(input.number)
    if not number then
      return nil, "number is required for action 'comment'"
    end
    if not input.body or input.body == "" then
      return nil, "body is required for action 'comment'"
    end
    args = { "pr", "comment", tostring(number), "--body", input.body }
  elseif action == "commit" then
    if not input.message or input.message == "" then
      return nil, "message is required for action 'commit'"
    end
    runner = run_git
    args = { "add", "-A" }
    run_git(args, function(_, add_err)
      if add_err then
        opts.on_complete(nil, add_err)
        return
      end
      run_git({ "commit", "-m", input.message }, function(stdout, err)
        if err then
          opts.on_complete(nil, err)
          return
        end
        opts.on_complete(stdout, nil)
      end)
    end)
    return
  elseif action == "push" then
    runner = run_git
    args = { "push" }
  else
    return nil,
      "unknown action '" .. tostring(action) .. "' (one of: pr, issue, search, create_pr, commit, comment, push)"
  end

  if opts.on_log then
    opts.on_log("github " .. table.concat(args, " "))
  end

  runner(args, function(stdout, err)
    if err then
      opts.on_complete(nil, err)
      return
    end
    opts.on_complete(stdout, nil)
  end)
end

--- Return the github custom tool for wiring into avante's `custom_tools`.
function M.github_tool()
  return github
end

return M
