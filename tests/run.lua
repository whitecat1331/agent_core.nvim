---@mod tests.run Test entry point: require every spec, then run the harness.
---@brief [[
--- Run with:
---   nvim --headless -u tests/minimal_init.lua "+lua require('tests.run')"
--- Each *_spec.lua registers its describe/it blocks on require; this file then
--- invokes the harness run() which prints PASS/FAIL and the AGENT_CORE_TESTS_OK
--- sentinel on success.
---@brief ]]

-- Register every spec (require order is stable and deterministic).
require("tests.platform_spec")
require("tests.modes_spec")
require("tests.profiles_spec")
require("tests.recommend_spec")
require("tests.autoswitch_spec")
require("tests.web_spec")
require("tests.slugify_spec")
require("tests.notepad_spec")
require("tests.bugbot_spec")
require("tests.indexer_spec")
require("tests.memory_spec")
require("tests.rules_spec")
require("tests.mentions_spec")
require("tests.keys_spec")
require("tests.bestofn_spec")
require("tests.dap_spec")
require("tests.registry_spec")
require("tests.policy_spec")
require("tests.completion_spec")
require("tests.catalog_spec")
require("tests.setup_spec")
require("tests.skills_spec")
require("tests.commands_spec")
require("tests.import_spec")
require("tests.context_spec")
require("tests.ask_spec")
require("tests.history_spec")
require("tests.automation_spec")
require("tests.browser_spec")
require("tests.vision_spec")
require("tests.diff_spec")
require("tests.edits_spec")
require("tests.runner_spec")

require("tests.harness").run()
