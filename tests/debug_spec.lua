---@mod tests.debug_spec Unit tests for agent_core.debug.

local h = require("tests.harness")
local Debug = require("agent_core.debug")

local function with_tmp_session(fn)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, "p")
  local saved_dir = Debug.dir
  local saved_sp = Debug.session_path
  Debug.dir = function()
    return tmp
  end
  Debug.session_path = function()
    return tmp .. "/session.json"
  end
  local ok, err = pcall(fn)
  Debug.dir = saved_dir
  Debug.session_path = saved_sp
  vim.fn.delete(tmp, "rf")
  if not ok then
    error(err, 0)
  end
end

h.describe("debug.slugify", function()
  h.it("normalizes roots", function()
    h.equals("my-root", Debug.slugify("My Root"))
    h.equals("session", Debug.slugify(""))
  end)
end)

h.describe("debug persistence", function()
  h.it("save/load roundtrip", function()
    with_tmp_session(function()
      local entries = { { file = "/a", text = "x", added_at = 1 } }
      h.truthy(Debug.save(entries), "save should succeed")
      local loaded = Debug.load()
      h.equals(1, #loaded)
      h.equals("/a", loaded[1].file)
      h.equals("x", loaded[1].text)
    end)
  end)

  h.it("load returns {} when the tracker is missing", function()
    with_tmp_session(function()
      h.same({}, Debug.load())
    end)
  end)

  h.it("remove_all strips matching snippets and clears the tracker", function()
    with_tmp_session(function()
      local file = vim.fn.tempname()
      vim.fn.writefile({ "line1", "TEMP_DEBUG_SNIPPET", "line3" }, file)
      Debug.save({ { file = file, text = "TEMP_DEBUG_SNIPPET", added_at = 1 } })

      local removed, remaining = Debug.remove_all()
      h.equals(1, removed)
      h.equals(0, remaining)

      local content = table.concat(vim.fn.readfile(file), "\n")
      h.falsy(content:find("TEMP_DEBUG_SNIPPET", 1, true), "snippet should be removed")
      vim.fn.delete(file)
    end)
  end)
end)
