---@mod tests.runner_spec Unit tests for agent_core.runner (multimodal content).

local h = require("tests.harness")
local Runner = require("agent_core.runner")

h.describe("runner", function()
  h.it("build_user_content returns a plain string without images", function()
    h.equals("hello", Runner.build_user_content({ user_prompt = "hello" }))
  end)

  h.it("build_user_content builds a multimodal array with images", function()
    local content = Runner.build_user_content({
      user_prompt = "describe this",
      images = { { data = "AAAA", media_type = "image/jpeg" } },
    })
    h.equals("table", type(content))
    h.equals(2, #content)
    h.equals("text", content[1].type)
    h.equals("describe this", content[1].text)
    h.equals("image", content[2].type)
    h.equals("base64", content[2].source.type)
    h.equals("image/jpeg", content[2].source.media_type)
    h.equals("AAAA", content[2].source.data)
  end)

  h.it("build_user_content defaults media_type to image/png", function()
    local content = Runner.build_user_content({
      user_prompt = "x",
      images = { { data = "AA" } },
    })
    h.equals("image/png", content[2].source.media_type)
  end)

  h.it("build_system_prompt injects the profile persona when set", function()
    vim.g.agent_persona = "PROFILE_PERSONA_MARKER"
    local out = Runner.build_system_prompt(nil)
    h.truthy(out:find("PROFILE_PERSONA_MARKER", 1, true), "profile persona should be present")
    vim.g.agent_persona = nil
  end)

  h.it("build_system_prompt omits the profile persona when empty", function()
    vim.g.agent_persona = nil
    local out = Runner.build_system_prompt(nil)
    h.falsy(out:find("PROFILE_PERSONA_MARKER", 1, true), "no persona marker when unset")
  end)
end)
