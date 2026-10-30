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
local sections = require("atlas.sections")

local M = {}

local buf = nil
local rows = {} -- line (1-indexed) -> { kind = "repo"|"session"|"worktree", ... }
local show_help = false -- full key list shown at the bottom (`?`)
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
  vim.api.nvim_set_hl(0, "AtlasRepo", { fg = "#9ccfd8", bold = true, default = true }) -- foam
  vim.api.nvim_set_hl(0, "AtlasSection", { fg = "#c4a7e7", bold = true, default = true }) -- iris
  vim.api.nvim_set_hl(0, "AtlasKey", { fg = "#f6c177", bold = true, default = true }) -- gold
  vim.api.nvim_set_hl(0, "AtlasHint", { fg = "#6e6a86", default = true }) -- muted
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
    if row and row.kind == "session" and row.gone then
      -- Its folder was removed (e.g. `wt remove`) while Claude kept
      -- running in it: all that's left to clean up is the session.
      vim.ui.select({ "Close the session", "Cancel" }, {
        prompt = "atlas: this session's folder was removed. Close the session?",
      }, function(choice)
        if choice ~= "Close the session" then
          return
        end
        local ok, err = require("atlas.cleanup").close_pane(row.pane)
        if not ok then
          vim.notify("atlas: " .. err, vim.log.levels.ERROR)
          return
        end
        vim.defer_fn(function()
          M.refresh(false)
        end, 500)
      end)
    elseif row and row.kind == "session" then
      require("atlas.cleanup").run(row.paths, function(removed)
        if removed > 0 then
          M.refresh(true)
        end
      end, { own = { path = row.cwd, pane = row.pane } })
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

  map("n", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or not row.root then
      vim.notify("atlas: put the cursor on a repo (or one of its sessions)", vim.log.levels.WARN)
      return
    end
    require("atlas.spawn").prompt(row.root, function(ok)
      if ok then
        -- The session registers with claude-status once claude starts;
        -- the background poll picks it up after that.
        vim.defer_fn(function()
          M.refresh(false)
        end, 2000)
      end
    end)
  end, "atlas: new worktree + Claude session in this repo")

  map("r", function()
    M.refresh(true)
  end, "atlas: refresh now (including PR/CI)")
  -- Sections: your own groupings, e.g. "to deploy", "observability".
  local function new_section(then_assign)
    vim.ui.input({ prompt = "New section name: " }, function(name)
      name = name and vim.trim(name) or ""
      if name == "" then
        return
      end
      if then_assign then
        sections.assign(then_assign, name)
      else
        local ok, err = sections.add(name)
        if not ok then
          vim.notify("atlas: " .. err, vim.log.levels.WARN)
          return
        end
      end
      M.redraw()
    end)
  end

  map("S", function()
    new_section(nil)
  end, "atlas: new section")

  map("m", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or row.kind ~= "session" then
      vim.notify("atlas: put the cursor on a session to move it", vim.log.levels.WARN)
      return
    end
    local current = sections.section_of(row.session_id)
    local NEW = "+ new section…"
    local choices = {}
    for _, n in ipairs(sections.list()) do
      if n ~= current then
        choices[#choices + 1] = n
      end
    end
    choices[#choices + 1] = NEW
    local remove = current and ("remove from " .. current) or nil
    if remove then
      choices[#choices + 1] = remove
    end
    vim.ui.select(choices, { prompt = "Move session to:" }, function(choice)
      if not choice then
        return
      elseif choice == NEW then
        new_section(row.session_id)
      elseif choice == remove then
        sections.assign(row.session_id, nil)
        M.redraw()
      else
        sections.assign(row.session_id, choice)
        M.redraw()
      end
    end)
  end, "atlas: move session to a section")

  map("R", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or row.kind ~= "section" then
      return
    end
    vim.ui.input({ prompt = "Rename section: ", default = row.name }, function(name)
      if not name then
        return
      end
      local ok, err = sections.rename(row.name, name)
      if not ok then
        vim.notify("atlas: " .. err, vim.log.levels.WARN)
        return
      end
      M.redraw()
    end)
  end, "atlas: rename section")

  map("d", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or row.kind ~= "section" then
      return
    end
    vim.ui.select({ "Delete section", "Cancel" }, {
      prompt = "Delete section '" .. row.name .. "'? Its sessions go back under their repos.",
    }, function(choice)
      if choice == "Delete section" then
        sections.remove(row.name)
        M.redraw()
      end
    end)
  end, "atlas: delete section")

  map("q", function()
    vim.cmd("close")
  end, "atlas: close sidebar")

  map("?", function()
    show_help = not show_help
    M.redraw()
  end, "atlas: show/hide all keys")

  -- The legend in the top bar follows the row under the cursor.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      M.update_legend()
    end,
  })

  return buf
end

-- Key legend. The top bar (winbar, which stays visible however long the
-- list gets -- LazyVim's statusline is global, so a per-window one
-- wouldn't show) lists the keys for the row under the cursor; `?` adds
-- the full list at the bottom.
local HINTS = {
  repo = { { "n", "new worktree" }, { "S", "new section" } },
  section = { { "R", "rename" }, { "d", "delete" }, { "S", "new" } },
  session = { { "⏎", "open" }, { "s", "send" }, { "m", "move" }, { "X", "clean" } },
  worktree = { { "⏎", "diff" }, { "y", "copy notes" } },
  -- A session whose folder was removed: closing it is the useful action.
  session_gone = { { "⏎", "open" }, { "X", "close session" } },
}

local HELP = {
  { "⏎", "session: open live view" },
  { "", "worktree: review diff" },
  { "n", "new worktree + session" },
  { "m", "move session to a section" },
  { "S", "new section" },
  { "R", "rename section" },
  { "d", "delete section" },
  { "s", "send notes to session" },
  { "X", "clean up finished worktrees" },
  { "y", "copy a worktree's notes" },
  { "r", "refresh now (incl. PR/CI)" },
  { "q", "close sidebar" },
  { "?", "hide this list" },
}
local HELP_FOOTER = "in a diff: <leader>aa adds a note"

--- The winbar string for a row kind ("repo"/"session"/"worktree"/nil).
function M.legend_for(kind)
  local parts = {}
  for _, h in ipairs(HINTS[kind] or {}) do
    parts[#parts + 1] = "%#AtlasKey#" .. h[1] .. "%#AtlasHint# " .. h[2]
  end
  parts[#parts + 1] = "%#AtlasKey#?%#AtlasHint# " .. (show_help and "less" or "more")
  return "%#AtlasHint#" .. table.concat(parts, "  ")
end

function M.update_legend()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return
  end
  local row = rows[vim.api.nvim_win_get_cursor(win)[1]]
  local kind = row and row.kind
  if kind == "session" and row.gone then
    kind = "session_gone"
  end
  vim.wo[win].winbar = M.legend_for(kind)
end

-- Display name and grouping key for a session's repo. `repos` maps a
-- session cwd to { root, name } (data.repo_of); sessions outside any
-- repo get their own group, keyed by folder.
local function repo_group(repos, cwd)
  local r = repos and repos[cwd]
  if r then
    return r.root, r.name, r.root
  end
  local label = vim.fn.isdirectory(cwd) == 1 and " (not a repo)" or " (folder removed)"
  return "dir:" .. cwd, vim.fn.fnamemodify(cwd, ":t") .. label, nil
end

local STATE_ORDER = { input = 1, done = 2, working = 3 }

local function render(sessions, touched, pr_by_path, changed, repos)
  local by_session = {}
  for _, t in ipairs(touched) do
    by_session[t.session_id] = t
  end
  local function rank(state)
    return STATE_ORDER[state] or 9
  end
  -- needing attention first, then finished, then working
  local function by_state(a, b)
    return rank(a.state) < rank(b.state)
  end

  -- Sessions the user moved into a section go there; the rest are
  -- grouped by the repo that owns their folder.
  local sec = sections.load()
  local in_section = {}
  for _, name in ipairs(sec.sections) do
    in_section[name] = {}
  end
  local groups, order = {}, {}
  for _, session in ipairs(sessions) do
    local section = sec.assign[session.session_id]
    if section and in_section[section] then
      table.insert(in_section[section], session)
    else
      local key, name, root = repo_group(repos, session.cwd or "")
      if not groups[key] then
        groups[key] = { name = name, root = root, sessions = {} }
        order[#order + 1] = key
      end
      table.insert(groups[key].sessions, session)
    end
  end
  for _, list in pairs(in_section) do
    table.sort(list, by_state)
  end
  for _, g in pairs(groups) do
    table.sort(g.sessions, by_state)
    g.rank = rank(g.sessions[1].state)
  end
  -- Repos with something needing you first, then by name.
  table.sort(order, function(a, b)
    if groups[a].rank ~= groups[b].rank then
      return groups[a].rank < groups[b].rank
    end
    return groups[a].name < groups[b].name
  end)

  local lines = {}
  local highlights = {} -- { line (0-indexed), col_start, col_end, hl_group }
  rows = {}

  -- One session and its changed worktrees. Under a section, the repo
  -- name is shown after the title, since the header no longer says it.
  local function add_session(session, show_repo)
    local _, repo_name, root = repo_group(repos, session.cwd or "")
    local indent = "  "
    local glyph = STATE_GLYPH[session.state] or "  "
    local title = session.title ~= "" and session.title or session.session_id
    local elapsed = format_elapsed(session.since)
    local line = indent .. glyph .. title
    local repo_start, repo_end
    if show_repo then
      repo_start = #line + 2
      line = line .. "  " .. repo_name
      repo_end = #line
    end
    if elapsed ~= "" then
      line = line .. "  " .. elapsed
    end
    -- Worktrees that no longer exist (e.g. removed by cleanup) are
    -- dropped right away, not after claude-status's 14-day expiry. Of the
    -- rest, only ones with something to review are shown: changes (see
    -- data.has_changes) or pending notes. `changed` is nil until the
    -- first change check finishes; until then only noted ones show, so
    -- changed repos pop in rather than unchanged ones flashing away.
    local t = by_session[session.session_id]
    local all_paths, paths = {}, {}
    if t then
      for p, _ in pairs(t.paths) do
        if vim.fn.isdirectory(p) == 1 then
          all_paths[#all_paths + 1] = p
          if (changed and changed[p]) or annotate.pending_for(session.session_id, p) > 0 then
            paths[#paths + 1] = p
          end
        end
      end
      table.sort(all_paths)
      table.sort(paths)
    end

    lines[#lines + 1] = line
    -- Cleanup gets every existing worktree, including hidden ones: a
    -- merged, clean worktree has "no changes" and is exactly what
    -- cleanup should remove.
    rows[#lines] = {
      kind = "session",
      session_id = session.session_id,
      paths = all_paths,
      root = root,
      cwd = session.cwd,
      gone = session.cwd ~= nil and session.cwd ~= "" and vim.fn.isdirectory(session.cwd) == 0,
      pane = session.tmux_pane,
    }

    local glyph_hl = STATE_HL[session.state]
    if glyph_hl then
      highlights[#highlights + 1] = { #lines - 1, #indent, #indent + #glyph, glyph_hl }
    end
    if repo_start then
      highlights[#highlights + 1] = { #lines - 1, repo_start, repo_end, "AtlasHint" }
    end
    if elapsed ~= "" then
      highlights[#highlights + 1] = { #lines - 1, #line - #elapsed, #line, "Comment" }
    end

    for _, path in ipairs(paths) do
      local wline = "      " .. vim.fn.fnamemodify(path, ":t")
      local pr = pr_by_path[path]
      if pr then
        local check_glyph = CHECK_GLYPH[pr.checks] or "•"
        local badge_start = #wline
        wline = wline .. string.format("  #%d %s", pr.number, check_glyph)
        highlights[#highlights + 1] = { #lines, badge_start, #wline, CHECK_HL[pr.checks] or "AtlasCheckNone" }
      end
      local note_count = annotate.pending_for(session.session_id, path)
      if note_count > 0 then
        local note_start = #wline
        wline = wline .. string.format("  [%d note%s]", note_count, note_count == 1 and "" or "s")
        highlights[#highlights + 1] = { #lines, note_start, #wline, "AtlasNoteBadge" }
      end
      lines[#lines + 1] = wline
      rows[#lines] = { kind = "worktree", session_id = session.session_id, path = path, root = root }
    end
  end

  -- The user's sections first, in their order, even when empty.
  for _, name in ipairs(sec.sections) do
    local sline = "▾ " .. name
    lines[#lines + 1] = sline
    rows[#lines] = { kind = "section", name = name }
    highlights[#highlights + 1] = { #lines - 1, 0, #sline, "AtlasSection" }
    if #in_section[name] == 0 then
      lines[#lines + 1] = "  (empty: m on a session moves it here)"
      highlights[#highlights + 1] = { #lines - 1, 0, #lines[#lines], "AtlasHint" }
    end
    for _, session in ipairs(in_section[name]) do
      add_session(session, true)
    end
  end

  if #sessions == 0 then
    lines[#lines + 1] = "(no live Claude Code sessions)"
  end

  -- Then everything not in a section, grouped by repo.
  for _, key in ipairs(order) do
    local g = groups[key]
    local rline = "▾ " .. g.name
    lines[#lines + 1] = rline
    rows[#lines] = { kind = "repo", root = g.root, name = g.name }
    highlights[#highlights + 1] = { #lines - 1, 0, #rline, "AtlasRepo" }
    for _, session in ipairs(g.sessions) do
      add_session(session, false)
    end
  end

  if show_help then
    lines[#lines + 1] = ""
    for _, h in ipairs(HELP) do
      -- Pad by display width, not bytes: "⏎" is 3 bytes but 1 column.
      local key = "  " .. h[1] .. string.rep(" ", 2 - vim.fn.strdisplaywidth(h[1]))
      lines[#lines + 1] = key .. "  " .. h[2]
      highlights[#highlights + 1] = { #lines - 1, 0, #key, "AtlasKey" }
      highlights[#highlights + 1] = { #lines - 1, #key, #lines[#lines], "AtlasHint" }
    end
    lines[#lines + 1] = "  " .. HELP_FOOTER
    highlights[#highlights + 1] = { #lines - 1, 0, #lines[#lines], "AtlasHint" }
  end

  local b = ensure_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.bo[b].modifiable = false
  M.update_legend()
end

local function is_open()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) ~= -1
end

-- Last local data rendered, so reopening the sidebar (or a PR fetch
-- finishing) can render instantly without waiting on claude-status.
local last = nil -- { sessions, touched, changed }
local repo_cache = {} -- session cwd -> { root, name }, or false if not a repo
local pr_in_flight = false
local changes_in_flight = false

local function render_last()
  if last and is_open() then
    render(vim.deepcopy(last.sessions), last.touched, pr_cache, last.changed, repo_cache)
  end
end

--- Re-renders from what's already loaded (no new data), e.g. after `?`.
function M.redraw()
  render_last()
  M.update_legend()
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

      -- Render now with the previous change check, then re-check which
      -- worktrees have changes (local git, a few calls per worktree) and
      -- re-render if anything appeared or disappeared.
      last = { sessions = sessions, touched = touched, changed = last and last.changed }

      -- Which repo owns each session's folder. Only new folders are
      -- looked up (a folder's repo doesn't change), in parallel, a few
      -- ms of local git -- done before rendering so the tree doesn't
      -- regroup a moment after it appears.
      local unknown = {}
      for _, s in ipairs(sessions) do
        if s.cwd and s.cwd ~= "" and repo_cache[s.cwd] == nil then
          unknown[#unknown + 1] = s.cwd
        end
      end
      local pending = #unknown
      if pending == 0 then
        render_last()
      end
      for _, cwd in ipairs(unknown) do
        data.repo_of(cwd, function(repo)
          repo_cache[cwd] = repo or false
          pending = pending - 1
          if pending == 0 then
            render_last()
          end
        end)
      end

      if not changes_in_flight then
        changes_in_flight = true
        local paths, seen = {}, {}
        for _, t in ipairs(touched) do
          for p, _ in pairs(t.paths) do
            if not seen[p] and vim.fn.isdirectory(p) == 1 then
              seen[p] = true
              paths[#paths + 1] = p
            end
          end
        end
        data.changed(paths, function(set)
          changes_in_flight = false
          if last and not vim.deep_equal(last.changed, set) then
            last.changed = set
            render_last()
          end
        end)
      end

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
  in_flight, pr_in_flight, changes_in_flight = false, false, false
  repo_cache = {}
  show_help = false
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
  M.update_legend()
  M.refresh(true)
  start_polling()
end

return M
