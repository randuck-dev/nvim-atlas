-- The sidebar: live sessions, each with the worktrees it's touched, PR/CI
-- status and relative timing. Manual refresh (`r`) for now — no
-- background timer yet.
--
-- Colors reuse the Rosé Pine tokens already used elsewhere in the user's
-- dotfiles (bin/claude-status's tmux segment, bin/git-review's preview),
-- so this looks like it belongs rather than clashing.

local data = require("atlas.data")
local review = require("atlas.review")
local annotate = require("atlas.annotate")

local M = {}

local buf = nil
local rows = {} -- line (1-indexed) -> { kind = "session"|"worktree", session_id, path }
local ns = vim.api.nvim_create_namespace("atlas_sidebar")

local STATE_GLYPH = { input = "● ", done = "◆ ", working = "… " }
local STATE_HL = { input = "AtlasStateInput", done = "AtlasStateDone", working = "AtlasStateWorking" }

local CHECK_GLYPH = { passing = "✓", failing = "✗", pending = "…", none = "•" }
local CHECK_HL = { passing = "AtlasCheckPassing", failing = "AtlasCheckFailing", pending = "AtlasCheckPending", none = "AtlasCheckNone" }

local function setup_highlights()
  -- Rosé Pine: gold, iris, muted, love, foam.
  vim.api.nvim_set_hl(0, "AtlasStateInput", { fg = "#f6c177", default = true })
  vim.api.nvim_set_hl(0, "AtlasStateDone", { fg = "#c4a7e7", default = true })
  vim.api.nvim_set_hl(0, "AtlasStateWorking", { fg = "#6e6a86", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckPassing", { fg = "#9ccfd8", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckFailing", { fg = "#eb6f92", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckPending", { fg = "#f6c177", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckNone", { fg = "#6e6a86", default = true })
  vim.api.nvim_set_hl(0, "AtlasNoteBadge", { fg = "#ebbcba", default = true }) -- rose
end

local function format_elapsed(epoch)
  if not epoch or epoch == 0 then
    return ""
  end
  local secs = os.time() - tonumber(epoch)
  if secs < 0 then
    secs = 0
  end
  if secs < 60 then
    return secs .. "s"
  elseif secs < 3600 then
    return math.floor(secs / 60) .. "m"
  end
  return math.floor(secs / 3600) .. "h"
end

local function ensure_buf()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  setup_highlights()
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
    -- Enter on a session row is deliberately a no-op for now: jumping
    -- into the session itself (its terminal) is still an open question
    -- the user hasn't settled on, not something to guess at.
  end, "atlas: review worktree under cursor")

  map("r", M.refresh, "atlas: refresh")
  map("q", function()
    vim.cmd("close")
  end, "atlas: close sidebar")

  return buf
end

local function render(sessions, touched, pr_by_path)
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
  local highlights = {} -- { line (0-indexed), col_start, col_end, hl_group }
  rows = {}

  if #sessions == 0 then
    lines[#lines + 1] = "(no live Claude Code sessions)"
  end

  for _, session in ipairs(sessions) do
    local glyph = STATE_GLYPH[session.state] or "  "
    local title = session.title ~= "" and session.title or session.session_id
    local elapsed = format_elapsed(session.since)
    local line = glyph .. title
    if elapsed ~= "" then
      line = line .. "  " .. elapsed
    end
    lines[#lines + 1] = line
    rows[#lines] = { kind = "session", session_id = session.session_id }

    local glyph_hl = STATE_HL[session.state]
    if glyph_hl then
      highlights[#highlights + 1] = { #lines - 1, 0, #glyph, glyph_hl }
    end
    if elapsed ~= "" then
      local suffix_start = #line - #elapsed
      highlights[#highlights + 1] = { #lines - 1, suffix_start, #line, "Comment" }
    end

    local t = by_session[session.session_id]
    if t then
      local paths = vim.tbl_keys(t.paths)
      table.sort(paths)
      for _, path in ipairs(paths) do
        local name = vim.fn.fnamemodify(path, ":t")
        local wline = "    " .. name
        local pr = pr_by_path[path]
        if pr then
          local check_glyph = CHECK_GLYPH[pr.checks] or "•"
          local badge = string.format("  #%d %s", pr.number, check_glyph)
          local badge_start = #wline
          wline = wline .. badge
          highlights[#highlights + 1] = { #lines, badge_start, #wline, CHECK_HL[pr.checks] or "AtlasCheckNone" }
        end
        local note_count = annotate.pending_for(session.session_id, path)
        if note_count > 0 then
          local note_start = #wline
          wline = wline .. string.format("  [%d note%s]", note_count, note_count == 1 and "" or "s")
          highlights[#highlights + 1] = { #lines, note_start, #wline, "AtlasNoteBadge" }
        end
        lines[#lines + 1] = wline
        rows[#lines] = { kind = "worktree", session_id = session.session_id, path = path }
      end
    end
  end

  local b = ensure_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.bo[b].modifiable = false
end

--- Re-shells claude-status/git/gh and re-renders the sidebar.
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

      local paths = {}
      local seen = {}
      for _, t in ipairs(touched) do
        for path, _ in pairs(t.paths) do
          if not seen[path] then
            seen[path] = true
            paths[#paths + 1] = path
          end
        end
      end

      data.pr_status(paths, function(pr_by_path)
        render(sessions, touched, pr_by_path)
      end)
    end)
  end)
end

--- Opens the sidebar pinned to the far left (like a file-explorer
--- sidebar) if it isn't already, and refreshes it; closes it if it's
--- already open.
function M.toggle()
  local b = ensure_buf()
  local win = vim.fn.bufwinid(b)
  if win ~= -1 then
    vim.api.nvim_win_close(win, false)
    return
  end
  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, b)
  vim.cmd("wincmd H") -- pin full-height to the far left, regardless of 'splitright'
  vim.api.nvim_win_set_width(0, 40)
  vim.wo[0].winfixwidth = true
  vim.wo[0].number = false
  vim.wo[0].signcolumn = "no"
  vim.wo[0].wrap = false
  M.refresh()
end

return M
