local plugin_root = vim.fn.getcwd()
local deps_root = plugin_root .. "/.deps"

vim.opt.rtp:append(plugin_root)
vim.opt.rtp:append(deps_root .. "/plenary.nvim")
vim.opt.rtp:append(deps_root .. "/diffview.nvim")

vim.cmd("runtime! plugin/plenary.vim")
vim.cmd("runtime! plugin/diffview.lua")
