---@mod tests.runtime_workflows_spec Unit tests for the owned workflows engine.

local h = require("tests.harness")
local Workflows = require("agent_core.runtime.workflows")

h.describe("runtime.workflows parse", function()
  h.it("accepts a table definition", function()
    local wf = Workflows.parse({ name = "t", steps = { "a", "b" } })
    h.equals("t", wf.name)
    h.equals(2, #wf.steps)
  end)

  h.it("rejects a definition without steps", function()
    local wf, err = Workflows.parse({ name = "t", steps = {} })
    h.falsy(wf)
    h.truthy(err)
  end)

  h.it("parses a serialized definition", function()
    local wf = Workflows.parse(
      "name: ship\n"
        .. "description: ship a feature\n"
        .. "step:\n"
        .. "plan the change\n"
        .. "step:\n"
        .. "implement {1}\n"
    )
    h.equals("ship", wf.name)
    h.equals("ship a feature", wf.description)
    h.equals(2, #wf.steps)
    h.equals("plan the change", wf.steps[1])
    h.equals("implement {1}", wf.steps[2])
  end)
end)

h.describe("runtime.workflows substitute", function()
  h.it("substitutes positional and named outputs", function()
    local ctx = { outputs = { "alpha", "beta", answer = "gamma" }, vars = { x = "1" } }
    h.equals("a alpha b gamma c 1", Workflows.substitute("a {1} b {outputs.answer} c {{x}}", ctx))
  end)

  h.it("leaves unknown placeholders verbatim", function()
    h.equals("see {9} and {missing}", Workflows.substitute("see {9} and {missing}", { outputs = {}, vars = {} }))
  end)
end)

h.describe("runtime.workflows run", function()
  h.it("runs steps sequentially feeding prior output", function()
    local wf = { name = "t", steps = { "step one", "continue with {1}" } }
    local prompts = {}
    local err, result
    Workflows.run(wf, {
      step_fn = function(prompt, ctx, done)
        prompts[#prompts + 1] = prompt
        done(nil, "output" .. #prompts)
      end,
    }, function(e, outputs)
      err = e
      result = outputs
    end)
    h.equals(nil, err)
    h.equals(2, #prompts)
    h.equals("step one", prompts[1])
    h.equals("continue with output1", prompts[2])
    h.equals(2, #result)
    h.equals("output2", result[2])
  end)

  h.it("propagates a step error", function()
    local err
    Workflows.run({ name = "t", steps = { "a" } }, {
      step_fn = function(_, _, done)
        done("boom", nil)
      end,
    }, function(e)
      err = e
    end)
    h.equals("boom", err)
  end)

  h.it("errors on a definition with no steps", function()
    local err
    Workflows.run({ name = "t", steps = {} }, {}, function(e)
      err = e
    end)
    h.truthy(err)
  end)
end)
