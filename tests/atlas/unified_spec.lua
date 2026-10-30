local unified = require("atlas.unified")
local annotate = require("atlas.annotate")

describe("atlas.unified.parse", function()
  it("maps every row to its file and old/new line numbers", function()
    local text = table.concat({
      "diff --git a/src/a.lua b/src/a.lua",
      "index 111..222 100644",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -10,3 +10,4 @@ function x()",
      " keep",
      "-old line",
      "+new line",
      "+another",
      " tail",
      "diff --git a/new.txt b/new.txt",
      "new file mode 100644",
      "--- /dev/null",
      "+++ b/new.txt",
      "@@ -0,0 +1,2 @@",
      "+hello",
      "+world",
      "diff --git a/gone.txt b/gone.txt",
      "deleted file mode 100644",
      "--- a/gone.txt",
      "+++ /dev/null",
      "@@ -1 +0,0 @@",
      "-bye",
      "diff --git a/img.png b/img.png",
      "Binary files a/img.png and b/img.png differ",
    }, "\n")
    local lines, rows = unified.parse(text)

    assert.are.equal("▍ src/a.lua", lines[1])
    assert.are.equal("hunk", rows[2].kind)
    assert.are.same({ kind = "ctx", file = "src/a.lua", old = 10, new = 10 }, rows[3])
    assert.are.same({ kind = "del", file = "src/a.lua", old = 11, new = 11 }, rows[4])
    assert.are.same({ kind = "add", file = "src/a.lua", new = 11 }, rows[5])
    assert.are.same({ kind = "add", file = "src/a.lua", new = 12 }, rows[6])
    assert.are.same({ kind = "ctx", file = "src/a.lua", old = 12, new = 13 }, rows[7])

    assert.are.equal("▍ new.txt  (new)", lines[8])
    assert.are.same({ kind = "add", file = "new.txt", new = 1 }, rows[10])
    assert.are.equal("▍ gone.txt  (deleted)", lines[12])
    assert.are.equal("▍ img.png", lines[15])
    assert.are.equal("  binary file changed", lines[16])
  end)

  it("shows a rename as one file with where it came from", function()
    local lines = unified.parse(table.concat({
      "diff --git a/old.txt b/new.txt",
      "similarity index 90%",
      "rename from old.txt",
      "rename to new.txt",
      "--- a/old.txt",
      "+++ b/new.txt",
      "@@ -1 +1 @@",
      "-a",
      "+b",
    }, "\n"))
    assert.are.equal("▍ new.txt  (renamed from old.txt)", lines[1])
  end)
end)

describe("atlas.unified review (real git)", function()
  local root, wt, real_input
  local sids = {}

  -- Session ids for notes; their files are deleted in after_each even
  -- when a test fails halfway.
  local function new_sid()
    local sid = "atlas-unified-test-" .. string.format("%d", vim.uv.hrtime())
    sids[#sids + 1] = sid
    return sid
  end

  local function git(dir, args)
    local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    assert(r.code == 0, "git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""))
  end

  local function open_review(sid)
    local before = vim.api.nvim_get_current_buf()
    unified.open(wt, sid)
    -- Wait for *this* review: opening is async (merge base first).
    assert.is_true(vim.wait(5000, function()
      local b = vim.api.nvim_get_current_buf()
      return b ~= before and unified.is_unified(b) and vim.api.nvim_buf_line_count(b) > 1
    end, 20), "review should open")
    return vim.api.nvim_get_current_buf()
  end

  local function line_of(buf, text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if l == text then
        return i
      end
    end
  end

  before_each(function()
    real_input = vim.ui.input
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/main", "p")
    git(root .. "/main", { "init", "-q", "-b", "main" })
    git(root .. "/main", { "config", "user.email", "t@example.com" })
    git(root .. "/main", { "config", "user.name", "t" })
    vim.fn.writefile({ "one", "two", "three", "four", "five" }, root .. "/main/f.txt")
    git(root .. "/main", { "add", "." })
    git(root .. "/main", { "commit", "-q", "-m", "init" })
    wt = root .. "/wt"
    git(root .. "/main", { "worktree", "add", "-q", wt, "-b", "feature" })
    -- committed change, then an uncommitted one, and an untracked file
    vim.fn.writefile({ "one", "TWO", "three", "four", "five" }, wt .. "/f.txt")
    git(wt, { "commit", "-q", "-am", "uppercase two" })
    vim.fn.writefile({ "one", "TWO", "three", "four", "five", "six" }, wt .. "/f.txt")
    vim.fn.writefile({ "brand new" }, wt .. "/new.txt")
  end)

  after_each(function()
    vim.ui.input = real_input
    -- Back to the first (non-review) tab, then close the rest.
    vim.cmd("tabfirst")
    vim.cmd("silent! tabonly")
    vim.fn.delete(root, "rf")
    for _, sid in ipairs(sids) do
      vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
    end
    sids = {}
  end)

  it("shows committed, uncommitted and untracked changes in one buffer", function()
    local buf = open_review(new_sid())
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(text:find("▍ f.txt", 1, true))
    assert.truthy(text:find("-two", 1, true))
    assert.truthy(text:find("+TWO", 1, true))
    assert.truthy(text:find("+six", 1, true), "uncommitted change")
    assert.truthy(text:find("▍ new.txt  (new)", 1, true), "untracked file")
    assert.truthy(text:find("+brand new", 1, true))
    assert.are.equal("main", vim.t.atlas_review.target)

    -- +/- rows are coloured and carry the line-number gutter.
    local ns = vim.api.nvim_create_namespace("atlas_unified")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { line_of(buf, "+TWO") - 1, 0 }, { line_of(buf, "+TWO") - 1, -1 }, { details = true })
    assert.are.equal("AtlasDiffAdd", marks[1][4].line_hl_group)
    assert.truthy(marks[1][4].virt_text[1][1]:find("2 │", 1, true))
  end)

  it("<leader>aa notes record the real file and line, and show on that row", function()
    local sid = new_sid()
    local buf = open_review(sid)
    vim.ui.input = function(_, cb)
      cb("why uppercase?")
    end

    local l = line_of(buf, "+TWO")
    annotate.add(l, l)

    local notes = annotate.load(sid)
    assert.are.equal(1, #notes)
    assert.are.equal("f.txt", notes[1].file)
    assert.are.equal(2, notes[1].line_start)
    assert.are.equal(wt, notes[1].worktree)

    local d = vim.diagnostic.get(buf, { namespace = annotate.ns })
    assert.are.equal(1, #d)
    assert.are.equal(l - 1, d[1].lnum)
    assert.truthy(d[1].message:find("why uppercase?", 1, true))

  end)

  it("a note across a selection maps to that file's line range", function()
    local sid = new_sid()
    local buf = open_review(sid)
    vim.ui.input = function(_, cb)
      cb("this block")
    end
    annotate.add(line_of(buf, "+TWO"), line_of(buf, "+six"))
    local notes = annotate.load(sid)
    assert.are.equal("f.txt", notes[1].file)
    assert.are.equal(2, notes[1].line_start)
    assert.are.equal(6, notes[1].line_end)
    -- shown once, under the first row of the range
    local d = vim.diagnostic.get(buf, { namespace = annotate.ns })
    assert.are.equal(1, #d)
    assert.are.equal(line_of(buf, "+TWO") - 1, d[1].lnum)
  end)

  local function panel()
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.bo[b].filetype == "AtlasReviewFiles" then
        return w, b
      end
    end
  end

  it("lists the changed files on the left, with status and +/- counts", function()
    open_review(new_sid())
    local pwin, pbuf = panel()
    assert.is_not_nil(pwin, "expected a file panel")
    assert.are.equal(1, vim.fn.win_screenpos(pwin)[2], "panel is on the left")
    local lines = vim.api.nvim_buf_get_lines(pbuf, 0, -1, false)
    -- f.txt: two -> TWO (1 removed, 1 added) plus "six" added
    assert.are.same({ " M  f.txt  +2 -1", " A  new.txt  +1 -0" }, lines)
  end)

  it("⏎ on a file in the panel jumps the diff to it", function()
    local buf = open_review(new_sid())
    local pwin = panel()
    vim.api.nvim_set_current_win(pwin)
    vim.api.nvim_win_set_cursor(pwin, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)

    assert.are.equal(buf, vim.api.nvim_get_current_buf(), "focus moves to the diff")
    assert.are.equal("▍ new.txt  (new)", vim.api.nvim_get_current_line())
  end)

  it("highlights the file the diff cursor is in", function()
    local buf = open_review(new_sid())
    local _, pbuf = panel()
    local current_ns = vim.api.nvim_create_namespace("atlas_unified_panel_current")
    local function marked_row()
      local marks = vim.api.nvim_buf_get_extmarks(pbuf, current_ns, 0, -1, {})
      return marks[1] and marks[1][2]
    end

    vim.api.nvim_win_set_cursor(0, { line_of(buf, "+TWO"), 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert.are.equal(0, marked_row())

    vim.api.nvim_win_set_cursor(0, { line_of(buf, "+brand new"), 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    assert.are.equal(1, marked_row())
  end)

  it("the panel follows a reload and q from it closes the review", function()
    local buf = open_review(new_sid())
    vim.fn.writefile({ "x" }, wt .. "/third.txt")
    vim.api.nvim_feedkeys("r", "x", false)
    local pwin, pbuf = panel()
    assert.are.equal(3, #vim.api.nvim_buf_get_lines(pbuf, 0, -1, false))

    local tabs = #vim.api.nvim_list_tabpages()
    vim.api.nvim_set_current_win(pwin)
    vim.api.nvim_feedkeys("q", "x", false)
    assert.are.equal(tabs - 1, #vim.api.nvim_list_tabpages())
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)

  it("]c / ]f jump between hunks and files; r reloads; q closes", function()
    local buf = open_review(new_sid())
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys("]c", "x", false)
    assert.truthy(vim.api.nvim_get_current_line():match("^@@"))
    vim.api.nvim_feedkeys("]f", "x", false)
    assert.are.equal("▍ new.txt  (new)", vim.api.nvim_get_current_line())

    vim.fn.writefile({ "another" }, wt .. "/later.txt")
    vim.api.nvim_feedkeys("r", "x", false)
    assert.truthy(line_of(buf, "+another"), "r picks up changes made since opening")

    local tabs = #vim.api.nvim_list_tabpages()
    vim.api.nvim_feedkeys("q", "x", false)
    assert.are.equal(tabs - 1, #vim.api.nvim_list_tabpages())
  end)
end)
