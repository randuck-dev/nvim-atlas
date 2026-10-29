local annotate = require("atlas.annotate")

-- M.add() is the thin interactive glue (vim.ui.input + resolving the
-- current file from a live diffview buffer) — that needs a real
-- diffview session to mean anything, so it's covered by the same manual
-- end-to-end check as review.lua, not here. This tests the storage path
-- underneath it directly, with real file IO against a disposable
-- session id.

local function fresh_session_id()
  return "atlas-test-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000))
end

describe("atlas.annotate storage", function()
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
end)
