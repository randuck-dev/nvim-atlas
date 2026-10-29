local annotate = require("atlas.annotate")
local deliver = require("atlas.deliver")

-- See annotate_spec.lua's comment: must be actually unique, not just
-- os.time()+unseeded math.random() (deterministic across process starts).
local created_sids = {}
local function fresh_session_id()
  local sid = "atlas-test-" .. tostring(vim.loop.hrtime())
  created_sids[#created_sids + 1] = sid
  return sid
end

describe("atlas.deliver.format_for_worktree", function()
  after_each(function()
    for _, sid in ipairs(created_sids) do
      vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
    end
    created_sids = {}
  end)

  it("returns nil when there are no pending notes for that worktree", function()
    assert.is_nil(deliver.format_for_worktree(fresh_session_id(), "/tmp/repo-a"))
  end)

  it("formats a single-line note", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 12, line_end = 12, text = "fix this" })

    local text = deliver.format_for_worktree(sid, "/tmp/repo-a", "repo-a (feature)")
    assert.are.equal("## repo-a (feature)\n- f.lua:12: fix this", text)
  end)

  it("formats a range note distinctly from a single-line one", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 10, line_end = 14, text = "this whole block" })

    local text = deliver.format_for_worktree(sid, "/tmp/repo-a")
    assert.are.equal("## /tmp/repo-a\n- f.lua:10-14: this whole block", text)
  end)

  it("only includes notes for the requested worktree, in order left", function()
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "a1" })
    annotate.record(sid, { worktree = "/tmp/repo-b", file = "g.lua", line_start = 2, line_end = 2, text = "b1" })
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "h.lua", line_start = 3, line_end = 3, text = "a2" })

    local text = deliver.format_for_worktree(sid, "/tmp/repo-a")
    assert.are.equal("## /tmp/repo-a\n- f.lua:1: a1\n- h.lua:3: a2", text)
  end)
end)
