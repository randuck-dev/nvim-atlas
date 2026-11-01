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
local history_mod = require("atlas.history")

local M = {}

local buf = nil
local rows = {} -- line (1-indexed) -> { kind = "section"|"repo"|"session"|"worktree"|"pane"|"idle", ... }
local show_help = false -- full key list shown at the bottom (`?`)
local ns = vim.api.nvim_create_namespace("atlas_sidebar")

local config = {
  poll_ms = 5000, -- claude-status: local files, cheap
  pr_poll_ms = 30000, -- gh: network, rate-limited
  history_poll_ms = 30000, -- rescan ~/.claude/projects while "All sessions" is open
  projects_dir = nil, -- default ~/.claude/projects
  history_skip = nil, -- path prefixes to leave out (default: temp folders)
}

local timer = nil
local in_flight = false -- never run two refreshes at once
local pr_cache = {} -- path -> PR status, reused between gh polls
local pr_fetched_at = 0 -- vim.uv.now() of the last gh fetch
local history = nil -- every conversation on disk: { repos, removed, at }
local history_in_flight = false

--- Polling intervals: { poll_ms, pr_poll_ms }.
function M.configure(opts)
  opts = opts or {}
  if opts.pr_icons then
    PR_ICON = vim.tbl_extend("force", PR_ICON, opts.pr_icons)
  end
  opts.pr_icons = nil
  config = vim.tbl_extend("force", config, opts)
end

local STATE_GLYPH = { input = "● ", done = "◆ ", working = "⠋ " }

-- Working sessions get a small spinner on their state glyph: an overlay
-- extmark advanced on a timer, so each frame touches no buffer text (the
-- cursor and everything else stay put). Runs only while the sidebar is
-- open and some session is working.
local SPIN_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_ns = vim.api.nvim_create_namespace("atlas_sidebar_spinner")
local spinners = {} -- { { line (0-indexed), col }, ... } of working sessions
local spin_frame = 1
local spin_timer = nil

local function draw_spinners()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, spinner_ns, 0, -1)
  local frame = SPIN_FRAMES[spin_frame]
  for _, sp in ipairs(spinners) do
    pcall(vim.api.nvim_buf_set_extmark, buf, spinner_ns, sp[1], sp[2], {
      virt_text = { { frame, "AtlasStateWorking" } },
      virt_text_pos = "overlay",
    })
  end
end
local STATE_HL = { input = "AtlasStateInput", done = "AtlasStateDone", working = "AtlasStateWorking" }

local CHECK_GLYPH = { passing = "✓", failing = "✗", pending = "…", none = "•" }

-- PR status, shown first on a worktree row. Nerd Font Octicons; override
-- with setup({ pr_icons = { merged = "M", ... } }) if your font lacks them.
local PR_ICON = {
  merged = "\u{f419}", -- git-merge
  closed = "\u{f4dc}", -- git-pull-request-closed
  draft = "\u{f4dd}", -- git-pull-request-draft
  approved = "\u{f42e}", -- check
  changes = "\u{f467}", -- x
  review = "\u{f407}", -- git-pull-request
}
local PR_HL = {
  merged = "AtlasPrMerged",
  closed = "AtlasPrClosed",
  draft = "AtlasPrDraft",
  approved = "AtlasPrApproved",
  changes = "AtlasPrChanges",
  review = "AtlasPrReview",
}
local PR_LABEL = {
  merged = "PR merged",
  approved = "PR approved",
  review = "PR open, in review",
  changes = "PR: changes requested",
  draft = "PR draft",
  closed = "PR closed, not merged",
}
local CHECK_HL = { passing = "AtlasCheckPassing", failing = "AtlasCheckFailing", pending = "AtlasCheckPending", none = "AtlasCheckNone" }

local function setup_highlights()
  -- Rosé Pine: gold, iris, muted, love, foam.
  vim.api.nvim_set_hl(0, "AtlasStateInput", { fg = "#f6c177", default = true })
  vim.api.nvim_set_hl(0, "AtlasStateDone", { fg = "#c4a7e7", default = true })
  vim.api.nvim_set_hl(0, "AtlasStateWorking", { fg = "#3e8fb0", default = true }) -- blue (Rosé Pine Moon pine)
  vim.api.nvim_set_hl(0, "AtlasCheckPassing", { fg = "#9ccfd8", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckFailing", { fg = "#eb6f92", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckPending", { fg = "#f6c177", default = true })
  vim.api.nvim_set_hl(0, "AtlasCheckNone", { fg = "#6e6a86", default = true })
  vim.api.nvim_set_hl(0, "AtlasNoteBadge", { fg = "#ebbcba", default = true }) -- rose
  vim.api.nvim_set_hl(0, "AtlasPrMerged", { fg = "#c4a7e7", default = true }) -- purple (iris)
  vim.api.nvim_set_hl(0, "AtlasPrApproved", { fg = "#8fd18b", default = true }) -- green
  vim.api.nvim_set_hl(0, "AtlasPrReview", { fg = "#8fd18b", default = true }) -- green
  vim.api.nvim_set_hl(0, "AtlasPrDraft", { fg = "#6e6a86", default = true }) -- gray (muted)
  vim.api.nvim_set_hl(0, "AtlasPrChanges", { fg = "#eb6f92", default = true }) -- red (love)
  vim.api.nvim_set_hl(0, "AtlasPrClosed", { fg = "#eb6f92", default = true }) -- red (love)
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

-- Like format_elapsed, with days once it's past a day: for how long ago
-- a worktree last had a conversation.
local function format_ago(epoch)
  local secs = epoch and (os.time() - tonumber(epoch)) or 0
  if secs >= 86400 then
    return math.floor(secs / 86400) .. "d ago"
  end
  local e = format_elapsed(epoch)
  return e ~= "" and (e .. " ago") or ""
end

-- Notes on a worktree with no session are stored under an id of their
-- own (annotation files are named by session id).
local function note_id(path)
  return "wt-" .. vim.fn.sha256(path):sub(1, 16)
end
M._note_id = note_id

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

  -- Folding sections and repo groups, tree-style. Groups in the "All
  -- sessions" tree start collapsed, so theirs is stored as "expanded".
  local function set_folded(key, collapsed)
    if key:sub(1, 3) == "all" then
      sections.set_expanded(key, not collapsed)
    else
      sections.set_collapsed(key, collapsed)
    end
  end
  local function fold(open)
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or not row.group then
      return
    end
    local is_header = row.is_header == true
    if open then
      if is_header and row.collapsed then
        set_folded(row.group, false)
        if row.kind == "all" then
          M.load_history(false)
        end
        M.redraw()
      end
      return
    end
    -- On a header: collapse it. On a collapsed header inside another
    -- group (the All tree nests): collapse that one. Inside a group:
    -- collapse the group and jump to its header (nothing above it
    -- moves, so its line holds).
    local key, header = row.group, row.header
    if is_header and row.collapsed then
      key, header = row.parent_group, row.parent_header
    end
    if key then
      set_folded(key, true)
      M.redraw()
      vim.api.nvim_win_set_cursor(0, { header, 0 })
    end
    M.update_legend()
  end
  for _, lhs in ipairs({ "<Left>", "h" }) do
    map(lhs, function()
      fold(false)
    end, "atlas: collapse group")
  end
  for _, lhs in ipairs({ "<Right>", "l" }) do
    map(lhs, function()
      fold(true)
    end, "atlas: expand group")
  end

  map("<CR>", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and (row.kind == "all_wt" or row.kind == "all_chat") and (row.session_id or row.pane) then
      -- Live: jump in.
      if row.session_id then
        peek.open(row.session_id)
      else
        peek.open_pane(row.pane)
      end
    elseif row and row.kind == "all_chat" then
      M.resume(row)
    elseif row and row.kind == "all_more" then
      sections.set_expanded(row.key, true)
      M.redraw()
    elseif row and row.is_header then
      fold(true)
    elseif row and row.kind == "worktree" then
      require("atlas.unified").open(row.path, row.session_id)
    elseif row and row.kind == "session" then
      peek.open(row.session_id)
    elseif row and row.kind == "pane" then
      peek.open_pane(row.pane)
    elseif row and row.kind == "idle" then
      require("atlas.unified").open(row.path, note_id(row.path))
    end
  end, "atlas: review worktree / peek session under cursor")

  map("o", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (row.kind ~= "worktree" and row.kind ~= "idle") then
      return
    end
    if not row.pr_url then
      vim.notify("atlas: no PR for this worktree (yet)", vim.log.levels.INFO)
      return
    end
    local _, err = vim.ui.open(row.pr_url)
    if err then
      vim.notify("atlas: couldn't open " .. row.pr_url .. ": " .. err, vim.log.levels.ERROR)
    end
  end, "atlas: open the worktree's PR in the browser")

  map("v", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "worktree" then
      review.open(row.path, row.session_id)
    elseif row and row.kind == "idle" then
      review.open(row.path, note_id(row.path))
    end
  end, "atlas: review worktree side by side (diffview)")

  map("y", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if row and row.kind == "worktree" then
      deliver.copy_for_worktree(row.session_id, row.path, vim.fn.fnamemodify(row.path, ":t"))
    elseif row and row.kind == "idle" then
      deliver.copy_for_worktree(note_id(row.path), row.path, vim.fn.fnamemodify(row.path, ":t"))
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
    elseif row and row.kind == "idle" then
      require("atlas.cleanup").run({ row.path }, function(removed)
        if removed > 0 then
          M.refresh(true)
        end
      end)
    end
  end, "atlas: clean up this session's finished worktrees")

  map("c", function()
    local row = rows[vim.api.nvim_win_get_cursor(0)[1]]
    if not row or (row.kind ~= "idle" and row.kind ~= "all_wt") then
      return
    end
    -- Pick up where the last conversation there left off, if any.
    local ok, err = require("atlas.spawn").open_window(row.path, row.branch or vim.fn.fnamemodify(row.path, ":t"), {
      command = row.chat and "claude --continue" or "claude",
    })
    if not ok then
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.notify("atlas: started Claude in " .. vim.fn.fnamemodify(row.path, ":t"), vim.log.levels.INFO)
    vim.defer_fn(function()
      M.refresh(false)
    end, 2000)
  end, "atlas: start Claude in this worktree (continuing its last conversation)")

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

  -- Showing again after polling stopped (closed with :q, say, then
  -- shown again some other way than toggle): pick it back up.
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    callback = function()
      vim.schedule(M._resume)
    end,
  })

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
  repo = { { "←→", "fold" }, { "n", "new worktree" } },
  section = { { "←→", "fold" }, { "R", "rename" }, { "d", "delete" } },
  session = { { "⏎", "open" }, { "s", "send" }, { "m", "move" }, { "X", "clean" } },
  worktree = { { "⏎", "review" }, { "v", "split" }, { "o", "PR" }, { "y", "copy" } },
  -- A session whose folder was removed: closing it is the useful action.
  session_gone = { { "⏎", "open" }, { "X", "close session" } },
  -- Claude running in tmux that claude-status hasn't recorded.
  pane = { { "⏎", "open" } },
  -- A worktree of this repo with no session in it.
  idle = { { "⏎", "review" }, { "c", "start Claude" }, { "o", "PR" }, { "X", "clean" } },
  -- The "All sessions" tree: every conversation on this machine.
  all = { { "←→", "fold" }, { "r", "rescan" } },
  all_repo = { { "←→", "fold" }, { "n", "new worktree" } },
  all_wt = { { "←→", "fold" }, { "c", "start Claude" }, { "n", "new worktree" } },
  all_wt_live = { { "⏎", "jump in" }, { "←→", "fold" } },
  all_chat = { { "⏎", "resume" } },
  all_chat_live = { { "⏎", "jump in" } },
  all_more = { { "⏎", "show all" } },
}

local HELP = {
  { "←→", "collapse/expand (h l, ⏎ opens)" },
  { "⏎", "session: open live view" },
  { "", "worktree: review (unified)" },
  { "v", "worktree: side-by-side review" },
  { "o", "worktree: open its PR in browser" },
  { "n", "new worktree + session" },
  { "c", "idle worktree: start Claude (continues)" },
  { "", "all sessions: ⏎ resumes or jumps in" },
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
local PR_ORDER = { "merged", "approved", "review", "changes", "draft", "closed" }

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
  local kind = row and (row.legend or row.kind)
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

-- Matches the worktrees of the shown repos (extra.worktrees: root ->
-- list) to what's running in them. A worktree is "covered" when a
-- recorded session works in it or touched it; otherwise, if Claude runs
-- in a tmux pane there that claude-status doesn't know (started before
-- its hooks were installed, say), that's a "pane" row; otherwise it's
-- an "idle" worktree. The main checkout is never idle. Returns root ->
-- { panes = {...}, idle = {...} }.
local function correlate(sessions, touched, extra)
  local result = {}
  if not extra then
    return result
  end
  local all = {}
  for root, list in pairs(extra.worktrees) do
    for _, w in ipairs(list) do
      all[#all + 1] = { root = root, w = w }
    end
  end
  -- The deepest worktree containing `cwd` (worktrees can live inside
  -- the main checkout, e.g. .claude/worktrees/x).
  local function owner(cwd)
    local best
    for _, e in ipairs(all) do
      local p = e.w.path
      if (cwd == p or cwd:sub(1, #p + 1) == p .. "/") and (not best or #p > #best.w.path) then
        best = e
      end
    end
    return best
  end
  local function bucket(root)
    result[root] = result[root] or { panes = {}, idle = {} }
    return result[root]
  end

  local covered, tracked_panes, live = {}, {}, {}
  for _, s in ipairs(sessions) do
    live[s.session_id] = true
    if s.tmux_pane then
      tracked_panes[s.tmux_pane] = true
    end
    local o = s.cwd and owner(s.cwd)
    if o then
      covered[o.w.path] = true
    end
  end
  for _, t in ipairs(touched) do
    if live[t.session_id] then
      for p, _ in pairs(t.paths) do
        covered[p] = true
      end
    end
  end
  for _, p in ipairs(extra.panes) do
    local o = not tracked_panes[p.pane] and owner(p.cwd)
    if o then
      covered[o.w.path] = true
      table.insert(bucket(o.root).panes, { pane = p.pane, cwd = p.cwd, path = o.w.path, branch = o.w.branch })
    end
  end
  for root, list in pairs(extra.worktrees) do
    for i, w in ipairs(list) do
      if i > 1 and not covered[w.path] and vim.fn.isdirectory(w.path) == 1 then
        table.insert(bucket(root).idle, { path = w.path, branch = w.branch, chat = extra.chats[w.path] })
      end
    end
  end
  -- Most recently used first.
  for _, b in pairs(result) do
    table.sort(b.idle, function(x, y)
      if (x.chat or 0) ~= (y.chat or 0) then
        return (x.chat or 0) > (y.chat or 0)
      end
      return x.path < y.path
    end)
  end
  return result
end
M._correlate = correlate

-- The "All sessions" tree: every conversation on disk (history.repos)
-- plus whatever's running right now, so a worktree with a live session
-- or untracked Claude pane shows (and sorts first) even before it has
-- a transcript. Doesn't modify the cached scan.
local MAX_CHATS = 10 -- per worktree, until "… N older" is opened

local function all_view(hist, sessions, panes)
  local view, by_root, by_wt = {}, {}, {}
  local function add_repo(root, name, mtime)
    local vr = { root = root, name = name, mtime = mtime, worktrees = {} }
    by_root[root] = vr
    view[#view + 1] = vr
    return vr
  end
  local function add_wt(vr, path, mtime, chats)
    local vw = { path = path, mtime = mtime, chats = chats, sessions = {}, panes = {} }
    by_wt[path] = vw
    table.insert(vr.worktrees, vw)
    return vw
  end
  for _, r in ipairs(hist and hist.repos or {}) do
    local vr = add_repo(r.root, r.name, r.mtime)
    for _, w in ipairs(r.worktrees) do
      add_wt(vr, w.path, w.mtime, w.chats)
    end
  end
  local function wt_for(cwd)
    if not cwd or cwd == "" or vim.fn.isdirectory(cwd) == 0 then
      return nil
    end
    local g = history_mod.git_of(cwd)
    if not g then
      return nil
    end
    local vr = by_root[g.root] or add_repo(g.root, g.name, 0)
    vr.live = true
    return by_wt[g.worktree] or add_wt(vr, g.worktree, 0, {})
  end
  local tracked = {}
  for _, s in ipairs(sessions) do
    if s.tmux_pane and s.tmux_pane ~= "" then
      tracked[s.tmux_pane] = true
    end
    local vw = wt_for(s.cwd)
    if vw then
      table.insert(vw.sessions, s)
    end
  end
  for _, p in ipairs(panes) do
    if not tracked[p.pane] then
      local vw = wt_for(p.cwd)
      if vw then
        table.insert(vw.panes, p)
      end
    end
  end
  -- Live first, then most recent.
  local function order(a, b)
    local la = a.live or (a.sessions and (#a.sessions > 0 or #a.panes > 0)) or false
    local lb = b.live or (b.sessions and (#b.sessions > 0 or #b.panes > 0)) or false
    if la ~= lb then
      return la
    end
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return (a.path or a.root) < (b.path or b.root)
  end
  for _, vr in ipairs(view) do
    table.sort(vr.worktrees, order)
    for _, vw in ipairs(vr.worktrees) do
      table.sort(vw.sessions, function(x, y)
        return (STATE_ORDER[x.state] or 9) < (STATE_ORDER[y.state] or 9)
      end)
    end
  end
  table.sort(view, order)
  return view
end
M._all_view = all_view

local function render(sessions, touched, pr_by_path, changed, repos, extra)
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
  local spawned_names = require("atlas.spawn").names()
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
  -- Repos whose sessions all moved into sections still show their
  -- other worktrees under the repo.
  local others = correlate(sessions, touched, extra)
  for root, b in pairs(others) do
    if not groups[root] and (#b.panes > 0 or #b.idle > 0) then
      groups[root] = { name = vim.fn.fnamemodify(root, ":t"), root = root, sessions = {} }
      order[#order + 1] = root
    end
  end
  for _, g in pairs(groups) do
    table.sort(g.sessions, by_state)
    g.rank = g.sessions[1] and rank(g.sessions[1].state) or 9
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
  spinners = {}

  -- One session and its changed worktrees. Under a section, the repo
  -- name is shown after the title, since the header no longer says it.
  local function add_session(session, show_repo, group, header)
    local _, repo_name, root = repo_group(repos, session.cwd or "")
    local indent = "  "
    local glyph = STATE_GLYPH[session.state] or "  "
    -- A session atlas started (`n`) shows the name it was given, from
    -- the first second -- claude-status only learns titles once the
    -- session has a transcript.
    local title = spawned_names[session.cwd or ""]
      or (session.title ~= "" and session.title)
      or session.session_id
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
      group = group,
      header = header,
    }

    local glyph_hl = STATE_HL[session.state]
    if glyph_hl then
      highlights[#highlights + 1] = { #lines - 1, #indent, #indent + #glyph, glyph_hl }
    end
    if session.state == "working" then
      spinners[#spinners + 1] = { #lines - 1, #indent }
    end
    if repo_start then
      highlights[#highlights + 1] = { #lines - 1, repo_start, repo_end, "AtlasHint" }
    end
    if elapsed ~= "" then
      highlights[#highlights + 1] = { #lines - 1, #line - #elapsed, #line, "Comment" }
    end

    for _, path in ipairs(paths) do
      -- PR status first (icon + colour), so it's easy to scan; the PR
      -- number and CI result stay on the right. No PR: a blank slot,
      -- so names stay aligned.
      local pr = pr_by_path[path]
      local kind = pr and data.pr_kind(pr)
      local icon = kind and PR_ICON[kind] or " "
      local prefix = "      "
      local wline = prefix .. icon .. " " .. vim.fn.fnamemodify(path, ":t")
      if kind then
        highlights[#highlights + 1] = { #lines, #prefix, #prefix + #icon, PR_HL[kind] }
      end
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
      rows[#lines] = {
        kind = "worktree",
        session_id = session.session_id,
        pr_url = pr and pr.url,
        path = path,
        root = root,
        group = group,
        header = header,
      }
    end
  end

  -- PR icon first (a blank slot without a PR, so names stay aligned).
  -- Returns the text and adds its highlight at line index `at`.
  local function pr_icon(pr, prefix, at)
    local kind = pr and data.pr_kind(pr)
    local icon = kind and PR_ICON[kind] or " "
    if kind then
      highlights[#highlights + 1] = { at, #prefix, #prefix + #icon, PR_HL[kind] }
    end
    return prefix .. icon .. " "
  end
  local function pr_badge(pr, line, at)
    if not pr then
      return line
    end
    local start = #line
    line = line .. string.format("  #%d %s", pr.number, CHECK_GLYPH[pr.checks] or "•")
    highlights[#highlights + 1] = { at, start, #line, CHECK_HL[pr.checks] or "AtlasCheckNone" }
    return line
  end

  -- Claude running in tmux that claude-status doesn't know about.
  local function add_pane(p, group, header, root)
    local name = p.branch or vim.fn.fnamemodify(p.path, ":t")
    local line = "  ◇ " .. name
    local tag_start = #line
    line = line .. "  not tracked"
    lines[#lines + 1] = line
    rows[#lines] = { kind = "pane", pane = p.pane, cwd = p.cwd, path = p.path, root = root, group = group, header = header }
    highlights[#highlights + 1] = { #lines - 1, 2, 2 + #"◇", "AtlasHint" }
    highlights[#highlights + 1] = { #lines - 1, tag_start, #line, "AtlasHint" }
  end

  -- A worktree of the repo with no session in it.
  local function add_idle(w, group, header, root)
    local pr = pr_by_path[w.path]
    local at = #lines
    local line = pr_icon(pr, "  ", at) .. vim.fn.fnamemodify(w.path, ":t")
    local name_start = #line - #vim.fn.fnamemodify(w.path, ":t")
    highlights[#highlights + 1] = { at, name_start, #line, "AtlasHint" }
    line = pr_badge(pr, line, at)
    local notes = annotate.pending_for(note_id(w.path), w.path)
    if notes > 0 then
      local start = #line
      line = line .. string.format("  [%d note%s]", notes, notes == 1 and "" or "s")
      highlights[#highlights + 1] = { at, start, #line, "AtlasNoteBadge" }
    end
    if changed and changed[w.path] then
      local start = #line
      line = line .. "  changes"
      highlights[#highlights + 1] = { at, start, #line, "AtlasStateInput" }
    end
    local ago = w.chat and format_ago(w.chat) or ""
    local tail = ago ~= "" and ("chat " .. ago) or "no chat"
    local start = #line
    line = line .. "  " .. tail
    highlights[#highlights + 1] = { at, start, #line, "Comment" }
    lines[#lines + 1] = line
    rows[#lines] = {
      kind = "idle",
      path = w.path,
      branch = w.branch,
      chat = w.chat,
      pr_url = pr and pr.url,
      root = root,
      group = group,
      header = header,
    }
  end

  -- A section or repo header. Collapsed, it shows how many sessions are
  -- folded away, and a ● if any of them is waiting on you -- folding
  -- should never hide that. Returns whether it's collapsed and its line.
  local function add_header(row, key, name, hl, list)
    local collapsed = sec.collapsed[key] == true
    local line = (collapsed and "▸ " or "▾ ") .. name
    local name_end = #line
    local count_start, dot_start
    if collapsed then
      count_start = #line
      line = line .. string.format("  (%d)", #list)
      for _, session in ipairs(list) do
        if session.state == "input" then
          dot_start = #line + 2
          line = line .. "  ●"
          break
        end
      end
    end
    lines[#lines + 1] = line
    row.group, row.collapsed, row.header, row.is_header = key, collapsed, #lines, true
    rows[#lines] = row
    highlights[#highlights + 1] = { #lines - 1, 0, name_end, hl }
    if count_start then
      highlights[#highlights + 1] = { #lines - 1, count_start, dot_start and dot_start - 2 or #line, "AtlasHint" }
    end
    if dot_start then
      highlights[#highlights + 1] = { #lines - 1, dot_start, #line, "AtlasStateInput" }
    end
    return collapsed, #lines
  end

  -- The user's sections first, in their order, even when empty.
  for _, name in ipairs(sec.sections) do
    local key = "section:" .. name
    local collapsed, header = add_header({ kind = "section", name = name }, key, name, "AtlasSection", in_section[name])
    if not collapsed then
      if #in_section[name] == 0 then
        lines[#lines + 1] = "  (empty: m on a session moves it here)"
        highlights[#highlights + 1] = { #lines - 1, 0, #lines[#lines], "AtlasHint" }
      end
      for _, session in ipairs(in_section[name]) do
        add_session(session, true, key, header)
      end
    end
  end

  if #sessions == 0 then
    lines[#lines + 1] = "(no live Claude Code sessions)"
  end

  -- Then everything not in a section, grouped by repo.
  for _, key in ipairs(order) do
    local g = groups[key]
    local gkey = "repo:" .. key
    local collapsed, header = add_header({ kind = "repo", root = g.root, name = g.name }, gkey, g.name, "AtlasRepo", g.sessions)
    if not collapsed then
      for _, session in ipairs(g.sessions) do
        add_session(session, false, gkey, header)
      end
      local b = g.root and others[g.root]
      if b then
        for _, p in ipairs(b.panes) do
          add_pane(p, gkey, header, g.root)
        end
        for _, w in ipairs(b.idle) do
          add_idle(w, gkey, header, g.root)
        end
      end
    end
  end

  -- Last: every conversation on this machine, collapsed until opened.
  do
    local view = history and all_view(history, sessions, extra and extra.panes or {}) or nil
    local open = sec.expanded["all"] == true
    lines[#lines + 1] = ""
    local line = (open and "▾ " or "▸ ") .. "All sessions"
    local name_end = #line
    if view then
      line = line .. string.format("  (%d repo%s)", #view, #view == 1 and "" or "s")
    end
    lines[#lines + 1] = line
    local all_header = #lines
    rows[#lines] = { kind = "all", group = "all", header = #lines, collapsed = not open, is_header = true }
    highlights[#highlights + 1] = { #lines - 1, 0, name_end, "AtlasSection" }
    highlights[#highlights + 1] = { #lines - 1, name_end, #line, "AtlasHint" }

    local function hint(text)
      lines[#lines + 1] = text
      highlights[#highlights + 1] = { #lines - 1, 0, #text, "AtlasHint" }
    end
    -- Live marker: the most urgent tracked session's state, or ◇ for
    -- Claude running in tmux that claude-status doesn't know.
    local function live_glyph(vw)
      local s = vw.sessions[1]
      if s and STATE_GLYPH[s.state] then
        return STATE_GLYPH[s.state], STATE_HL[s.state], s.state == "working"
      elseif s or #vw.panes > 0 then
        return "◇ ", "AtlasHint", false
      end
      return nil
    end
    local function chats_label(n, mtime)
      local parts = {}
      if n > 0 then
        parts[#parts + 1] = n .. " chat" .. (n == 1 and "" or "s")
      end
      local ago = mtime and mtime > 0 and format_ago(mtime) or ""
      if ago ~= "" then
        parts[#parts + 1] = ago
      end
      return table.concat(parts, " · ")
    end

    if open and not view then
      hint("  loading…")
    elseif open and #view == 0 then
      hint("  (no conversations found)")
    end
    for _, vr in ipairs(open and view or {}) do
      local rkey = "all:repo:" .. vr.root
      local ropen = sec.expanded[rkey] == true
      local rline = "  " .. (ropen and "▾ " or "▸ ") .. vr.name
      local rname_end = #rline
      local glyph, glyph_hl, spins
      for _, vw in ipairs(vr.worktrees) do
        glyph, glyph_hl, spins = live_glyph(vw)
        if glyph then
          glyph = vim.trim(glyph)
          break
        end
      end
      local gstart
      if glyph then
        gstart = #rline + 2
        rline = rline .. "  " .. glyph
      end
      local nchats = 0
      for _, vw in ipairs(vr.worktrees) do
        nchats = nchats + #vw.chats
      end
      local meta = (#vr.worktrees > 1 and (#vr.worktrees .. " worktrees · ") or "") .. chats_label(nchats, vr.mtime)
      local mstart = #rline + 2
      rline = rline .. "  " .. meta
      lines[#lines + 1] = rline
      local repo_header = #lines
      rows[#lines] = {
        kind = "all_repo",
        root = vr.root,
        group = rkey,
        header = #lines,
        collapsed = not ropen,
        is_header = true,
        parent_group = "all",
        parent_header = all_header,
      }
      highlights[#highlights + 1] = { #lines - 1, 0, rname_end, "AtlasRepo" }
      if gstart then
        highlights[#highlights + 1] = { #lines - 1, gstart, gstart + #glyph, glyph_hl }
        if spins then
          spinners[#spinners + 1] = { #lines - 1, gstart }
        end
      end
      highlights[#highlights + 1] = { #lines - 1, mstart, #rline, "Comment" }

      for _, vw in ipairs(ropen and vr.worktrees or {}) do
        local wkey = "all:wt:" .. vw.path
        local wopen = sec.expanded[wkey] == true
        local wglyph, wglyph_hl, wspins = live_glyph(vw)
        local prefix = "    " .. (wopen and "▾ " or "▸ ")
        local wline = prefix .. (wglyph or "") .. vim.fn.fnamemodify(vw.path, ":t")
        local wmeta = chats_label(#vw.chats, vw.mtime)
        local wmstart = #wline + 2
        if wmeta ~= "" then
          wline = wline .. "  " .. wmeta
        end
        lines[#lines + 1] = wline
        local wt_header = #lines
        local s, p = vw.sessions[1], vw.panes[1]
        local live = s ~= nil or p ~= nil
        rows[#lines] = {
          kind = "all_wt",
          legend = live and "all_wt_live" or "all_wt",
          path = vw.path,
          root = vr.root,
          chat = #vw.chats > 0,
          session_id = s and s.session_id,
          pane = not s and p and p.pane or nil,
          group = wkey,
          header = #lines,
          collapsed = not wopen,
          is_header = true,
          parent_group = rkey,
          parent_header = repo_header,
        }
        if wglyph then
          highlights[#highlights + 1] = { #lines - 1, #prefix, #prefix + #wglyph, wglyph_hl }
          if wspins then
            spinners[#spinners + 1] = { #lines - 1, #prefix }
          end
        end
        if wmeta ~= "" then
          highlights[#highlights + 1] = { #lines - 1, wmstart, #wline, "Comment" }
        end

        if wopen then
          -- Which conversations are running: tracked sessions know theirs.
          local live_chat = {}
          for _, ses in ipairs(vw.sessions) do
            live_chat[ses.session_id] = ses
            if ses.transcript then
              live_chat[ses.transcript] = ses
            end
          end
          local more_key = "all:more:" .. vw.path
          local limit = sec.expanded[more_key] and #vw.chats or math.min(#vw.chats, MAX_CHATS)
          for i = 1, limit do
            local c = vw.chats[i]
            local ses = live_chat[c.id] or live_chat[c.file]
            local title = (ses and ses.title ~= "" and ses.title) or history_mod.title(c.file) or ("(untitled) " .. c.id:sub(1, 8))
            local cprefix = "        "
            local cglyph = ses and STATE_GLYPH[ses.state] or ""
            local cline = cprefix .. cglyph .. title
            local ago = format_ago(c.mtime)
            if ago ~= "" then
              cline = cline .. "  " .. ago
            end
            lines[#lines + 1] = cline
            rows[#lines] = {
              kind = "all_chat",
              legend = ses and "all_chat_live" or "all_chat",
              id = c.id,
              cwd = c.cwd,
              path = vw.path,
              title = title,
              root = vr.root,
              session_id = ses and ses.session_id,
              group = wkey,
              header = wt_header,
            }
            if cglyph ~= "" then
              highlights[#highlights + 1] = { #lines - 1, #cprefix, #cprefix + #cglyph, STATE_HL[ses.state] }
              if ses.state == "working" then
                spinners[#spinners + 1] = { #lines - 1, #cprefix }
              end
            end
            if ago ~= "" then
              highlights[#highlights + 1] = { #lines - 1, #cline - #ago, #cline, "Comment" }
            end
          end
          if limit < #vw.chats then
            hint(string.format("        … %d older", #vw.chats - limit))
            rows[#lines] = { kind = "all_more", key = more_key, root = vr.root, group = wkey, header = wt_header }
          end
          if #vw.chats == 0 then
            hint("        (no conversation saved yet)")
          end
        end
      end
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
    lines[#lines + 1] = ""
    for _, kind in ipairs(PR_ORDER) do
      local icon = PR_ICON[kind]
      lines[#lines + 1] = "  " .. icon .. string.rep(" ", 4 - vim.fn.strdisplaywidth(icon)) .. PR_LABEL[kind]
      highlights[#highlights + 1] = { #lines - 1, 2, 2 + #icon, PR_HL[kind] }
      highlights[#highlights + 1] = { #lines - 1, 2 + #icon, #lines[#lines], "AtlasHint" }
    end
  end

  local b = ensure_buf()
  vim.bo[b].modifiable = true
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  draw_spinners()
  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(b, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  vim.bo[b].modifiable = false
  M.update_legend()
end

-- Open in any tab, not just the current one: a review opens its own
-- tab, and polling must not stop (for good) while you're in it.
local function is_open()
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0
end

-- Last local data rendered, so reopening the sidebar (or a PR fetch
-- finishing) can render instantly without waiting on claude-status.
local last = nil -- { sessions, touched, changed, extra }
local repo_cache = {} -- session cwd -> { root, name }, or false if not a repo
local pr_in_flight = false
local changes_in_flight = false

local function render_last()
  if last and is_open() then
    render(vim.deepcopy(last.sessions), last.touched, pr_cache, last.changed, repo_cache, last.extra)
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
local function refresh_prs(paths)
  if pr_in_flight then
    return
  end
  pr_in_flight = true
  data.pr_status(paths, function(pr_by_path)
    pr_in_flight = false
    pr_cache = pr_by_path
    pr_fetched_at = vim.uv.now()
    render_last()
  end)
end

-- The worktrees of every repo a live session is in, the tmux panes
-- running Claude, and when each worktree last had a conversation.
-- cb({ worktrees = root -> list, panes = list, chats = path -> epoch }).
local function load_extra(sessions, cb)
  local roots, seen = {}, {}
  for _, s in ipairs(sessions) do
    local r = s.cwd and repo_cache[s.cwd]
    if r and not seen[r.root] then
      seen[r.root] = true
      roots[#roots + 1] = r.root
    end
  end
  local extra = { worktrees = {}, panes = {}, chats = {} }
  local pending = #roots + 1
  local function done()
    pending = pending - 1
    if pending == 0 then
      for _, list in pairs(extra.worktrees) do
        for _, w in ipairs(list) do
          extra.chats[w.path] = data.last_conversation(w.path)
        end
      end
      cb(extra)
    end
  end
  for _, root in ipairs(roots) do
    data.worktrees(root, function(list)
      extra.worktrees[root] = list
      done()
    end)
  end
  data.claude_panes(function(panes)
    extra.panes = panes
    done()
  end)
end

-- Every worktree worth checking for changes and PRs: those sessions
-- touched, plus the repos' other worktrees (not main checkouts).
local function review_paths(touched, extra)
  local paths, seen = {}, {}
  local function add(p)
    if not seen[p] and vim.fn.isdirectory(p) == 1 then
      seen[p] = true
      paths[#paths + 1] = p
    end
  end
  for _, t in ipairs(touched) do
    for p, _ in pairs(t.paths) do
      add(p)
    end
  end
  for _, list in pairs(extra and extra.worktrees or {}) do
    for i, w in ipairs(list) do
      if i > 1 then
        add(w.path)
      end
    end
  end
  return paths
end

--- Rescans ~/.claude/projects for the "All sessions" tree, in the
--- background, if it's open and the last scan is older than
--- history_poll_ms (or `force`). Re-renders when done.
function M.load_history(force)
  if history_in_flight or not sections.is_expanded("all") then
    return
  end
  if not force and history and vim.uv.now() - history.at < config.history_poll_ms then
    return
  end
  history_in_flight = true
  local opts = config.history_skip and { skip = config.history_skip } or nil
  history_mod.scan_async(config.projects_dir, opts, function(repos, removed)
    history_in_flight = false
    history = { repos = repos, removed = removed, at = vim.uv.now() }
    render_last()
  end)
end

--- Resumes a conversation from the All tree in a new tmux window
--- (`claude --resume <id>` in its folder) and opens its live view.
function M.resume(row)
  local spawn = require("atlas.spawn")
  local name = vim.fn.fnamemodify(row.path, ":t") .. "-" .. row.id:sub(1, 6)
  local ok, err = spawn.open_window(row.cwd, name, { command = "claude --resume " .. vim.fn.shellescape(row.id) })
  if not ok then
    vim.notify("atlas: " .. err, vim.log.levels.ERROR)
    return
  end
  -- The window opens in the background; find its pane to jump in.
  local res = vim.system({ "tmux", "list-panes", "-s", "-F", "#{window_name}|#{pane_id}" }, { text = true }):wait()
  local pane
  for l in ((res.code == 0 and res.stdout or "") .. "\n"):gmatch("(.-)\n") do
    local w, id = l:match("^(.*)|(%%%d+)$")
    if w == name:gsub("/", "-") then
      pane = id
    end
  end
  if pane then
    peek.open_pane(pane)
  else
    vim.notify("atlas: resumed " .. row.title .. " in tmux window " .. name, vim.log.levels.INFO)
  end
  vim.defer_fn(function()
    M.refresh(false)
  end, 2000)
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
  M.load_history(force)

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
      last = { sessions = sessions, touched = touched, changed = last and last.changed, extra = last and last.extra }

      -- Once the repos are known: their worktrees and any Claude
      -- running in tmux, then which worktrees have changes, then PRs.
      local function after_repos()
        render_last()
        load_extra(sessions, function(extra)
          if not last then
            return
          end
          if not vim.deep_equal(last.extra, extra) then
            last.extra = extra
            render_last()
          end
          local paths = review_paths(touched, extra)
          if not changes_in_flight then
            changes_in_flight = true
            data.changed(paths, function(set)
              changes_in_flight = false
              if last and not vim.deep_equal(last.changed, set) then
                last.changed = set
                render_last()
              end
            end)
          end
          if force or vim.uv.now() - pr_fetched_at >= config.pr_poll_ms then
            refresh_prs(paths)
          end
        end)
      end

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
        after_repos()
      end
      for _, cwd in ipairs(unknown) do
        data.repo_of(cwd, function(repo)
          repo_cache[cwd] = repo or false
          pending = pending - 1
          if pending == 0 then
            after_repos()
          end
        end)
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
  if spin_timer and not spin_timer:is_closing() then
    spin_timer:stop()
    spin_timer:close()
  end
  spin_timer = nil
end

local function start_polling()
  stop_polling()
  spin_timer = vim.uv.new_timer()
  spin_timer:start(
    100,
    100,
    vim.schedule_wrap(function()
      if #spinners > 0 and is_open() then
        spin_frame = spin_frame % #SPIN_FRAMES + 1
        draw_spinners()
      end
    end)
  )
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

--- Restarts polling (and refreshes) if the sidebar is showing but
--- polling has stopped.
function M._resume()
  if is_open() and not (timer and not timer:is_closing()) then
    start_polling()
    M.refresh(false)
  end
end

--- Forgets cached state and in-flight flags (for tests).
function M._reset()
  stop_polling()
  in_flight, pr_in_flight, changes_in_flight = false, false, false
  repo_cache = {}
  show_help = false
  last, pr_cache, pr_fetched_at = nil, {}, 0
  history, history_in_flight = nil, false
end

--- True while the spinner timer is running (for tests).
function M._spinning()
  return spin_timer ~= nil and not spin_timer:is_closing()
end

--- True while the background refresh timer is running (for tests).
function M._polling()
  return timer ~= nil and not timer:is_closing()
end

--- Focuses the sidebar (if open) with the cursor on session_id's row
--- (or, for Claude claude-status doesn't know, the pane id's row).
--- Returns true if it found the window.
function M.focus_session(session_id)
  local win = buf and vim.api.nvim_buf_is_valid(buf) and vim.fn.bufwinid(buf) or -1
  if win == -1 then
    return false
  end
  vim.api.nvim_set_current_win(win)
  for lnum = 1, vim.api.nvim_buf_line_count(buf) do
    local row = rows[lnum]
    if row and ((row.kind == "session" and row.session_id == session_id) or (row.kind == "pane" and row.pane == session_id)) then
      vim.api.nvim_win_set_cursor(win, { lnum, 0 })
      break
    end
  end
  M.update_legend()
  return true
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
  -- LazyVim enables relativenumber and a statuscolumn that draws
  -- its own numbers; neither is useful here.
  vim.wo[0].relativenumber = false
  vim.wo[0].statuscolumn = ""
  vim.wo[0].foldcolumn = "0"
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
