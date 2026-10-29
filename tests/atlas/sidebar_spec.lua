local sidebar = require("atlas.sidebar")
local data = require("atlas.data")
local annotate = require("atlas.annotate")

-- The sidebar's three data sources, swapped for fixtures so tests can
-- change what claude-status/gh "report" and count gh calls.
local real = {}
local state
local pr_calls

local function sidebar_text()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].filetype == "AtlasSidebar" then
      return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    end
  end
  return nil
end

local function wait_for(pred)
  return vim.wait(3000, pred, 20)
end

describe("atlas.sidebar", function()
  before_each(function()
    real.sessions, real.touched, real.pr_status = data.sessions, data.touched, data.pr_status
    pr_calls = 0
    state = {
      sessions = { { session_id = "s1", state = "done", title = "first session", since = os.time() } },
      touched = { { session_id = "s1", paths = { ["/tmp/atlas-sb/repo-a"] = os.time() } } },
    }
    data.sessions = function(cb)
      cb(vim.deepcopy(state.sessions), nil)
    end
    data.touched = function(cb)
      cb(vim.deepcopy(state.touched), nil)
    end
    data.pr_status = function(_, cb)
      pr_calls = pr_calls + 1
      cb({ ["/tmp/atlas-sb/repo-a"] = { number = 42, state = "OPEN", checks = "passing" } })
    end
    sidebar.configure({ poll_ms = 100, pr_poll_ms = 60000 })
    vim.cmd("tabnew")
  end)

  after_each(function()
    if sidebar_text() then
      sidebar.toggle() -- close
    end
    data.sessions, data.touched, data.pr_status = real.sessions, real.touched, real.pr_status
    sidebar.configure({ poll_ms = 5000, pr_poll_ms = 30000 })
    vim.cmd("silent! tabclose")
  end)

  it("lists sessions with their touched worktrees and PR/CI status", function()
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("first session", 1, true) ~= nil
    end))
    local text = sidebar_text()
    assert.truthy(text:find("repo-a", 1, true))
    assert.truthy(text:find("#42", 1, true))
  end)

  it("picks up new sessions on its own, without pressing r", function()
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("first session", 1, true) ~= nil
    end))

    table.insert(state.sessions, { session_id = "s2", state = "input", title = "second session", since = os.time() })

    assert.is_true(wait_for(function()
      return sidebar_text():find("second session", 1, true) ~= nil
    end), "a session that appears later should show up via the background poll")
  end)

  it("reuses cached PR/CI status between polls instead of calling gh every time", function()
    sidebar.toggle()
    vim.wait(700) -- several 100ms local polls
    assert.are.equal(1, pr_calls, "gh should only be called once within pr_poll_ms")

    sidebar.refresh(true) -- what `r` does
    assert.is_true(wait_for(function()
      return pr_calls == 2
    end), "a forced refresh should fetch PR/CI status again")
  end)

  it("stops polling when closed", function()
    sidebar.toggle()
    assert.is_true(sidebar._polling())
    sidebar.toggle()
    assert.is_false(sidebar._polling())
    local calls_after_close = pr_calls
    vim.wait(400)
    assert.are.equal(calls_after_close, pr_calls)
  end)

  it("shows a pending-notes badge on a worktree", function()
    local sid = "atlas-sb-test-" .. string.format("%d", vim.uv.hrtime())
    state.sessions = { { session_id = sid, state = "done", title = "notes session", since = os.time() } }
    state.touched = { { session_id = sid, paths = { ["/tmp/atlas-sb/repo-a"] = os.time() } } }
    annotate.record(sid, { worktree = "/tmp/atlas-sb/repo-a", file = "f.lua", line_start = 1, line_end = 1, text = "x" })
    annotate.record(sid, { worktree = "/tmp/atlas-sb/repo-a", file = "f.lua", line_start = 2, line_end = 2, text = "y" })

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("[2 notes]", 1, true) ~= nil
    end))

    vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
  end)
end)
