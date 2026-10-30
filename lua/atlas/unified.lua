-- GitHub-style unified review of a worktree: everything it changed since
-- its merge base (committed, uncommitted and untracked), in one
-- scrolling buffer. diffview.nvim can't do this -- its layouts are all
-- two linked buffers -- so atlas renders the diff itself, which also
-- means it knows which file/line every row is, for notes.
--
-- Rows: a header per file, @@ hunk headers, then context/-/+ lines with
-- old/new line numbers in an inline gutter. Notes (<leader>aa) work as
-- in diffview and show inline at end of line.

local data = require("atlas.data")

local M = {}

local ns = vim.api.nvim_create_namespace("atlas_unified")

-- bufnr -> { path, session_id, base, target, rows = { [lnum] = { file, old, new, kind } } }
local views = {}

local function hl()
  vim.api.nvim_set_hl(0, "AtlasDiffFile", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "AtlasDiffHunk", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "AtlasDiffAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "AtlasDiffDelete", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "AtlasDiffGutter", { link = "LineNr", default = true })
  vim.api.nvim_set_hl(0, "AtlasKey", { fg = "#f6c177", bold = true, default = true })
  vim.api.nvim_set_hl(0, "AtlasHint", { fg = "#6e6a86", default = true })
  vim.api.nvim_set_hl(0, "AtlasStatusM", { fg = "#f6c177", bold = true, default = true }) -- gold
  vim.api.nvim_set_hl(0, "AtlasStatusA", { fg = "#9ccfd8", default = true }) -- foam
  vim.api.nvim_set_hl(0, "AtlasStatusD", { fg = "#eb6f92", default = true }) -- love
  vim.api.nvim_set_hl(0, "AtlasStatusR", { fg = "#c4a7e7", bold = true, default = true }) -- iris
end

--- Parses `git diff` output into display lines plus a per-line map.
--- Returns lines, rows, where rows[i] = { kind, file, old, new }:
--- kind is "file" | "hunk" | "ctx" | "add" | "del" | "meta".
function M.parse(diff_text)
  local lines, rows = {}, {}
  local file, flag
  local old, new = 0, 0

  local function emit(text, row)
    lines[#lines + 1] = text
    rows[#lines] = row
  end

  local function file_header()
    if file then
      local suffix = flag and ("  (" .. flag .. ")") or ""
      emit("▍ " .. file .. suffix, { kind = "file", file = file, flag = flag })
    end
  end

  local pending_header = false
  for raw in (diff_text .. "\n"):gmatch("(.-)\n") do
    local a, b = raw:match("^diff %-%-git a/(.-) b/(.*)$")
    if a then
      if pending_header then
        file_header() -- previous file had no hunks (e.g. mode change)
      end
      file, flag = b, nil
      pending_header = true
    elseif raw:match("^new file mode") then
      flag = "new"
    elseif raw:match("^deleted file mode") then
      flag = "deleted"
    elseif raw:match("^rename from ") then
      flag = "renamed from " .. raw:match("^rename from (.*)$")
    elseif raw:match("^%-%-%- ") or raw:match("^index ") or raw:match("^similarity index")
      or raw:match("^rename to ") or raw:match("^old mode") or raw:match("^new mode")
      or raw:match("^dissimilarity") then
      -- folded into the file header
    elseif raw:match("^%+%+%+ ") then
      local p = raw:match("^%+%+%+ b/(.*)$")
      if p then
        file = p
      end
    elseif raw:match("^@@") then
      if pending_header then
        file_header()
        pending_header = false
      end
      local o, n = raw:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      old, new = tonumber(o) or 0, tonumber(n) or 0
      emit(raw, { kind = "hunk", file = file, new = new })
    elseif raw:match("^Binary files") then
      if pending_header then
        file_header()
        pending_header = false
      end
      emit("  binary file changed", { kind = "meta", file = file })
    elseif file and raw:sub(1, 1) == "+" then
      emit(raw, { kind = "add", file = file, new = new })
      new = new + 1
    elseif file and raw:sub(1, 1) == "-" then
      -- A removed line has no line in the new file; notes on it attach
      -- to where it was removed.
      emit(raw, { kind = "del", file = file, old = old, new = new })
      old = old + 1
    elseif file and raw:sub(1, 1) == " " then
      emit(raw, { kind = "ctx", file = file, old = old, new = new })
      old, new = old + 1, new + 1
    elseif raw:sub(1, 1) == "\\" then
      emit(raw, { kind = "meta", file = file })
    end
  end
  if pending_header then
    file_header()
  end
  return lines, rows
end

local function sh(args, cwd)
  local r = vim.system(args, { text = true, cwd = cwd }):wait()
  -- `git diff --no-index` exits 1 when files differ: that's success here.
  return (r.code == 0 or r.code == 1), r.stdout or ""
end

--- The full diff text for `path` against `base`: tracked changes
--- (committed + uncommitted) plus untracked files as additions.
function M.diff_text(path, base)
  local _, tracked = sh({ "git", "-C", path, "diff", "--no-color", "--no-ext-diff", base })
  local _, untracked = sh({ "git", "-C", path, "ls-files", "--others", "--exclude-standard" })
  local parts = { tracked }
  for f in untracked:gmatch("[^\n]+") do
    local _, d = sh({ "git", "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", f }, path)
    parts[#parts + 1] = d
  end
  return table.concat(parts, "\n")
end

local function gutter(row)
  local o, n = "", ""
  if row.kind == "ctx" then
    o, n = row.old, row.new
  elseif row.kind == "add" then
    n = row.new
  elseif row.kind == "del" then
    o = row.old
  end
  return string.format("%4s %4s │ ", o, n)
end

local function paint(buf)
  local view = views[buf]
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, row in pairs(view.rows) do
    local opts = {}
    if row.kind == "file" then
      opts.line_hl_group = "AtlasDiffFile"
    elseif row.kind == "hunk" or row.kind == "meta" then
      opts.line_hl_group = "AtlasDiffHunk"
    elseif row.kind == "add" then
      opts.line_hl_group = "AtlasDiffAdd"
    elseif row.kind == "del" then
      opts.line_hl_group = "AtlasDiffDelete"
    end
    if row.kind == "ctx" or row.kind == "add" or row.kind == "del" then
      opts.virt_text = { { gutter(row), "AtlasDiffGutter" } }
      opts.virt_text_pos = "inline"
    end
    vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, opts)
  end
  M.render_notes(buf)
end

-- File panel: the changed files, in diff order, on the left of the
-- unified view (like diffview's file panel).
local panel_ns = vim.api.nvim_create_namespace("atlas_unified_panel")
local current_ns = vim.api.nvim_create_namespace("atlas_unified_panel_current")

local function status_of(flag)
  if not flag then
    return "M"
  elseif flag == "new" then
    return "A"
  elseif flag == "deleted" then
    return "D"
  elseif flag:match("^renamed") then
    return "R"
  end
  return "M"
end

local STATUS_HL = { M = "AtlasStatusM", A = "AtlasStatusA", D = "AtlasStatusD", R = "AtlasStatusR" }

--- Changed files in diff order:
--- { file, line (its header's buffer line), status, adds, dels }[].
function M.files(rows)
  local list, by_file = {}, {}
  local last = 0
  for l in pairs(rows) do
    last = math.max(last, l)
  end
  for l = 1, last do
    local row = rows[l]
    if row and row.kind == "file" then
      local f = { file = row.file, line = l, status = status_of(row.flag), adds = 0, dels = 0 }
      list[#list + 1] = f
      by_file[row.file] = f
    elseif row and by_file[row.file] then
      if row.kind == "add" then
        by_file[row.file].adds = by_file[row.file].adds + 1
      elseif row.kind == "del" then
        by_file[row.file].dels = by_file[row.file].dels + 1
      end
    end
  end
  return list
end

local function render_panel(buf)
  local view = views[buf]
  local pbuf = view.panel_buf
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return
  end
  view.files = M.files(view.rows)
  local lines, hls = {}, {}
  for _, f in ipairs(view.files) do
    local head = " " .. f.status .. "  " .. f.file
    local adds, dels = "+" .. f.adds, "-" .. f.dels
    lines[#lines + 1] = head .. "  " .. adds .. " " .. dels
    local l = #lines - 1
    hls[#hls + 1] = { l, 1, 2, STATUS_HL[f.status] }
    hls[#hls + 1] = { l, #head + 2, #head + 2 + #adds, "AtlasStatusA" }
    hls[#hls + 1] = { l, #head + 3 + #adds, #lines[#lines], "AtlasStatusD" }
  end
  if #lines == 0 then
    lines = { " (no changed files)" }
  end
  vim.bo[pbuf].modifiable = true
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.bo[pbuf].modifiable = false
  vim.api.nvim_buf_clear_namespace(pbuf, panel_ns, 0, -1)
  for _, h in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(pbuf, panel_ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

--- Index (into view.files) of the file the diff cursor is in, or nil.
local function current_file_index(buf)
  local view = views[buf]
  local win = vim.fn.bufwinid(buf)
  if not view or not view.files or win == -1 then
    return nil
  end
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local idx
  for i, f in ipairs(view.files) do
    if f.line <= cur then
      idx = i
    end
  end
  return idx
end

--- Highlights the file the diff cursor is in, in the panel.
local function mark_current(buf)
  local view = views[buf]
  local pbuf = view and view.panel_buf
  if not pbuf or not vim.api.nvim_buf_is_valid(pbuf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(pbuf, current_ns, 0, -1)
  local idx = current_file_index(buf)
  if idx then
    vim.api.nvim_buf_set_extmark(pbuf, current_ns, idx - 1, 0, { line_hl_group = "CursorLine" })
  end
end

--- Index of the file under the panel cursor, for tests and <CR>.
function M._current_file(buf)
  local i = current_file_index(buf)
  return i and views[buf].files[i].file
end


--- Fills `buf` with the current diff of its view. Returns ok, err.
local function load(buf)
  local view = views[buf]
  local text = M.diff_text(view.path, view.base)
  local lines, rows = M.parse(text)
  if #lines == 0 then
    lines = { "(no changes against " .. view.target .. ")" }
    rows = {}
  end
  view.rows = rows
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  paint(buf)
  render_panel(buf)
  mark_current(buf)
end

function M.is_unified(buf)
  return views[buf == 0 and vim.api.nvim_get_current_buf() or buf] ~= nil
end

--- Maps buffer lines line1..line2 to a file and new-file line range,
--- for notes. Uses the file of the first mapped line in the range.
--- Returns file, start, end -- or nil if nothing in range maps.
function M.resolve(buf, line1, line2)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local view = views[buf]
  if not view then
    return nil
  end
  local file, first, last
  for l = line1, line2 do
    local row = view.rows[l]
    if row and row.file and row.new and row.kind ~= "file" then
      if not file then
        file = row.file
      end
      if row.file == file then
        first = first and math.min(first, row.new) or row.new
        last = last and math.max(last, row.new) or row.new
      end
    end
  end
  if not file then
    return nil
  end
  return file, first, last
end

--- Shows pending notes as diagnostics below the first row each covers.
function M.render_notes(buf)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local view = views[buf]
  if not view then
    return
  end
  local annotate = require("atlas.annotate")
  local last = 0
  for l in pairs(view.rows) do
    last = math.max(last, l)
  end
  local items = {}
  for _, n in ipairs(annotate.load(view.session_id)) do
    if n.worktree == view.path then
      -- First and last buffer rows of the file's lines in the note's
      -- range. Not removed rows: their position is shared with the row
      -- that replaced them.
      local first, final
      for l = 1, last do
        local row = view.rows[l]
        if row and row.file == n.file and row.new and (row.kind == "add" or row.kind == "ctx")
          and row.new >= n.line_start and row.new <= n.line_end then
          first = first or l
          final = l
        end
      end
      if first then
        items[#items + 1] = { first - 1, final - 1, n.text }
      end
    end
  end
  annotate.show(buf, items)
end

local function jump(buf, kind, dir)
  local view = views[buf]
  local cur = vim.api.nvim_win_get_cursor(0)[1]
  local count = vim.api.nvim_buf_line_count(buf)
  local l = cur + dir
  while l >= 1 and l <= count do
    local row = view.rows[l]
    if row and row.kind == kind then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return
    end
    l = l + dir
  end
end

--- Opens the unified review of `path` (a worktree) in a new tab.
--- `session_id` ties notes left here to that session.
function M.open(path, session_id)
  data.merge_base(path, function(base, target, err)
    if err then
      vim.notify("atlas: couldn't compute merge base for " .. path .. ": " .. err, vim.log.levels.ERROR)
      return
    end
    hl()
    vim.cmd("tabnew")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "AtlasReview"
    pcall(vim.api.nvim_buf_set_name, buf, "atlas://review/" .. vim.fn.fnamemodify(path, ":t"))
    vim.wo[0].number = false
    vim.wo[0].relativenumber = false
    vim.wo[0].signcolumn = "no"
    vim.wo[0].wrap = false
    vim.wo[0].winbar = "%#AtlasHint#"
      .. vim.fn.fnamemodify(path, ":t") .. " vs " .. target
      .. "   %#AtlasKey#␣aa%#AtlasHint# note  %#AtlasKey#]c%#AtlasHint# hunk  %#AtlasKey#]f%#AtlasHint# file"
      .. "  %#AtlasKey#⏎%#AtlasHint# open file  %#AtlasKey#r%#AtlasHint# reload  %#AtlasKey#q%#AtlasHint# close"

    vim.t.atlas_review = { path = path, session_id = session_id, base = base, target = target, unified = true }
    views[buf] = { path = path, session_id = session_id, base = base, target = target, rows = {} }
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function()
        views[buf] = nil
      end,
    })

    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = desc })
    end
    map("q", function()
      if #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd("tabclose")
      else
        vim.cmd("bdelete")
      end
    end, "atlas: close review")
    map("r", function()
      load(buf)
    end, "atlas: reload diff")
    map("]c", function()
      jump(buf, "hunk", 1)
    end, "atlas: next hunk")
    map("[c", function()
      jump(buf, "hunk", -1)
    end, "atlas: previous hunk")
    map("]f", function()
      jump(buf, "file", 1)
    end, "atlas: next file")
    map("[f", function()
      jump(buf, "file", -1)
    end, "atlas: previous file")
    map("<CR>", function()
      local row = views[buf].rows[vim.api.nvim_win_get_cursor(0)[1]]
      if row and row.file and row.kind ~= "del" then
        local target_line = row.new or 1
        -- A split, so the review stays (its buffer is wiped when hidden).
        vim.cmd("vsplit " .. vim.fn.fnameescape(path .. "/" .. row.file))
        pcall(vim.api.nvim_win_set_cursor, 0, { math.max(target_line, 1), 0 })
      end
    end, "atlas: open file at this line")

    -- The file panel on the left.
    local main_win = vim.api.nvim_get_current_win()
    vim.cmd("topleft vnew")
    local pbuf = vim.api.nvim_get_current_buf()
    vim.bo[pbuf].buftype = "nofile"
    vim.bo[pbuf].bufhidden = "wipe"
    vim.bo[pbuf].swapfile = false
    vim.bo[pbuf].filetype = "AtlasReviewFiles"
    vim.api.nvim_win_set_width(0, 34)
    vim.wo[0].winfixwidth = true
    vim.wo[0].number = false
    vim.wo[0].relativenumber = false
    vim.wo[0].signcolumn = "no"
    vim.wo[0].wrap = false
    vim.wo[0].winbar = "%#AtlasKey#⏎%#AtlasHint# jump to file  %#AtlasKey#q%#AtlasHint# close"
    views[buf].panel_buf = pbuf

    vim.keymap.set("n", "<CR>", function()
      local view = views[buf]
      local f = view and view.files and view.files[vim.api.nvim_win_get_cursor(0)[1]]
      local win = vim.fn.bufwinid(buf)
      if f and win ~= -1 then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { f.line, 0 })
        vim.cmd("normal! zt")
        mark_current(buf)
      end
    end, { buffer = pbuf, nowait = true, desc = "atlas: jump to file" })
    vim.keymap.set("n", "q", function()
      if #vim.api.nvim_list_tabpages() > 1 then
        vim.cmd("tabclose")
      end
    end, { buffer = pbuf, nowait = true, desc = "atlas: close review" })

    vim.api.nvim_create_autocmd("CursorMoved", {
      buffer = buf,
      callback = function()
        mark_current(buf)
      end,
    })
    vim.api.nvim_set_current_win(main_win)

    load(buf)
  end)
end

return M
