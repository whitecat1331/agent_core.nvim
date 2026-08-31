---@mod agent_core.platform OS/binary/path helpers for cross-platform parity.
---@brief [[
--- Centralizes the few OS-specific decisions agent_core needs so the plugin
--- behaves identically on Linux, macOS, and Windows: Windows detection, absolute
--- path detection (POSIX, drive-letter, and UNC), binary resolution (absolute
--- paths pass through; bare names go through vim.fn.exepath), path joining with
--- forward slashes, and a shell-appropriate command joiner. Also provides an
--- os_hint() string so the model gets correct shell/path instructions.
---@brief ]]

local M = {}

--- True on Windows (native Neovim, not WSL).
---@return boolean
function M.is_windows()
  return vim.fn.has("win32") == 1
end

--- True for an absolute path: POSIX `/`, home `~`, Windows drive `C:\`/`C:/`,
--- or UNC `\\server\share`.
---@param path string|nil
---@return boolean
function M.is_abs(path)
  if not path or path == "" then
    return false
  end
  return path:match("^/") ~= nil
    or path:match("^~") ~= nil
    or path:match("^%a:[/\\]") ~= nil
    or path:match("^\\\\") ~= nil
end

--- Resolve a binary name to an absolute path when possible. Absolute/`~` paths
--- are expanded and returned unchanged; bare names go through vim.fn.exepath
--- (PATH lookup). Returns the original name when it cannot be resolved.
---@param name string
---@return string
function M.resolve_bin(name)
  name = name or ""
  if name == "" then
    return ""
  end
  if name:sub(1, 1) == "~" then
    return vim.fn.expand(name)
  end
  if M.is_abs(name) then
    return name
  end
  local resolved = vim.fn.exepath(name)
  if resolved and resolved ~= "" then
    return resolved
  end
  return name
end

--- Join path parts with forward slashes, normalizing backslashes. Neovim
--- accepts `/` on Windows, so this yields portable paths everywhere.
---@param ... string|nil
---@return string
function M.join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then
      table.insert(parts, (tostring(p):gsub("\\", "/")))
    end
  end
  return table.concat(parts, "/")
end

--- Shell-appropriate command joiner: `&&` on POSIX, `;` on Windows (where
--- cmd.exe and PowerShell do not support `&&` in all contexts).
---@return string
function M.shell_and()
  if M.is_windows() then
    return ";"
  end
  return "&&"
end

--- Neovim caret/autocmd event names, isolated here so the rest of the plugin
--- never references the raw Neovim API/event strings directly.
M.events = {
  caret_moved = "CursorMoved",
  caret_moved_i = "CursorMovedI",
  insert_leave = "InsertLeave",
  mode_changed = "ModeChanged",
}

--- Read the caret position (zero-based row, byte column) for a window.
---@param win integer|nil nil = current window
---@return integer row
---@return integer col
function M.get_caret(win)
  local pos = vim.api.nvim_win_get_cursor(win or 0)
  return pos[1] - 1, pos[2]
end

--- Move the caret for a window to a one-based (row, col) position.
---@param win integer|nil nil = current window
---@param row integer one-based line
---@param col integer byte column
function M.set_caret(win, row, col)
  vim.api.nvim_win_set_cursor(win or 0, { row, col })
end

--- Detect Windows Subsystem for Linux via /proc/version.
---@return boolean
function M.is_wsl()
  if M.is_windows() then
    return false
  end
  if vim.fn.has("wsl") == 1 then
    return true
  end
  local f = io.open("/proc/version", "r")
  if not f then
    return false
  end
  local content = f:read("*a")
  f:close()
  return content ~= nil and content:find("microsoft", 1, true) ~= nil
end

--- Use Windows clip.exe for the system clipboard on WSL (avoids broken xclip/DISPLAY).
--- Skips when the user or LazyVim already configured vim.g.clipboard.
---@return boolean configured
function M.ensure_wsl_clipboard()
  if not M.is_wsl() then
    return false
  end
  if type(vim.g.clipboard) == "table" and vim.g.clipboard.name then
    return false
  end
  if vim.fn.executable("clip.exe") ~= 1 then
    return false
  end
  vim.g.clipboard = {
    name = "AgentCoreWslClipboard",
    copy = {
      ["+"] = "clip.exe",
      ["*"] = "clip.exe",
    },
    paste = {
      ["+"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).ToString())',
      ["*"] = 'powershell.exe -NoLogo -NoProfile -c [Console]::Out.Write($(Get-Clipboard -Raw).ToString())',
    },
    cache_enabled = 0,
  }
  return true
end

--- Short model-facing hint describing the OS, shell, and path style.
---@return string
function M.os_hint()
  if M.is_windows() then
    return [[IMPORTANT: You are operating on Windows.
Use PowerShell commands where possible.
File paths may use either backslashes (C:\path\to\file) or forward slashes.]]
  end
  if M.is_wsl() then
    return [[IMPORTANT: You are operating inside a Linux WSL (Ubuntu) environment.
Use standard Bash commands like ls, cat, grep, and find.
Always use forward slashes (/) for file paths.]]
  end
  local sysname = ""
  local ok, uv = pcall(require, "vim.uv")
  if ok and uv.os_uname then
    local ok2, uname = pcall(uv.os_uname)
    if ok2 and uname and uname.sysname then
      sysname = uname.sysname
    end
  end
  if sysname == "Darwin" then
    return [[IMPORTANT: You are operating on macOS.
Use standard Bash or zsh commands like ls, cat, grep, and find.
Always use forward slashes (/) for file paths.]]
  end
  return [[IMPORTANT: You are operating inside a Linux environment.
Use standard Bash commands like ls, cat, grep, and find.
Always use forward slashes (/) for file paths.]]
end

return M
