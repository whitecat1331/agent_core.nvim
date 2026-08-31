---@mod tests.history_spec Unit tests for agent_core.history (owned persistence).

local h = require("tests.harness")
local History = require("agent_core.history")

h.describe("history", function()
  h.it("list returns entries from a directory", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "{}" }, dir .. "/a.json")
    vim.fn.writefile({ "{}" }, dir .. "/b.json")
    local entries = History.list(dir)
    h.equals(2, #entries)
    vim.fn.delete(dir, "rf")
  end)

  h.it("list returns empty for a missing directory", function()
    h.equals(0, #History.list(vim.fn.tempname() .. "/nope"))
  end)

  h.it("load decodes a session and appends .json when needed", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ '{"title":"hello"}' }, dir .. "/s1.json")
    local data, err = History.load(dir, "s1")
    h.equals(nil, err)
    h.equals("hello", data.title)
    vim.fn.delete(dir, "rf")
  end)

  h.it("load returns an error for a missing session", function()
    local data, err = History.load(vim.fn.tempname(), "missing")
    h.equals(nil, data)
    h.truthy(err ~= nil, "missing session should error")
  end)
end)

h.describe("history binding", function()
  h.it("bind_profile and get_bound_profile round-trip on the session record", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    History.config.dir = dir
    vim.fn.writefile({ '{"title":"s"}' }, dir .. "/s1.json")
    h.truthy(History.bind_profile("s1", "Claude"), "bind should succeed")
    h.equals("Claude", History.get_bound_profile("s1"))
    -- provider/model are also resolved and persisted on the record.
    local data = History.load(dir, "s1")
    h.equals("claude", data.provider)
    h.truthy(data.model ~= nil, "model should be resolved")
    h.equals(nil, History.get_bound_profile("missing"))
    vim.fn.delete(dir, "rf")
    History.config.dir = nil
  end)

  h.it("bind_profile rejects empty id or profile", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    History.config.dir = dir
    h.equals(false, History.bind_profile("", "Claude"))
    h.equals(false, History.bind_profile("s1", ""))
    vim.fn.delete(dir, "rf")
    History.config.dir = nil
  end)

  h.it("current_session_id is empty with no active session", function()
    h.equals("", History.current_session_id())
  end)
end)

h.describe("history rename + fork", function()
  local function with_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    History.config.dir = dir
    return dir
  end

  local function cleanup(dir)
    History.config.dir = nil
    vim.fn.delete(dir, "rf")
  end

  h.it("rename_session updates the session record title", function()
    local dir = with_dir()
    vim.fn.writefile({ '{"title":"old"}' }, dir .. "/s1.json")
    h.truthy(History.rename_session("s1", "new title"), "rename should succeed")
    h.equals("new title", History.title_for(dir, "s1"))
    local data = History.load(dir, "s1")
    h.equals("new title", data.title)
    cleanup(dir)
  end)

  h.it("rename_session rejects empty id or title", function()
    local dir = with_dir()
    h.equals(false, History.rename_session("", "x"))
    h.equals(false, History.rename_session("s1", ""))
    cleanup(dir)
  end)

  h.it("fork_session creates a new id with a fork-suffixed title and copies binding", function()
    local dir = with_dir()
    vim.fn.writefile({ '{"title":"orig"}' }, dir .. "/s1.json")
    History.bind_profile("s1", "Claude")
    local new_id, err = History.fork_session("s1", nil)
    h.equals(nil, err)
    h.truthy(new_id ~= nil and new_id ~= "s1", "fork should produce a new id")
    local data = History.load(dir, new_id)
    h.truthy(data.title and data.title:find("(fork)", 1, true) ~= nil, "fork title should carry (fork)")
    -- Original is unchanged.
    local orig = History.load(dir, "s1")
    h.equals("orig", orig.title)
    -- Binding is copied to the fork.
    h.equals("Claude", History.get_bound_profile(new_id))
    cleanup(dir)
  end)

  h.it("fork_session accepts an explicit title", function()
    local dir = with_dir()
    vim.fn.writefile({ '{"title":"orig"}' }, dir .. "/s1.json")
    local new_id, err = History.fork_session("s1", "explicit")
    h.equals(nil, err)
    h.equals("explicit", History.load(dir, new_id).title)
    cleanup(dir)
  end)

  h.it("fork_session errors on a missing session", function()
    local dir = with_dir()
    local new_id, err = History.fork_session("missing", nil)
    h.equals(nil, new_id)
    h.truthy(err ~= nil, "fork of a missing session should error")
    cleanup(dir)
  end)

  h.it("list excludes metadata.json", function()
    local dir = with_dir()
    vim.fn.writefile({ "{}" }, dir .. "/metadata.json")
    vim.fn.writefile({ '{"title":"real"}' }, dir .. "/a.json")
    local entries = History.list(dir)
    h.equals(1, #entries)
    h.equals("a", entries[1].id)
    cleanup(dir)
  end)

  h.it("rewind_session truncates messages and writes a backup", function()
    local dir = with_dir()
    vim.fn.writefile({
      vim.json.encode({
        title = "t",
        messages = {
          { message = { role = "user", content = "one" } },
          { message = { role = "assistant", content = "two" } },
          { message = { role = "user", content = "three" } },
        },
      }),
    }, dir .. "/s1.json")
    local ok, err = History.rewind_session("s1", 2)
    h.equals(nil, err)
    h.truthy(ok, "rewind should succeed")
    local data = History.load(dir, "s1")
    h.equals(2, #data.messages)
    h.equals("two", data.messages[2].message.content)
    -- backup preserves the original three messages.
    local bak = dir .. "/s1.json.rewind-bak"
    h.truthy(vim.fn.filereadable(bak) == 1, "backup file should exist")
    cleanup(dir)
  end)

  h.it("rewind_session rejects an out-of-range index", function()
    local dir = with_dir()
    vim.fn.writefile(
      { vim.json.encode({ messages = { { message = { role = "user", content = "x" } } } }) },
      dir .. "/s1.json"
    )
    local ok, err = History.rewind_session("s1", 5)
    h.equals(false, ok)
    h.truthy(err ~= nil, "out-of-range index should error")
    cleanup(dir)
  end)
end)

h.describe("history delete + persist_model", function()
  local function with_dir()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    History.config.dir = dir
    return dir
  end

  local function cleanup(dir)
    History.config.dir = nil
    vim.fn.delete(dir, "rf")
  end

  h.it("delete_session removes the session file", function()
    local dir = with_dir()
    vim.fn.writefile({ '{"title":"x"}' }, dir .. "/s1.json")
    h.truthy(History.delete_session("s1"), "delete should succeed")
    h.equals(0, vim.fn.filereadable(dir .. "/s1.json"))
    h.equals(false, History.delete_session("missing"))
    h.equals(false, History.delete_session(""))
    cleanup(dir)
  end)

  h.it("persist_model writes provider/model to the record", function()
    local dir = with_dir()
    vim.fn.writefile({ '{"title":"x"}' }, dir .. "/s1.json")
    h.truthy(History.persist_model("s1", "gemini", "gemini-2.0-flash"))
    local data = History.load(dir, "s1")
    h.equals("gemini", data.provider)
    h.equals("gemini-2.0-flash", data.model)
    cleanup(dir)
  end)
end)
