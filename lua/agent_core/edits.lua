---@mod agent_core.edits Multi-file coordinated edits (Tab v2 remainder)
---@brief [[
--- Predicts and applies a coordinated edit across multiple files, grounded in
--- the symbol under the caret and its cross-file usage. The edit-capable profile
--- returns a JSON edit set `[{ "path", "find", "replace" }]` (never raw diffs);
--- the harness validates every path stays inside the repo root, checkpoints the
--- working tree, applies each find/replace, and presents a combined diff with
--- accept (keep) / cancel (rollback via checkpoint). Pure helpers (gather,
--- parse, validate, replace_first, unified_diff) are unit-testable and
--- headless-safe.
---@brief ]]

local M = {}

M.config = {
  enabled = true,
  edit_profile = nil, -- profile for edit requests; nil = active profile
  edit_model = nil, -- override model; nil = profile's model
  max_files = 8, -- max files to include as context
  max_chars = 20000, -- max context characters to send
  context_files = 5, -- max grep-matched files (beyond the current file)
}

local EDIT_SYSTEM = [[You are a multi-file refactoring engine. Given a symbol and its cross-file usage, return a JSON array of coordinated edits. Each edit is an object with three string fields:
- "path": the file path relative to the repository root.
- "find": the exact existing text to replace (include enough surrounding context to be unique).
- "replace": the replacement text.
Output ONLY the JSON array. Keep edits minimal and precise; do not include code fences or explanations.]]

--- Resolve the edit profile (override model when configured).
---@return table|nil
function M.resolve_profile()
  local Runner = require("agent_core.runner")
  local profile = Runner.resolve_profile(M.config.edit_profile)
  if not profile then
    return nil
  end
  local p = vim.deepcopy(profile)
  if M.config.edit_model and M.config.edit_model ~= "" then
    p.model = M.config.edit_model
  end
  return p
end

--- The identifier under the caret, or nil.
---@return string|nil
function M.symbol_under_caret()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

--- The current buffer's path relative to the project root, or nil.
---@return string|nil
function M.current_rel_path()
  local abs = vim.fn.expand("%:p")
  if abs == nil or abs == "" then
    return nil
  end
  local root = require("agent_core.indexer").root():gsub("\\", "/")
  local rel = abs:gsub("\\", "/")
  if rel:sub(1, #root) == root then
    rel = rel:sub(#root + 1):gsub("^/", "")
  end
  return rel
end

--- Search the repo root for files containing the literal symbol (bounded),
--- excluding the current file. Returns relative paths.
---@param symbol string
---@param exclude string|nil
---@return string[]
function M.grep_files(symbol, exclude)
  local bin = require("agent_core.platform").resolve_bin("rg")
  if bin == "" then
    return {}
  end
  local root = require("agent_core.indexer").root()
  local ok, out = pcall(vim.fn.systemlist, {
    bin,
    "-l",
    "--max-count",
    "2",
    "-F",
    symbol,
    root,
  })
  if not ok or vim.v.shell_error ~= 0 then
    return {}
  end
  local res = {}
  for _, line in ipairs(out or {}) do
    line = line:gsub("[\r\n]", ""):gsub("\\", "/")
    if line ~= "" then
      local rootn = root:gsub("\\", "/")
      local rel = line:gsub("^" .. vim.pesc(rootn) .. "/", "")
      if rel ~= line and (not exclude or rel ~= exclude) then
        res[#res + 1] = rel
      end
    end
  end
  return res
end

--- Read a file's lines, or nil when unreadable.
---@param rel string
---@return string[]|nil
function M.read_file(rel)
  local root = require("agent_core.indexer").root()
  local abs = root .. "/" .. rel
  if vim.fn.filereadable(abs) ~= 1 then
    return nil
  end
  return vim.fn.readfile(abs)
end

--- Assemble cross-file context for a symbol: the current file plus up to
--- `context_files` grep-matched files, bounded by `max_files`/`max_chars`.
--- Returns a prompt-ready string and the ordered file list.
---@param symbol string
---@return string context
---@return string[] files
function M.gather_context(symbol)
  local files = {}
  local seen = {}
  local function push(rel)
    if rel and rel ~= "" and not seen[rel] then
      seen[rel] = true
      files[#files + 1] = rel
    end
  end

  local current = M.current_rel_path()
  push(current)

  local max_files = M.config.max_files or 8
  for _, rel in ipairs(M.grep_files(symbol, current)) do
    if #files >= max_files then
      break
    end
    push(rel)
  end

  local parts = { "CROSS-FILE USAGE for symbol: " .. symbol, "" }
  local total = 0
  local max_chars = M.config.max_chars or 20000
  local included = {}
  for _, rel in ipairs(files) do
    local lines = M.read_file(rel)
    if lines then
      local block = "### " .. rel .. "\n```\n" .. table.concat(lines, "\n") .. "\n```"
      if total + #block <= max_chars or #included == 0 then
        included[#included + 1] = rel
        parts[#parts + 1] = block
        parts[#parts + 1] = ""
        total = total + #block
      else
        break
      end
    end
  end

  return table.concat(parts, "\n"), included
end

--- Parse a model response into a normalized edit list, or nil on failure.
---@param text string
---@return table[]|nil
function M.parse_edits(text)
  if not text or text == "" then
    return nil
  end
  local stripped = text:gsub("^```[%w]*%s*", ""):gsub("%s*```$", "")
  local ok, data = pcall(vim.json.decode, stripped)
  if not ok or type(data) ~= "table" then
    return nil
  end
  local out = {}
  for _, e in ipairs(data) do
    if type(e) == "table" and type(e.path) == "string" and type(e.find) == "string" and type(e.replace) == "string" then
      out[#out + 1] = { path = e.path, find = e.find, replace = e.replace }
    end
  end
  if #out == 0 then
    return nil
  end
  return out
end

--- Validate an edit's path: relative, no traversal, inside the repo root.
---@param rel string
---@return boolean ok
---@return string|nil err
function M.validate_path(rel)
  if not rel or rel == "" then
    return false, "empty path"
  end
  if require("agent_core.platform").is_abs(rel) then
    return false, "absolute path rejected: " .. rel
  end
  if rel:find("..", 1, true) then
    return false, "path traversal rejected: " .. rel
  end
  return true, nil
end

--- Replace the first literal occurrence of `needle` in `haystack`.
--- Returns the new string, or nil when `needle` is not present.
---@param haystack string
---@param needle string
---@param replacement string
---@return string|nil
function M.replace_first(haystack, needle, replacement)
  local s = haystack:find(needle, 1, true)
  if not s then
    return nil
  end
  return haystack:sub(1, s - 1) .. replacement .. haystack:sub(s + #needle)
end

--- Produce a unified-style diff text between two line lists.
---@param old_lines string[]
---@param new_lines string[]
---@param path string
---@return string
function M.unified_diff(old_lines, new_lines, path)
  local Diff = require("agent_core.diff")
  local hunks = Diff.compute_hunks(old_lines, new_lines)
  local out = { "diff --git a/" .. path .. " b/" .. path }
  for _, h in ipairs(hunks) do
    out[#out + 1] = string.format("@@ -%d,%d +%d,%d @@", h.start_a, h.count_a or 0, h.start_b, h.count_b or 0)
    for i = h.start_a, h.start_a + (h.count_a or 0) - 1 do
      out[#out + 1] = "-" .. (old_lines[i] or "")
    end
    for i = h.start_b, h.start_b + (h.count_b or 0) - 1 do
      out[#out + 1] = "+" .. (new_lines[i] or "")
    end
  end
  return table.concat(out, "\n")
end

--- Run a coordinated multi-file edit for the symbol under the caret.
---@param cb fun(ok:boolean, msg:string|nil)
function M.coordinated_edit(cb)
  cb = cb or function() end
  if not M.config.enabled then
    cb(false, "coordinated edits disabled")
    return
  end
  local symbol = M.symbol_under_caret()
  if not symbol then
    cb(false, "no symbol under the caret")
    return
  end

  local profile = M.resolve_profile()
  if not profile then
    cb(false, "no profile resolved for coordinated edit")
    return
  end

  local context = M.gather_context(symbol)
  local Runner = require("agent_core.runner")
  Runner.llm_curl(profile, {
    system_prompt = EDIT_SYSTEM,
    user_prompt = context .. "\n\nReturn the coordinated edit set as a JSON array for symbol `" .. symbol .. "`.",
  }, function(result)
    if result.error or not result.text then
      cb(false, result.error or "no response")
      return
    end
    local edits = M.parse_edits(result.text)
    if not edits then
      cb(false, "no valid JSON edit set in response")
      return
    end

    local ok_cp, Checkpoint = pcall(require, "agent_core.checkpoint")
    if ok_cp and Checkpoint.create then
      Checkpoint.create("coordinated-edit")
    end

    local root = require("agent_core.indexer").root()
    local applied = {}
    for _, edit in ipairs(edits) do
      local vok, verr = M.validate_path(edit.path)
      if not vok then
        cb(false, verr)
        return
      end
      local abs = root .. "/" .. edit.path
      if vim.fn.filereadable(abs) ~= 1 then
        cb(false, "file not readable: " .. edit.path)
        return
      end
      local old_lines = vim.fn.readfile(abs)
      local old_text = table.concat(old_lines, "\n")
      local new_text = M.replace_first(old_text, edit.find, edit.replace)
      if not new_text then
        cb(false, "find not matched in " .. edit.path .. ": " .. edit.find:sub(1, 60))
        return
      end
      local new_lines = vim.split(new_text, "\n", { plain = true })
      vim.fn.writefile(new_lines, abs)
      applied[#applied + 1] = { path = edit.path, old_lines = old_lines, new_lines = new_lines }
    end

    local diff_parts = {}
    for _, a in ipairs(applied) do
      diff_parts[#diff_parts + 1] = M.unified_diff(a.old_lines, a.new_lines, a.path)
    end
    local diff_text = table.concat(diff_parts, "\n\n")

    if #vim.api.nvim_list_uis() == 0 then
      cb(true, "applied " .. #applied .. " edit(s); :AgentRollback to undo")
      return
    end

    require("agent_core.diff").present_text({
      text = diff_text,
      label = "coordinated-edit",
      on_apply = function()
        cb(true, "applied " .. #applied .. " edit(s); :AgentRollback to undo")
      end,
      on_dismiss = function()
        local ok_roll, Rollback = pcall(require, "agent_core.checkpoint")
        if ok_roll and Rollback.rollback then
          local list = Rollback.load()
          if #list > 0 then
            Rollback.rollback(list[#list])
          end
        end
        cb(false, "coordinated edit cancelled (rolled back)")
      end,
    })
  end)
end

--- Backing for :AgentCoordinatedEdit.
function M.coordinated_edit_cmd()
  vim.notify("CoordinatedEdit: gathering context…", vim.log.levels.INFO)
  M.coordinated_edit(function(ok, msg)
    vim.notify("CoordinatedEdit: " .. tostring(msg), ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

function M.setup()
  local cfg = require("agent_core").config
  M.config = vim.tbl_deep_extend("force", M.config, cfg.edits or {})
end

return M
