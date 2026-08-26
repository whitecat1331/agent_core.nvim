-- Minimal init for the headless nvim smoke test.
--
-- Loads the plugin from the repository root (cwd) so CI and `check_smoke_nvim`
-- can validate that `agent_core` requires and sets up cleanly with no third-party
-- plugins installed. Run:
--
--   nvim --headless -u tests/minimal_init.lua \
--     "+lua require('agent_core').setup(); print('AGENT_CORE_SMOKE_OK')" +qa

vim.opt.runtimepath:prepend(vim.fn.getcwd())
