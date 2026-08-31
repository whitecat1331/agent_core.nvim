---@mod tests.workspace_spec Unit tests for agent_core.workspace.

local h = require("tests.harness")
local Workspace = require("agent_core.workspace")

local function with_registry(fn)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local saved_rp = Workspace.registry_path
  Workspace.registry_path = function()
    return tmp .. "/workspace.json"
  end
  local ok, err = pcall(fn)
  Workspace.registry_path = saved_rp
  vim.fn.delete(tmp, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("workspace persistence", function()
  h.it("load/save roundtrip", function()
    with_registry(function()
      local projects = { { path = "/a", name = "a", summary = "s", added_at = 1 } }
      h.truthy(Workspace.save(projects), "save should succeed")
      local loaded = Workspace.load()
      h.equals(1, #loaded)
      h.equals("/a", loaded[1].path)
      h.equals("s", loaded[1].summary)
    end)
  end)

  h.it("load returns {} when the registry is missing", function()
    with_registry(function()
      h.same({}, Workspace.load())
    end)
  end)
end)

h.describe("workspace.add", function()
  h.it("registers a project and derives a summary", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local saved_rp = Workspace.registry_path
    Workspace.registry_path = function()
      return tmp .. "/workspace.json"
    end

    local Indexer = require("agent_core.indexer")
    local McpIndex = require("agent_core.mcp_index")
    local saved_root_for = Indexer.root_for
    local saved_summary = Indexer.summary_for
    local saved_wg = McpIndex.write_global
    local saved_ip = McpIndex.index_project
    Indexer.root_for = function()
      return "/a"
    end
    Indexer.summary_for = function()
      return "summary"
    end
    McpIndex.write_global = function() end
    McpIndex.index_project = function()
      return true
    end

    local ok, err = pcall(function()
      local entry = Workspace.add(tmp)
      h.truthy(entry, "entry should be returned")
      h.equals("/a", entry.path)
      h.equals("summary", entry.summary)
    end)

    Indexer.root_for = saved_root_for
    Indexer.summary_for = saved_summary
    McpIndex.write_global = saved_wg
    McpIndex.index_project = saved_ip
    Workspace.registry_path = saved_rp
    vim.fn.delete(tmp, "rf")
    if not ok then
      error(err, 0)
    end
  end)
end)

h.describe("workspace.activate", function()
  h.it("refreshes the brief for the activated project", function()
    local Indexer = require("agent_core.indexer")
    local saved_refresh = Indexer.refresh
    local refreshed = false
    Indexer.refresh = function()
      refreshed = true
    end
    local cwd = vim.fn.getcwd()
    Workspace.activate({ path = cwd, name = "current" })
    h.truthy(refreshed, "refresh should be called")
    Indexer.refresh = saved_refresh
  end)
end)

h.describe("workspace.get_workspace_prompt", function()
  h.it("formats registered projects", function()
    with_registry(function()
      Workspace.save({ { path = "/a", name = "alpha", summary = "the alpha project", added_at = 1 } })
      local prompt = Workspace.get_workspace_prompt()
      h.matches("Registered workspace projects", prompt)
      h.matches("alpha", prompt)
      h.matches("/a", prompt)
    end)
  end)

  h.it("returns an empty string when nothing is registered", function()
    with_registry(function()
      h.equals("", Workspace.get_workspace_prompt())
    end)
  end)
end)
