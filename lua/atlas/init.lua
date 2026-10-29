local sidebar = require("atlas.sidebar")
local data = require("atlas.data")
local annotate = require("atlas.annotate")

local M = {}

function M.setup(opts)
  opts = opts or {}
  data.configure(opts)

  vim.api.nvim_create_user_command("AtlasToggle", sidebar.toggle, {})
  -- `range = true`: with no explicit range (normal mode, "AtlasAnnotate")
  -- line1/line2 both default to the current line; with a visual
  -- selection ("'<,'>AtlasAnnotate", from the "x"-mode mapping below)
  -- they're the selection's bounds.
  vim.api.nvim_create_user_command("AtlasAnnotate", function(cmd_opts)
    annotate.add(cmd_opts.line1, cmd_opts.line2)
  end, { range = true })

  local keys = opts.keys or {}
  vim.keymap.set("n", keys.toggle or "<leader>ae", sidebar.toggle, { desc = "Atlas: toggle sidebar" })
  vim.keymap.set("n", keys.annotate or "<leader>aa", "<cmd>AtlasAnnotate<cr>", { desc = "Atlas: add a note on this line" })
  -- Deliberately ":AtlasAnnotate<cr>", not "<cmd>...": the leading ":" is
  -- what makes Neovim auto-prefix "'<,'>" from the visual selection.
  vim.keymap.set("x", keys.annotate or "<leader>aa", ":AtlasAnnotate<cr>", { desc = "Atlas: add a note on the selected lines" })
end

return M
