-- Opens a worktree's diff in its own tab via diffview.nvim.
--
-- Deliberately does nothing special to make `q` close the tab: diffview's
-- own `DiffviewClose` (bound to `q` in config/nvim/lua/plugins/diffview.lua,
-- active whenever `g:review_mode` isn't set) already removes the tab it
-- opened in (see diffview's View:close(), which tabcloses before emitting
-- view_closed). Since atlas never sets `g:review_mode`, that's exactly
-- what happens for free, with zero coupling to diffview's internals and
-- zero interference with `bin/git-review`'s own (review_mode-based) flow.
--
-- Uses diffview's `-C<path>` flag to resolve the repo explicitly, so no
-- :cd/:tcd dance is needed before opening it.

local data = require("atlas.data")

local M = {}

--- Opens `path`'s diff against its merge base in a new tab. `session_id`
--- is just carried along in the tab's context for annotate.lua to use;
--- review.lua itself doesn't interpret it.
function M.open(path, session_id)
  data.merge_base(path, function(base, target, err)
    if err then
      vim.notify("atlas: couldn't compute merge base for " .. path .. ": " .. err, vim.log.levels.ERROR)
      return
    end

    vim.cmd("DiffviewOpen -C" .. vim.fn.fnameescape(path) .. " " .. base)

    -- `DiffviewOpen` opens (and switches to) its new tab synchronously, so
    -- the current tabpage right here is that new tab.
    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.t[tabpage].atlas_review = {
      path = path,
      session_id = session_id,
      base = base,
      target = target,
    }
  end)
end

--- The atlas review context for `tabpage` (default: the current one), or
--- nil if it isn't an atlas-opened review tab.
function M.context(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  return vim.t[tabpage] and vim.t[tabpage].atlas_review
end

return M
