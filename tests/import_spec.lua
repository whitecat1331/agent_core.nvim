---@mod tests.import_spec Unit tests for agent_core.import.

local h = require("tests.harness")
local Import = require("agent_core.import")

--- Normalize path separators so Windows glob output (backslashes) compares
--- cleanly against the forward-slash strings the module builds for dst.
---@param p string|nil
---@return string
local function norm(p)
  return (p or ""):gsub("\\", "/")
end

--- Find a plan entry whose normalized dst matches, or nil.
---@param plan {src:string,dst:string}[]
---@param dst string
---@return {src:string,dst:string}|nil
local function find_by_dst(plan, dst)
  for _, item in ipairs(plan) do
    if norm(item.dst) == norm(dst) then
      return item
    end
  end
  return nil
end

h.describe("import", function()
  h.it("cursor_plan maps project .cursor/rules *.mdc and *.md to .agent_core/rules", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.cursor/rules", "p")
    vim.fn.writefile({ "rule a" }, root .. "/.cursor/rules/a.mdc")
    vim.fn.writefile({ "rule b" }, root .. "/.cursor/rules/b.md")

    local plan = Import.cursor_plan(root, vim.fn.tempname())
    local a = find_by_dst(plan, root .. "/.agent_core/rules/a.mdc")
    local b = find_by_dst(plan, root .. "/.agent_core/rules/b.md")
    h.truthy(a ~= nil, "a.mdc should be planned")
    h.equals(norm(root .. "/.cursor/rules/a.mdc"), norm(a.src))
    h.truthy(b ~= nil, "b.md should be planned")
    h.equals(norm(root .. "/.cursor/rules/b.md"), norm(b.src))
    vim.fn.delete(root, "rf")
  end)

  h.it("cursor_plan maps project .cursor/skills/*/SKILL.md preserving the skill name", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.cursor/skills/deploy", "p")
    vim.fn.writefile({ "deploy steps" }, root .. "/.cursor/skills/deploy/SKILL.md")

    local plan = Import.cursor_plan(root, vim.fn.tempname())
    local entry = find_by_dst(plan, root .. "/.agent_core/skills/deploy/SKILL.md")
    h.truthy(entry ~= nil, "skill should be planned")
    h.equals(norm(root .. "/.cursor/skills/deploy/SKILL.md"), norm(entry.src))
    vim.fn.delete(root, "rf")
  end)

  h.it("cursor_plan rewrites root instruction files to neutral filenames", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "cursor md" }, root .. "/CURSOR.md")
    vim.fn.writefile({ "legacy" }, root .. "/.cursorrules")

    local plan = Import.cursor_plan(root, vim.fn.tempname())
    local ide = find_by_dst(plan, root .. "/.agent_core/rules/ide_instructions.md")
    local legacy = find_by_dst(plan, root .. "/.agent_core/rules/legacy_instructions.md")
    h.truthy(ide ~= nil, "CURSOR.md should be planned")
    h.equals(norm(root .. "/CURSOR.md"), norm(ide.src))
    h.truthy(legacy ~= nil, ".cursorrules should be planned")
    h.equals(norm(root .. "/.cursorrules"), norm(legacy.src))
    vim.fn.delete(root, "rf")
  end)

  h.it("cursor_plan produces no project entries when the root has no source files", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root, "p")
    local plan = Import.cursor_plan(root, vim.fn.tempname())
    for _, item in ipairs(plan) do
      h.falsy(norm(item.src):sub(1, #norm(root)) == norm(root), "no plan entry should originate under the empty root")
    end
    vim.fn.delete(root, "rf")
  end)

  h.it("vscode_plan maps copilot-instructions.md to a neutral rule file", function()
    local root = vim.fn.tempname()
    vim.fn.mkdir(root .. "/.github", "p")
    vim.fn.writefile({ "copilot" }, root .. "/.github/copilot-instructions.md")

    local plan = Import.vscode_plan(root, vim.fn.tempname())
    h.equals(1, #plan)
    h.equals(norm(root .. "/.github/copilot-instructions.md"), norm(plan[1].src))
    h.equals(norm(root .. "/.agent_core/rules/copilot_instructions.md"), norm(plan[1].dst))
    vim.fn.delete(root, "rf")
  end)

  h.it("import_plan copies files non-destructively and skips existing destinations", function()
    local src = vim.fn.tempname()
    vim.fn.writefile({ "payload" }, src)
    local dst = vim.fn.tempname() .. "/out.md"
    vim.fn.mkdir(vim.fn.fnamemodify(dst, ":h"), "p")

    local first = Import.import_plan({ { src = src, dst = dst } })
    h.equals(1, #first.copied)
    h.equals(0, #first.skipped)
    h.equals("payload", table.concat(vim.fn.readfile(dst), "\n"))

    local second = Import.import_plan({ { src = src, dst = dst } })
    h.equals(0, #second.copied)
    h.equals(1, #second.skipped)
    h.equals(norm(dst), norm(second.skipped[1]))

    vim.fn.delete(src, "rf")
    vim.fn.delete(vim.fn.fnamemodify(dst, ":h"), "rf")
  end)

  h.it("import_plan returns an empty report for an empty plan", function()
    local report = Import.import_plan({})
    h.equals(0, #report.copied)
    h.equals(0, #report.skipped)
  end)
end)
