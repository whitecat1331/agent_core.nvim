---@mod tests.harness Minimal dependency-free test harness.
---@brief [[
--- Zero-dependency BDD-ish runner for agent_core.nvim unit tests. Registers
--- describe/it blocks, provides assertion helpers that fail with file:line and
--- a message, and a run() that prints PASS/FAIL per test plus a summary and a
--- AGENT_CORE_TESTS_OK sentinel on success (so CI/hooks can grep for it).
--- Exits non-zero via vim.cmd("cquit") on any failure.
---@brief ]]

local M = {}

---@class TestCase
---@field name string
---@field file string
---@field line integer
---@field fn fun()
local suites = {} ---@type {name:string, cases:TestCase[]}[]

local current_suite ---@type {name:string, cases:TestCase[]}|nil

--- Register a describe block.
---@param name string
---@param fn fun()
function M.describe(name, fn)
  local suite = { name = name, cases = {} }
  suites[#suites + 1] = suite
  local prev = current_suite
  current_suite = suite
  fn()
  current_suite = prev
end

--- Register a single test case.
---@param name string
---@param fn fun()
function M.it(name, fn)
  if not current_suite then
    current_suite = { name = "(top level)", cases = {} }
    suites[#suites + 1] = current_suite
  end
  local info = debug.getinfo(2, "Sl")
  current_suite.cases[#current_suite.cases + 1] = {
    name = name,
    file = info and info.short_src or "?",
    line = info and info.currentline or 0,
    fn = fn,
  }
end

---@class AssertionContext
---@field file string
---@field line integer
local ctx = { file = "?", line = 0 }

--- Capture caller location for failure messages.
local function locate(level)
  local info = debug.getinfo(level, "Sl")
  ctx.file = info and info.short_src or "?"
  ctx.line = info and info.currentline or 0
end

---@param msg string
local function fail(msg)
  error(string.format("%s:%d: %s", ctx.file, ctx.line, msg), 0)
end

---@param expected any
---@param actual any
---@param msg string|nil
local function format_failure(expected, actual, msg)
  local suffix = msg and ("\n  " .. msg) or ""
  return string.format(
    "assertion failed\n  expected: %s\n  actual:   %s%s",
    vim.inspect(expected),
    vim.inspect(actual),
    suffix
  )
end

---@param v any
---@param msg string|nil
function M.truthy(v, msg)
  locate(2)
  if not v then
    fail(format_failure(true, v, msg))
  end
end

---@param v any
---@param msg string|nil
function M.falsy(v, msg)
  locate(2)
  if v then
    fail(format_failure(false, v, msg))
  end
end

---@param expected any
---@param actual any
---@param msg string|nil
function M.equals(expected, actual, msg)
  locate(2)
  if expected ~= actual then
    fail(format_failure(expected, actual, msg))
  end
end

---@param expected any
---@param actual any
---@param msg string|nil
function M.not_equals(expected, actual, msg)
  locate(2)
  if expected == actual then
    fail(format_failure("not " .. vim.inspect(expected), actual, msg))
  end
end

--- Deep equality (tables compared recursively; keys must match exactly).
---@param a any
---@param b any
---@return boolean
local function deep_equal(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---@param expected any
---@param actual any
---@param msg string|nil
function M.same(expected, actual, msg)
  locate(2)
  if not deep_equal(expected, actual) then
    fail(format_failure(expected, actual, msg))
  end
end

---@param haystack table
---@param needle any
---@param msg string|nil
function M.contains(haystack, needle, msg)
  locate(2)
  if not vim.tbl_contains(haystack, needle) then
    fail(format_failure(needle, haystack, msg or "expected element not found in table"))
  end
end

---@param pattern string|fun(string):string|nil
---@param str string
---@param msg string|nil
function M.matches(pattern, str, msg)
  locate(2)
  local ok = false
  if type(pattern) == "function" then
    ok = pattern(str) ~= nil
  else
    ok = str:find(pattern) ~= nil
  end
  if not ok then
    fail(format_failure("match: " .. tostring(pattern), str, msg))
  end
end

--- Assert a function raises an error.
---@param fn fun()
---@param msg string|nil
function M.throws(fn, msg)
  locate(2)
  local ok = pcall(fn)
  if ok then
    fail(format_failure("an error", "no error", msg or "expected function to throw"))
  end
end

--- Run all registered tests and print a report.
---@return boolean ok
function M.run()
  local total = 0
  local passed = 0
  local failed = 0

  for _, suite in ipairs(suites) do
    print("== " .. suite.name .. " ==")
    for _, case in ipairs(suite.cases) do
      total = total + 1
      local ok, err = pcall(case.fn)
      if ok then
        passed = passed + 1
        print(string.format("  PASS  %s", case.name))
      else
        failed = failed + 1
        print(string.format("  FAIL  %s", case.name))
        print("        " .. tostring(err):gsub("\n", "\n        "))
      end
    end
  end

  print(string.format("--- %d tests, %d passed, %d failed ---", total, passed, failed))
  if failed > 0 then
    print("AGENT_CORE_TESTS_FAILED")
    vim.cmd("cquit 1")
    return false
  end
  print("AGENT_CORE_TESTS_OK")
  return true
end

return M
