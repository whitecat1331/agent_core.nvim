---@mod tests.checkpoint_spec Unit tests for agent_core.checkpoint.

local h = require("tests.harness")
local Checkpoint = require("agent_core.checkpoint")

local function with_tmp_dir(fn)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local saved_dir = Checkpoint.dir
  Checkpoint.dir = function()
    return tmp
  end
  local ok, err = pcall(fn)
  Checkpoint.dir = saved_dir
  vim.fn.delete(tmp, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("checkpoint.slugify", function()
  h.it("normalizes labels", function()
    h.equals("my-label", Checkpoint.slugify("My Label!"))
    h.equals("checkpoint", Checkpoint.slugify(""))
  end)
end)

h.describe("checkpoint persistence", function()
  h.it("save/load registry roundtrip", function()
    with_tmp_dir(function()
      local list = { { label = "before", path = "/x.patch", created = 123 } }
      h.truthy(Checkpoint.save(list), "save should succeed")
      local loaded = Checkpoint.load()
      h.equals(1, #loaded)
      h.equals("before", loaded[1].label)
    end)
  end)

  h.it("load returns {} when the registry is missing", function()
    with_tmp_dir(function()
      h.same({}, Checkpoint.load())
    end)
  end)
end)

h.describe("checkpoint.load_manifest", function()
  h.it("reads an untracked manifest", function()
    with_tmp_dir(function()
      local mf_path = vim.fn.tempname()
      local f = io.open(mf_path, "w")
      f:write(vim.json.encode({ { path = "a.txt", content = { "x" } } }))
      f:close()
      local entry = { untracked = mf_path }
      local manifest = Checkpoint.load_manifest(entry)
      h.equals(1, #manifest)
      h.equals("a.txt", manifest[1].path)
      vim.fn.delete(mf_path)
    end)
  end)

  h.it("returns {} for missing entry/untracked", function()
    h.same({}, Checkpoint.load_manifest(nil))
    h.same({}, Checkpoint.load_manifest({}))
  end)
end)
