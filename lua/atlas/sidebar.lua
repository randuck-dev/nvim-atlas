-- The sidebar: live sessions, each with the worktrees it's touched.
-- v0: manual refresh only (no background timer yet, no PR/CI badges yet
-- — data.pr_status exists and works, just not wired in here yet).

local data = require("atlas.data")
local review = require("atlas.review")

local M = {}

local buf = nil
local rows = {} -- line (1-indexed) -> { kind = "session"|"worktree", session_id, path }

local STATE_GLYPH = {
  input = "● ",
  done = "◆ ",
  working = "… ",
}

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "AtlasSidebar"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, "atlas://sidebar")

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
  end

  map("<CR>", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "worktree" then
      review.open(row.path, row.session_id)
    end
  end, "atlas: review worktree under cursor")

  map("r", M.refresh, "atlas: refresh")
  map("q", function()
    vim.cmd("close")
  end, "atlas: close sidebar")

  return buf
end

local function render(sessions, touched)
  local by_session = {}
  for _, t in ipairs(touched) do
    by_session[t.session_id] = t
  end

  -- live sessions needing attention first, then finished, then working.
  local order = { input = 1, done = 2, working = 3 }
  table.sort(sessions, function(a, b)
    return (order[a.state] or 9) < (order[b.state] or 9)
  end)

  local lines = {}
  rows = {}

  if #sessions == 0 then
    lines[#lines + 1] = "(no live Claude Code sessions)"
  end

  for _, session in ipairs(sessions) do
    local glyph = STATE_GLYPH[session.state] or "  "
    lines[#lines + 1] = glyph .. (session.title ~= "" and session.title or session.session_id)
    rows[#lines] = { kind = "session", session_id = session.session_id }

    local t = by_session[session.session_id]
    if t then
      local paths = vim.tbl_keys(t.paths)
      table.sort(paths)
      for _, path in ipairs(paths) do
        lines[#lines + 1] = "    " .. vim.fn.fnamemodify(path, ":t")
        rows[#lines] = { kind = "worktree", session_id = session.session_id, path = path }
      end
    end
  end

  local b = ensure_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
end

--- Re-shells claude-status and re-renders the sidebar.
function M.refresh()
  data.sessions(function(sessions, err)
    if err then
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      return
    end
    data.touched(function(touched, terr)
      if terr then
        vim.notify("atlas: " .. terr, vim.log.levels.ERROR)
        return
      end
      render(sessions, touched)
    end)
  end)
end

--- Opens the sidebar in a vertical split if it isn't already, and
--- refreshes it; closes it if it's already open.
function M.toggle()
  local b = ensure_buf()
  local win = vim.fn.bufwinid(b)
  if win ~= -1 then
    vim.api.nvim_win_close(win, false)
    return
  end
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, b)
  vim.api.nvim_win_set_width(0, 40)
  M.refresh()
end

return M
