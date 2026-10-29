local sidebar = require("atlas.sidebar")

local M = {}

function M.setup(opts)
  opts = opts or {}

  vim.api.nvim_create_user_command("AtlasToggle", sidebar.toggle, {})

  local keys = opts.keys or {}
  vim.keymap.set("n", keys.toggle or "<leader>ae", sidebar.toggle, { desc = "Atlas: toggle sidebar" })
end

return M
