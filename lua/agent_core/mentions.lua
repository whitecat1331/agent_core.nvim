---@mod agent_core.mentions @-mention context providers
---@brief [[
--- Expands `@codebase <query>`, `@git <pr|issue> <n>`, `@web <query>`, and
--- `@docs <path>` tokens in a submitted prompt into inline context blocks,
--- pulling from ripgrep (codebase search), the `gh` CLI (git), the web_search
--- tool (web), and local files (docs). The owned runtime injects context
--- separately, so this is the local analog: `M.expand(prompt, cb)` plus
--- the `:AgentMentions` command that expands a selection and opens the result in
--- a scratch buffer for review. The pure tokenizer (`M.find_mentions`) is exported
--- for testing.
---@brief ]]

local M = {}

---@class AgentMention
---@field type string "codebase" | "git" | "web" | "docs"
---@field arg string
---@field token string the literal "@type arg" span to replace

--- Find mention tokens in a prompt. A mention is `@type` followed by whitespace
--- and an argument that runs until the next `@type` token or end of line.
---@param prompt string
---@return AgentMention[]
function M.find_mentions(prompt)
  prompt = prompt or ""
  local types = { codebase = true, git = true, web = true, docs = true, file = true, folder = true, symbol = true }
  local mentions = {}
  local pos = 1
  while true do
    local s, e, type_ = prompt:find("@(%a+)", pos)
    if not s then
      break
    end
    if types[type_] then
      local rest_start = e + 1
      local ws = prompt:match("^%s+", rest_start)
      if ws then
        local arg_start = rest_start + #ws
        local next_at = prompt:find("@%a+", arg_start)
        local nl = prompt:find("\n", arg_start)
        local stop = #prompt + 1
        if next_at and next_at < stop then
          stop = next_at
        end
        if nl and nl < stop then
          stop = nl
        end
        local arg = prompt:sub(arg_start, stop - 1):gsub("%s+$", "")
        if arg ~= "" then
          mentions[#mentions + 1] = {
            type = type_,
            arg = arg,
            token = prompt:sub(s, stop - 1),
          }
        end
        pos = arg_start
      else
        pos = e + 1
      end
    else
      pos = e + 1
    end
  end
  return mentions
end

--- Run ripgrep (or grep fallback) for `query` and return raw stdout via cb.
---@param query string
---@param cb fun(stdout:string|nil, err:string|nil)
local function rg_query(query, cb)
  local root = require("agent_core.indexer").root()
  local rg = vim.fn.exepath("rg")
  local args
  if rg ~= "" then
    args = { rg, "--no-heading", "-n", "--color", "never", "-S", "--max-count", "40", query, root }
  else
    args = { "grep", "-rnI", "--exclude-dir=.git", "-m", "40", query, root }
  end
  vim.system(args, { text = true }, function(obj)
    if obj.code == 0 and obj.stdout ~= "" then
      cb(obj.stdout, nil)
    else
      cb(nil, "no results for: " .. query)
    end
  end)
end

--- Resolve `@codebase <query>` via ripgrep (structural fallback).
---@param query string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_codebase(query, cb)
  rg_query(query, function(stdout, err)
    if err then
      cb(nil, "no codebase results for: " .. query)
      return
    end
    cb("[codebase: " .. query .. "]\n" .. stdout, nil)
  end)
end

--- Resolve `@web <query>` through the web_search tool.
---@param query string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_web(query, cb)
  local ok_web, web = pcall(require, "agent_core.web")
  if not ok_web then
    cb(nil, "web module unavailable")
    return
  end
  local tool = web.web_search_tool()
  local finished = false
  local function done(result, err)
    if finished then
      return
    end
    finished = true
    if err then
      cb(nil, err)
    else
      cb("[web: " .. query .. "]\n" .. result, nil)
    end
  end
  local ok_call, ret, sync_err = pcall(tool.func, { query = query }, { on_complete = done })
  if not ok_call then
    done(nil, tostring(ret))
  elseif sync_err then
    done(nil, sync_err)
  end
end

--- Resolve `@git pr <n>` / `@git issue <n>` via the `gh` CLI.
---@param arg string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_git(arg, cb)
  local kind, num = arg:match("^%s*(%a+)%s+(%d+)%s*$")
  if not kind then
    cb(nil, "git mention must be '@git pr <n>' or '@git issue <n>'")
    return
  end
  local bin = vim.fn.exepath("gh")
  if bin == "" then
    cb(nil, "gh CLI not found on PATH")
    return
  end
  local args
  if kind == "pr" then
    args = { bin, "pr", "view", num, "--comments" }
  elseif kind == "issue" then
    args = { bin, "issue", "view", num, "--comments" }
  else
    cb(nil, "git mention must be 'pr' or 'issue'")
    return
  end
  vim.system(args, { text = true }, function(obj)
    if obj.code == 0 then
      cb("[git " .. kind .. " " .. num .. "]\n" .. (obj.stdout or ""), nil)
    else
      cb(nil, "gh " .. kind .. " view failed")
    end
  end)
end

--- Resolve `@docs <path>` by reading a local file.
---@param arg string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_docs(arg, cb)
  local path = vim.fn.expand(arg)
  if vim.fn.filereadable(path) == 1 then
    cb("[docs: " .. path .. "]\n" .. table.concat(vim.fn.readfile(path), "\n"), nil)
  else
    cb(nil, "docs file not found: " .. arg)
  end
end

--- Resolve `@file <path>` by reading a local file's full contents.
---@param arg string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_file(arg, cb)
  local path = vim.fn.expand(arg)
  if vim.fn.filereadable(path) == 1 then
    cb("[file: " .. path .. "]\n" .. table.concat(vim.fn.readfile(path), "\n"), nil)
  else
    cb(nil, "file not found: " .. arg)
  end
end

--- Resolve `@folder <path>` by listing its files (recursive, capped).
---@param arg string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_folder(arg, cb)
  local path = vim.fn.expand(arg)
  if vim.fn.isdirectory(path) ~= 1 then
    cb(nil, "folder not found: " .. arg)
    return
  end
  local files = vim.fn.glob(path .. "/**/*", false, true)
  local lines = {}
  for _, f in ipairs(files) do
    if vim.fn.isdirectory(f) ~= 1 then
      lines[#lines + 1] = f
      if #lines >= 100 then
        break
      end
    end
  end
  cb("[folder: " .. path .. "]\n" .. table.concat(lines, "\n"), nil)
end

--- Resolve `@symbol <name>` via LSP document symbols, with a ripgrep fallback.
---@param arg string
---@param cb fun(text:string|nil, err:string|nil)
local function resolve_symbol(arg, cb)
  local out = {}
  local got_lsp = false
  local ok_clients, clients = pcall(vim.lsp.get_clients, { bufnr = 0 })
  if ok_clients and clients and #clients > 0 then
    local ok_params, params = pcall(vim.lsp.util.make_text_document_params, 0)
    if ok_params then
      local ok_sync, results = pcall(vim.lsp.buf_request_sync, 0, "textDocument/documentSymbol", params, 1000)
      if ok_sync then
        for _, resp in pairs(results or {}) do
          if resp and resp.result then
            got_lsp = true
            for _, sym in ipairs(resp.result) do
              if sym.name and sym.name:lower():find(arg:lower(), 1, true) then
                local line = sym.name
                if sym.detail and sym.detail ~= "" then
                  line = line .. " — " .. sym.detail
                end
                out[#out + 1] = line
              end
            end
          end
        end
      end
    end
  end
  if got_lsp and #out > 0 then
    cb("[symbol: " .. arg .. "]\n" .. table.concat(out, "\n"), nil)
    return
  end
  rg_query(arg, function(stdout, err)
    if err then
      cb(nil, "no symbol results for: " .. arg)
      return
    end
    cb("[symbol (ripgrep): " .. arg .. "]\n" .. stdout, nil)
  end)
end

--- Resolve one mention asynchronously.
---@param m AgentMention
---@param cb fun(text:string|nil, err:string|nil)
local function resolve(m, cb)
  if m.type == "docs" then
    resolve_docs(m.arg, cb)
  elseif m.type == "codebase" then
    resolve_codebase(m.arg, cb)
  elseif m.type == "file" then
    resolve_file(m.arg, cb)
  elseif m.type == "folder" then
    resolve_folder(m.arg, cb)
  elseif m.type == "symbol" then
    resolve_symbol(m.arg, cb)
  elseif m.type == "web" then
    resolve_web(m.arg, cb)
  elseif m.type == "git" then
    resolve_git(m.arg, cb)
  else
    cb(nil, "unknown mention type @" .. m.type)
  end
end

--- Expand every mention token in `prompt` into inline context blocks.
---@param prompt string
---@param cb fun(expanded:string)
function M.expand(prompt, cb)
  if not prompt or prompt == "" then
    cb(prompt or "")
    return
  end
  local mentions = M.find_mentions(prompt)
  if #mentions == 0 then
    cb(prompt)
    return
  end

  local blocks = {}
  local remaining = #mentions
  for i, m in ipairs(mentions) do
    resolve(m, function(text, err)
      if text then
        blocks[i] = text
      else
        blocks[i] = "[mention failed: " .. m.token .. "] " .. tostring(err)
      end
      remaining = remaining - 1
      if remaining == 0 then
        local out = prompt
        for j, mm in ipairs(mentions) do
          out = out:gsub(vim.pesc(mm.token), blocks[j], 1)
        end
        cb(out)
      end
    end)
  end
end

--- Expand a prompt and show the result in a read-only scratch buffer.
---@param prompt string
function M.show(prompt)
  if not prompt or prompt == "" then
    return
  end
  M.expand(prompt, function(expanded)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(expanded, "\n"))
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].modifiable = false
    vim.api.nvim_open_win(buf, true, { split = "right" })
  end)
end

--- Backing for :AgentMentions. Uses the visual selection when present.
---@param arg string
function M.mentions_cmd(arg)
  local text = arg
  if not text or text == "" then
    local ok, start_line, start_col = pcall(vim.fn.getpos, "'<")
    local ok2, end_line, end_col = pcall(vim.fn.getpos, "'>")
    if ok and ok2 then
      local lines = vim.fn.getline(start_line, end_line)
      if #lines > 0 then
        lines[1] = string.sub(lines[1], start_col)
        lines[#lines] = string.sub(lines[#lines], 1, end_col)
        text = table.concat(lines, "\n")
      end
    end
  end
  if not text or text == "" then
    vim.ui.input({ prompt = "Expand mentions (prompt): " }, function(input)
      if input and input ~= "" then
        M.show(input)
      end
    end)
    return
  end
  M.show(text)
end

return M
