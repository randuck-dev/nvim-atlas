local annotate = require("atlas.annotate")

-- M.add() is the thin interactive glue (vim.ui.input + resolving the
-- current file from a live diffview buffer) — that needs a real
-- diffview session to mean anything, so it's covered by the same manual
-- end-to-end check as review.lua, not here. This tests the storage path
-- underneath it directly, with real file IO against a disposable
-- session id.

-- vim.loop.hrtime() is a monotonic nanosecond clock: unlike
-- os.time()+math.random() (unseeded, so deterministic across process
-- starts — this bit us once already, colliding both within a run and
-- across repeated runs), this is actually unique per call.
local created_sids = {}
local function fresh_session_id()
  local sid = "atlas-test-" .. string.format("%d", vim.loop.hrtime())
  created_sids[#created_sids + 1] = sid
  return sid
end

describe("atlas.annotate storage", function()
  after_each(function()
    for _, sid in ipairs(created_sids) do
      vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
    end
    created_sids = {}
  end)

  it("starts empty for an unseen session", function()
    assert.are.same({}, annotate.load(fresh_session_id()))
  end)

  it("records and reloads an annotation", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 12, line_end = 12, text = "fix this" })

    local list = annotate.load(sid)
    assert.are.equal(1, #list)
    assert.are.equal("/tmp/repo-a", list[1].worktree)
    assert.are.equal("f.lua", list[1].file)
    assert.are.equal(12, list[1].line_start)
    assert.are.equal(12, list[1].line_end)
    assert.are.equal("fix this", list[1].text)
    assert.is_number(list[1].created)
  end)

  it("records and reloads a multi-line range annotation", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 10, line_end = 14, text = "this whole block" })

    local list = annotate.load(sid)
    assert.are.equal(10, list[1].line_start)
    assert.are.equal(14, list[1].line_end)
  end)

  it("counts pending annotations per worktree", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "a" })
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "g.lua", line_start = 2, line_end = 2, text = "b" })
    annotate.record(sid, { worktree = "/tmp/repo-b", file = "h.lua", line_start = 3, line_end = 3, text = "c" })

    assert.are.equal(2, annotate.pending_for(sid, "/tmp/repo-a"))
    assert.are.equal(1, annotate.pending_for(sid, "/tmp/repo-b"))
    assert.are.equal(0, annotate.pending_for(sid, "/tmp/repo-c"))
  end)

  it("clears only the annotations for the given worktree", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "a" })
    annotate.record(sid, { worktree = "/tmp/repo-b", file = "h.lua", line_start = 3, line_end = 3, text = "c" })

    annotate.clear_for(sid, "/tmp/repo-a")

    assert.are.equal(0, annotate.pending_for(sid, "/tmp/repo-a"))
    assert.are.equal(1, annotate.pending_for(sid, "/tmp/repo-b"))
  end)

  local function notes_in(buf)
    return vim.diagnostic.get(buf, { namespace = annotate.ns })
  end

  it("shows a note as a diagnostic below its line", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 3, line_end = 3, text = "hello" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })

    annotate.render_inline(buf, sid, "/tmp/repo-a", "f.lua")

    local d = notes_in(buf)
    assert.are.equal(1, #d)
    assert.are.equal(2, d[1].lnum) -- line 3, 0-indexed
    assert.are.equal(vim.diagnostic.severity.HINT, d[1].severity)
    assert.are.equal("note: hello", d[1].message)
    -- Displayed as a virtual line under it, for this namespace only.
    local cfg = vim.diagnostic.config(nil, annotate.ns)
    assert.truthy(cfg.virtual_lines)
    assert.falsy(cfg.virtual_text)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("shows a multi-line note once, spanning its lines", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 2, line_end = 4, text = "block note" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })

    annotate.render_inline(buf, sid, "/tmp/repo-a", "f.lua")

    local d = notes_in(buf)
    assert.are.equal(1, #d)
    assert.are.equal(1, d[1].lnum)
    assert.are.equal(3, d[1].end_lnum)

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("clears previous notes before showing (no stale notes from an earlier call)", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "first" })

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two" })
    annotate.render_inline(buf, sid, "/tmp/repo-a", "f.lua")

    -- notes cleared (e.g. after a send) then re-rendered: should show nothing now
    annotate.clear_for(sid, "/tmp/repo-a")
    annotate.render_inline(buf, sid, "/tmp/repo-a", "f.lua")

    assert.are.equal(0, #notes_in(buf))

    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("doesn't change how other (e.g. LSP) diagnostics are displayed", function()
    local before = vim.deepcopy(vim.diagnostic.config())
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one" })
    annotate.show(buf, { { 0, 0, "x" } })
    assert.are.same(before, vim.diagnostic.config())
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
