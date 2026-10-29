local sidebar = require("atlas.sidebar")
local data = require("atlas.data")
local annotate = require("atlas.annotate")

local M = {}

function M.setup(opts)
  opts = opts or {}
  data.configure(opts)

  vim.api.nvim_create_user_command("AtlasToggle", sidebar.toggle, {})
  vim.api.nvim_create_user_command("AtlasAnnotate", annotate.add, {})

  local keys = opts.keys or {}
  vim.keymap.set("n", keys.toggle or "<leader>ae", sidebar.toggle, { desc = "Atlas: toggle sidebar" })
  vim.keymap.set("n", keys.annotate or "<leader>aa", annotate.add, { desc = "Atlas: add a note on this line" })
end

return M
