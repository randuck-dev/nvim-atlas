-- The sidebar: live sessions, each with the worktrees it's touched, PR/CI
-- status and relative timing. Refreshes itself while open: local session
-- state every few seconds, GitHub PR/CI status less often (network,
-- rate-limited). `r` forces both immediately.
--
-- Colors reuse the Rosé Pine tokens already used elsewhere in the user's
-- dotfiles (bin/claude-status's tmux segment, bin/git-review's preview),
-- so this looks like it belongs rather than clashing.

local data = require("atlas.data")
local review = require("atlas.review")
local annotate = require("atlas.annotate")
local deliver = require("atlas.deliver")
local peek = require("atlas.peek")

local M = {}

local buf = nil
local rows = {} -- line (1-indexed) -> { kind = "session"|"worktree", session_id, path }
local ns = vim.api.nvim_create_namespace("atlas_sidebar")

local config = {
  poll_ms = 5000, -- claude-status: local files, cheap
  pr_poll_ms = 30000, -- gh: network, rate-limited
}

local timer = nil
local in_flight = false -- never run two refreshes at once
local pr_cache = {} -- path -> PR status, reused between gh polls
local pr_fetched_at = 0 -- vim.uv.now() of the last gh fetch

--- Polling intervals: { poll_ms, pr_poll_ms }.
function M.configure(opts)
  config = vim.tbl_extend("force", config, opts or {})
end

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
    elseif row and row.kind == "session" then
      peek.open(row.session_id)
    end
  end, "atlas: review worktree / peek session under cursor")

  map("y", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "worktree" then
      deliver.copy_for_worktree(row.session_id, row.path, vim.fn.fnamemodify(row.path, ":t"))
    end
  end, "atlas: copy pending notes for worktree under cursor")

  map("X", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "session" then
      require("atlas.cleanup").run(row.paths, function(removed)
        if removed > 0 then
          M.refresh(true)
        end
      end)
    end
  end, "atlas: clean up this session's finished worktrees")

  map("s", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "session" then
      deliver.send(row.session_id, function(ok)
        if ok then
          M.refresh()
        end
      end)
    end
  end, "atlas: send all pending notes into this session")

  map("r", function()
    M.refresh(true)
  end, "atlas: refresh now (including PR/CI)")
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
    -- Worktrees that no longer exist (e.g. removed by cleanup) are
    -- dropped right away, not after claude-status's 14-day expiry.
    local t = by_session[session.session_id]
    local paths = {}
    if t then
      for p, _ in pairs(t.paths) do
        if vim.fn.isdirectory(p) == 1 then
          paths[#paths + 1] = p
        end
      end
      table.sort(paths)
    end

    lines[#lines + 1] = line
    rows[#lines] = { kind = "session", session_id = session.session_id, paths = paths }

    local glyph_hl = STATE_HL[session.state]
    if glyph_hl then
      highlights[#highlights + 1] = { #lines - 1, 0, #glyph, glyph_hl }
    end
    if elapsed ~= "" then
      local suffix_start = #line - #elapsed
      highlights[#highlights + 1] = { #lines - 1, suffix_start, #line, "Comment" }
    end

    do
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

local function is_open()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1
end

-- Last local data rendered, so reopening the sidebar (or a PR fetch
-- finishing) can render instantly without waiting on claude-status.
local last = nil -- { sessions, touched }
local pr_in_flight = false

local function render_last()
  if last and is_open() then
    render(vim.deepcopy(last.sessions), last.touched, pr_cache)
  end
end

-- GitHub PR/CI status is slow (measured ~2s for 4 worktrees: a git call
-- per worktree plus a `gh pr list` per repo, over the network), so it
-- never blocks a render: fetch in the background, re-render on arrival.
local function refresh_prs(touched)
  if pr_in_flight then
    return
  end
  pr_in_flight = true
  local paths, seen = {}, {}
  for _, t in ipairs(touched) do
    for path, _ in pairs(t.paths) do
      if not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
  end
  data.pr_status(paths, function(pr_by_path)
    pr_in_flight = false
    pr_cache = pr_by_path
    pr_fetched_at = vim.uv.now()
    render_last()
  end)
end

--- Re-reads claude-status and re-renders right away with the PR/CI
--- status cached so far. If that status is older than pr_poll_ms (or
--- `force` is set) it's refetched in the background and the sidebar
--- re-renders when it arrives. Skipped while another local refresh is
--- still running.
function M.refresh(force)
  if in_flight then
    return
  end
  in_flight = true

  data.sessions(function(sessions, err)
    if err then
      in_flight = false
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      return
    end
    data.touched(function(touched, terr)
      in_flight = false
      if terr then
        vim.notify("atlas: " .. terr, vim.log.levels.ERROR)
        return
      end

      last = { sessions = sessions, touched = touched }
      render_last()

      if force or vim.uv.now() - pr_fetched_at >= config.pr_poll_ms then
        refresh_prs(touched)
      end
    end)
  end)
end

local function stop_polling()
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  timer = nil
end

local function start_polling()
  stop_polling()
  timer = vim.uv.new_timer()
  timer:start(
    config.poll_ms,
    config.poll_ms,
    vim.schedule_wrap(function()
      if is_open() then
        M.refresh(false)
      else
        stop_polling()
      end
    end)
  )
end

--- Forgets cached state and in-flight flags (for tests).
function M._reset()
  stop_polling()
  in_flight, pr_in_flight = false, false
  last, pr_cache, pr_fetched_at = nil, {}, 0
end

--- True while the background refresh timer is running (for tests).
function M._polling()
  return timer ~= nil and not timer:is_closing()
end

--- Opens the sidebar pinned to the far left (like a file-explorer
--- sidebar) if it isn't already, and refreshes it; closes it if it's
--- already open.
function M.toggle()
  local b = ensure_buf()
  local win = vim.fn.bufwinid(b)
  if win ~= -1 then
    stop_polling()
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
  if last then
    render_last() -- instant: what it showed last time
  else
    vim.bo[b].modifiable = true
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "loading sessions…" })
    vim.bo[b].modifiable = false
  end
  M.refresh(true)
  start_polling()
end

return M
