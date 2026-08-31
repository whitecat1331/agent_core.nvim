---@mod tests.vision_spec Unit tests for agent_core.image vision (base64, media type, tool).

local h = require("tests.harness")
local Image = require("agent_core.image")

h.describe("vision", function()
  h.it("base64_encode encodes RFC 4648 test vectors", function()
    h.equals("", Image.base64_encode(""))
    h.equals("QQ==", Image.base64_encode("A"))
    h.equals("QUI=", Image.base64_encode("AB"))
    h.equals("QUJD", Image.base64_encode("ABC"))
    h.equals("TWFu", Image.base64_encode("Man"))
  end)

  h.it("media_type_for maps extensions case-insensitively", function()
    h.equals("image/png", Image.media_type_for("shot.png"))
    h.equals("image/jpeg", Image.media_type_for("photo.JPG"))
    h.equals("image/jpeg", Image.media_type_for("x.jpeg"))
    h.equals("image/gif", Image.media_type_for("a.gif"))
    h.equals("image/webp", Image.media_type_for("b.webp"))
    h.equals("image/png", Image.media_type_for("unknown.txt"))
  end)

  h.it("resolve_path passes through absolute paths", function()
    h.equals("/tmp/foo.png", Image.resolve_path("/tmp/foo.png"))
  end)

  h.it("read_bytes reads a file's raw bytes", function()
    local path = vim.fn.tempname()
    local f = io.open(path, "wb")
    f:write("hello world")
    f:close()
    h.equals("hello world", Image.read_bytes(path))
    vim.fn.delete(path)
  end)

  h.it("read_bytes returns nil for a missing file", function()
    h.equals(nil, Image.read_bytes(vim.fn.tempname() .. "-missing"))
  end)

  h.it("read_image_tool exposes the read_image tool", function()
    local tool = Image.read_image_tool()
    h.equals("read_image", tool.name)
    h.equals("function", type(tool.func))
  end)

  h.it("read_image tool rejects a missing path", function()
    local err
    Image.read_image_tool().func({}, {
      on_complete = function(_, e)
        err = e
      end,
    })
    h.equals("path is required", err)
  end)

  h.it("read_image errors on an unreadable path", function()
    local err
    Image.read_image(vim.fn.tempname() .. "-nope", nil, function(_, e)
      err = e
    end)
    h.matches("not readable", err)
  end)

  h.it("paste_allowed accepts vision models and rejects text-only models", function()
    h.equals(true, Image.paste_allowed("gpt-4o"))
    h.equals(true, Image.paste_allowed("llava:13b"))
    h.equals(false, Image.paste_allowed("deepseek-chat"))
    h.equals(false, Image.paste_allowed("qwen2.5-coder:7b-instruct"))
    h.equals(false, Image.paste_allowed(""))
    h.equals(false, Image.paste_allowed(nil))
  end)

  h.it("guard_paste blocks a non-vision model in block mode", function()
    h.equals(false, Image.guard_paste("deepseek-chat", "block"))
  end)

  h.it("guard_paste warns but allows a non-vision model in warn mode", function()
    h.equals(true, Image.guard_paste("deepseek-chat", "warn"))
  end)

  h.it("guard_paste allows vision models", function()
    h.equals(true, Image.guard_paste("gpt-4o", "block"))
  end)

  h.it("guard_paste is disabled when mode is false", function()
    h.equals(true, Image.guard_paste("deepseek-chat", false))
  end)

  h.it("guard_paste allows in auto_switch mode (caller performs the switch)", function()
    h.equals(true, Image.guard_paste("deepseek-chat", "auto_switch"))
  end)
end)
