---@mod tests.plan_spec Unit tests for agent_core.plan + plan_manager.

local h = require("tests.harness")
local Plan = require("agent_core.plan")
local PlanManager = require("agent_core.plan_manager")

local function with_tmp_dir(fn)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local saved_dir = Plan.dir
  local saved_ideas = Plan.ideas_file
  Plan.dir = function()
    return tmp .. "/plans"
  end
  Plan.ideas_file = function()
    return tmp .. "/ideas.json"
  end
  local ok, err = pcall(fn)
  Plan.dir = saved_dir
  Plan.ideas_file = saved_ideas
  vim.fn.delete(tmp, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("plan.slugify", function()
  h.it("normalizes titles", function()
    h.equals("my-plan", Plan.slugify("My Plan!"))
    h.equals("plan", Plan.slugify(""))
  end)
end)

h.describe("plan persistence", function()
  h.it("write_plan/latest_plan roundtrip", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("My Plan", "- [ ] step 1")
      h.truthy(ok, "write should succeed")
      h.truthy(path and vim.fn.filereadable(path) == 1, "plan file should exist")
      local function norm(p)
        return (p:gsub("\\", "/"))
      end
      h.equals(norm(path), norm(Plan.latest_plan()))
    end)
  end)

  h.it("resolve_path prefers an explicit argument", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("T", "body")
      h.truthy(ok)
      local resolved = Plan.resolve_path(path)
      h.equals(1, vim.fn.filereadable(resolved), "resolved path should be readable")
    end)
  end)

  h.it("write_plan writes frontmatter with status draft", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("Frontmatter Plan", "body text")
      h.truthy(ok)
      local lines = vim.fn.readfile(path)
      h.equals("---", lines[1])
      h.equals("status: draft", lines[2])
      h.matches("^created: ", lines[3])
      h.equals("---", lines[4])
      h.equals("draft", Plan.read_status(path))
    end)
  end)
end)

h.describe("plan status", function()
  h.it("read_status defaults missing frontmatter to draft", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("No Fm", "body")
      h.truthy(ok)
      -- Strip the frontmatter to simulate a legacy plan.
      local lines = vim.fn.readfile(path)
      local body = table.concat(vim.list_slice(lines, 5, #lines), "\n")
      local f = io.open(path, "w")
      f:write(body)
      f:close()
      h.equals("draft", Plan.read_status(path))
    end)
  end)

  h.it("set_status roundtrips and preserves the body", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("Cycle Me", "# Header\n\nsome body")
      h.truthy(ok)
      local ok2 = Plan.set_status(path, "in_progress")
      h.truthy(ok2)
      h.equals("in_progress", Plan.read_status(path))
      local content = table.concat(vim.fn.readfile(path), "\n")
      h.matches("some body", content, "body preserved after set_status")
    end)
  end)

  h.it("status_cycle walks draft → in_progress → completed → abandoned → draft", function()
    h.equals("in_progress", Plan.status_cycle("draft"))
    h.equals("completed", Plan.status_cycle("in_progress"))
    h.equals("abandoned", Plan.status_cycle("completed"))
    h.equals("draft", Plan.status_cycle("abandoned"))
    h.equals("in_progress", Plan.status_cycle("unknown"), "unknown resets to draft then cycles")
  end)

  h.it("cycle_status advances the stored status", function()
    with_tmp_dir(function()
      local ok, path = Plan.write_plan("Cycle", "body")
      h.truthy(ok)
      h.equals("in_progress", Plan.cycle_status(path))
      h.equals("completed", Plan.cycle_status(path))
      h.equals("abandoned", Plan.cycle_status(path))
      h.equals("draft", Plan.cycle_status(path))
    end)
  end)

  h.it("list returns parsed statuses and titles", function()
    with_tmp_dir(function()
      local ok, a = Plan.write_plan("Alpha", "1")
      h.truthy(ok)
      local ok2, b = Plan.write_plan("Beta", "2")
      h.truthy(ok2)
      Plan.set_status(b, "completed")
      local items = Plan.list()
      h.equals(2, #items)
      local by_title = {}
      for _, it in ipairs(items) do
        by_title[it.title] = it
      end
      h.truthy(by_title["Alpha"], "alpha listed")
      h.equals("draft", by_title["Alpha"].status)
      h.truthy(by_title["Beta"], "beta listed")
      h.equals("completed", by_title["Beta"].status)
    end)
  end)
end)

h.describe("plan summary", function()
  h.it("empty dir is all zeros", function()
    with_tmp_dir(function()
      local s = Plan.summary()
      h.equals(0, s.unfinished)
      h.equals(0, s.archived)
      h.equals(0, s.ideas)
    end)
  end)

  h.it("counts unfinished, archived, and ideas", function()
    with_tmp_dir(function()
      local _, a = Plan.write_plan("Draft Plan", "x")
      h.truthy(a)
      local _, b = Plan.write_plan("Done Plan", "y")
      h.truthy(b)
      Plan.set_status(b, "completed")
      Plan.add_idea("One", "")
      Plan.add_idea("Two", "")

      local s = Plan.summary()
      h.equals(1, s.unfinished, "one draft")
      h.equals(1, s.archived, "one completed")
      h.equals(2, s.ideas, "two ideas")
    end)
  end)
end)

h.describe("plan change notification", function()
  h.it("mutations fire User AgentPlanChanged", function()
    with_tmp_dir(function()
      local fired = 0
      local group = vim.api.nvim_create_augroup("AgentPlanChangedTest", { clear = true })
      vim.api.nvim_create_autocmd("User", {
        group = group,
        pattern = "AgentPlanChanged",
        callback = function()
          fired = fired + 1
        end,
      })

      Plan.write_plan("A", "body")
      h.truthy(fired >= 1, "write_plan fires AgentPlanChanged")

      local before_idea = fired
      Plan.add_idea("Idea", "")
      h.truthy(fired > before_idea, "add_idea fires AgentPlanChanged")

      local before_status = fired
      local ok, path = Plan.write_plan("B", "body")
      h.truthy(ok)
      Plan.set_status(path, "completed")
      h.truthy(fired > before_status, "set_status fires AgentPlanChanged")

      vim.api.nvim_del_augroup_by_id(group)
    end)
  end)
end)

h.describe("plan ideas", function()
  h.it("add_idea/ideas roundtrip", function()
    with_tmp_dir(function()
      local ok, id = Plan.add_idea("Add plan manager", "discussed, never drafted")
      h.truthy(ok)
      h.truthy(id, "id returned")
      local ideas = Plan.ideas()
      h.equals(1, #ideas)
      h.equals("Add plan manager", ideas[1].title)
      h.equals("discussed, never drafted", ideas[1].notes)
    end)
  end)

  h.it("remove_idea deletes by id", function()
    with_tmp_dir(function()
      local _, id = Plan.add_idea("Keep", "")
      local _, id2 = Plan.add_idea("Drop", "")
      local ok = Plan.remove_idea(id2)
      h.truthy(ok)
      local ideas = Plan.ideas()
      h.equals(1, #ideas)
      h.equals(id, ideas[1].id)
    end)
  end)

  h.it("promote_idea writes a plan and removes the idea", function()
    with_tmp_dir(function()
      local _, id = Plan.add_idea("Promote Me", "plan body notes")
      local ok, path = Plan.promote_idea(id)
      h.truthy(ok)
      h.truthy(path and vim.fn.filereadable(path) == 1, "plan file written")
      h.equals("draft", Plan.read_status(path))
      h.equals(0, #Plan.ideas(), "idea removed after promotion")
    end)
  end)
end)

h.describe("plan_manager", function()
  h.it("rows renders sections and maps plans + ideas", function()
    with_tmp_dir(function()
      local _, a = Plan.write_plan("Unfinished Plan", "x")
      Plan.set_status(a, "in_progress")
      local _, b = Plan.write_plan("Done Plan", "y")
      Plan.set_status(b, "completed")
      Plan.add_idea("An Idea", "note")

      local data = PlanManager.rows()
      h.truthy(#data.lines > 0, "rows are non-empty")
      local text = table.concat(data.lines, "\n")
      h.matches("# Unfinished plans", text)
      h.matches("# Completed / abandoned", text)
      h.matches("# Ideas", text)
      h.matches("An Idea", text)

      -- At least one plan row and one idea row map to their actions.
      local plan_row, idea_row
      for row, action in pairs(data.map) do
        if action.type == "plan" then
          plan_row = row
        elseif action.type == "idea" then
          idea_row = row
        end
      end
      h.truthy(plan_row, "a plan row maps to a plan action")
      h.truthy(idea_row, "an idea row maps to an idea action")
      h.truthy(data.map[idea_row].id, "idea action carries an id")
    end)
  end)

  h.it("header lists the keymap legend", function()
    local header = PlanManager.header()
    h.truthy(#header > 0, "header non-empty")
  end)

  h.it("open is a headless no-op", function()
    -- No UI attached in headless tests, so open() must not error.
    PlanManager.open()
    h.equals(nil, PlanManager.action_at())
  end)

  h.it("summary delegates to plan.summary", function()
    with_tmp_dir(function()
      Plan.add_idea("Delegated", "")
      local s = PlanManager.summary()
      h.equals(1, s.ideas)
      h.equals(0, s.unfinished)
      h.equals(0, s.archived)
    end)
  end)

  h.it("badge_text summarizes outstanding counts", function()
    with_tmp_dir(function()
      Plan.add_idea("Badge Idea", "")
      h.matches("1 idea", PlanManager.badge_text())
      local _, a = Plan.write_plan("Badge Plan", "x")
      h.truthy(a)
      h.matches("1 unfinished plan", PlanManager.badge_text())
    end)
  end)

  h.it("open_badge/toggle/dismiss are headless no-ops", function()
    -- No UI attached in headless tests, so badge operations must not error.
    PlanManager.open_badge()
    PlanManager.toggle()
    PlanManager.dismiss()
    h.equals(nil, PlanManager.action_at())
  end)
end)
