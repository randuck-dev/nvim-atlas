local review = require("atlas.review")
local annotate = require("atlas.annotate")

-- Real git fixture (main + a feature worktree that changed a file) and
-- the real diffview.nvim (pinned in scripts/test.sh).
local root, wt

local function git(dir, args)
  local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  assert(r.code == 0, "git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""))
  return vim.trim(r.stdout or "")
end

local function wait_for(pred)
  return vim.wait(5000, pred, 20)
end

-- The diff window showing the working-tree copy of `rel` (its buffer
-- name is the real file path, unlike the diffview:// base side).
local function working_tree_window(rel)
  local want = vim.fn.resolve(wt .. "/" .. rel)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    if vim.fn.resolve(name) == want then
      return win
    end
  end
end

describe("atlas.review + annotate (real git, real diffview)", function()
  local real_input

  before_each(function()
    real_input = vim.ui.input
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/main", "p")
    git(root .. "/main", { "init", "-q", "-b", "main" })
    git(root .. "/main", { "config", "user.email", "t@example.com" })
    git(root .. "/main", { "config", "user.name", "t" })
    vim.fn.writefile({ "one", "two", "three" }, root .. "/main/f.txt")
    git(root .. "/main", { "add", "." })
    git(root .. "/main", { "commit", "-q", "-m", "init" })
    wt = root .. "/wt"
    git(root .. "/main", { "worktree", "add", "-q", wt, "-b", "feature" })
    vim.fn.writefile({ "one", "TWO", "three" }, wt .. "/f.txt")
    git(wt, { "commit", "-q", "-am", "change line 2" })
  end)

  after_each(function()
    vim.ui.input = real_input
    pcall(vim.cmd, "DiffviewClose")
    vim.cmd("silent! tabonly")
    vim.fn.delete(root, "rf")
  end)

  it("opens the worktree's diff in a new tab carrying its review context", function()
    local tabs_before = #vim.api.nvim_list_tabpages()
    review.open(wt, "sess-1")

    assert.is_true(wait_for(function()
      return review.context() ~= nil
    end), "expected an atlas review tab")
    assert.are.equal(tabs_before + 1, #vim.api.nvim_list_tabpages())

    local ctx = review.context()
    assert.are.equal(wt, ctx.path)
    assert.are.equal("sess-1", ctx.session_id)
    assert.are.equal("main", ctx.target)
  end)

  it("lets you annotate a line in the diff, records it and shows it inline", function()
    local sid = "atlas-review-test-" .. string.format("%d", vim.uv.hrtime())
    review.open(wt, sid)
    assert.is_true(wait_for(function()
      return review.context() ~= nil
    end))

    -- diffview fills its file list asynchronously after opening.
    local view = require("diffview.lib").get_current_view()
    local entry
    assert.is_true(wait_for(function()
      for _, f in view.files:iter() do
        if f.path == "f.txt" then
          entry = f
        end
      end
      return entry ~= nil
    end), "f.txt should be in the diff")
    view:set_file(entry, true)

    local win
    assert.is_true(wait_for(function()
      win = working_tree_window("f.txt")
      return win ~= nil
    end), "expected f.txt's working-tree side to open")
    vim.api.nvim_set_current_win(win)

    vim.ui.input = function(_, cb)
      cb("why uppercase?")
    end
    annotate.add(2, 2)

    local notes = annotate.load(sid)
    assert.are.equal(1, #notes)
    assert.are.equal("f.txt", notes[1].file)
    assert.are.equal(wt, notes[1].worktree)
    assert.are.equal(2, notes[1].line_start)

    local d = vim.diagnostic.get(vim.api.nvim_win_get_buf(win), { namespace = annotate.ns })
    assert.are.equal(1, #d)
    assert.are.equal(1, d[1].lnum) -- line 2
    assert.truthy(d[1].message:find("why uppercase?", 1, true))

    vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
  end)

  it("refuses to annotate outside an atlas review tab", function()
    local called = false
    vim.ui.input = function()
      called = true
    end
    annotate.add(1, 1)
    assert.is_false(called)
  end)
end)
