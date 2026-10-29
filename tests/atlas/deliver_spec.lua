local annotate = require("atlas.annotate")
local deliver = require("atlas.deliver")

-- See annotate_spec.lua's comment: must be actually unique, not just
-- os.time()+unseeded math.random() (deterministic across process starts).
local created_sids = {}
local function fresh_session_id()
  local sid = "atlas-test-" .. string.format("%d", vim.loop.hrtime())
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

local function new_pane(name)
  vim.system({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" }):wait()
  return name
end

local function kill_pane(name)
  vim.system({ "tmux", "kill-session", "-t", name }):wait()
end

local function capture(pane)
  local r = vim.system({ "tmux", "capture-pane", "-t", pane, "-p" }, { text = true }):wait()
  return r.stdout or ""
end

describe("atlas.deliver tmux paste (real disposable tmux pane)", function()
  it("lands a multi-line message intact, without executing it line-by-line", function()
    local pane = new_pane("atlas-test-paste-" .. string.format("%d", vim.loop.hrtime()))
    local message = "## repo-a\n- f.lua:1: note one\n\n## repo-b\n- g.lua:2: note two"

    local ok, err = deliver._tmux_paste(pane, message)
    assert.is_true(ok, err)
    vim.wait(300)

    local screen = capture(pane)
    assert.truthy(screen:find("## repo-a", 1, true))
    assert.truthy(screen:find("f.lua:1: note one", 1, true))
    assert.truthy(screen:find("## repo-b", 1, true))
    assert.truthy(screen:find("g.lua:2: note two", 1, true))
    -- Not executed: no shell error from e.g. "- f.lua:1:..." running as a command.
    assert.falsy(screen:find("command not found", 1, true))
    assert.falsy(screen:find("too many arguments", 1, true))

    kill_pane(pane)
  end)
end)

describe("atlas.deliver.send (real tmux pane; claude-status discovery mocked)", function()
  local data = require("atlas.data")
  local real_sessions, real_touched

  before_each(function()
    real_sessions = data.sessions
    real_touched = data.touched
  end)

  after_each(function()
    data.sessions = real_sessions
    data.touched = real_touched
  end)

  it("sends pending notes across every touched worktree as one message and clears them", function()
    local pane = new_pane("atlas-test-send-" .. string.format("%d", vim.loop.hrtime()))
    local sid = fresh_session_id()
    annotate.record(sid, { worktree = "/tmp/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "note a" })
    annotate.record(sid, { worktree = "/tmp/repo-b", file = "g.lua", line_start = 2, line_end = 2, text = "note b" })

    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done" } }, nil)
    end
    data.touched = function(cb)
      cb({ { session_id = sid, paths = { ["/tmp/repo-a"] = 1, ["/tmp/repo-b"] = 2 } } }, nil)
    end

    local sent_ok, done = nil, false
    deliver.send(sid, function(ok)
      sent_ok = ok
      done = true
    end)
    vim.wait(5000, function()
      return done
    end, 20)

    assert.is_true(sent_ok)
    assert.are.equal(0, annotate.pending_for(sid, "/tmp/repo-a"))
    assert.are.equal(0, annotate.pending_for(sid, "/tmp/repo-b"))

    vim.wait(300)
    local screen = capture(pane)
    assert.truthy(screen:find("f.lua:1", 1, true))
    assert.truthy(screen:find("g.lua:2", 1, true))

    kill_pane(pane)
  end)

  it("warns and does nothing when the session has no pending notes", function()
    local pane = new_pane("atlas-test-send-empty-" .. string.format("%d", vim.loop.hrtime()))
    local sid = fresh_session_id()

    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done" } }, nil)
    end
    data.touched = function(cb)
      cb({ { session_id = sid, paths = {} } }, nil)
    end

    local sent_ok, done = nil, false
    deliver.send(sid, function(ok)
      sent_ok = ok
      done = true
    end)
    vim.wait(5000, function()
      return done
    end, 20)

    assert.is_false(sent_ok)
    kill_pane(pane)
  end)
end)
