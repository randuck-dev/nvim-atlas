local peek = require("atlas.peek")

local function new_pane(name)
  vim.system({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" }):wait()
  return name
end

local function kill_pane(name)
  vim.system({ "tmux", "kill-session", "-t", name }):wait()
end

describe("atlas.peek._capture (real disposable tmux pane)", function()
  it("returns the pane's current rendered screen, ANSI codes included", function()
    local pane = new_pane("atlas-test-peek-" .. string.format("%d", vim.loop.hrtime()))
    -- A colored echo, so the capture actually has an SGR code to check for.
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, [[printf '\033[31mhello-from-peek-test\033[0m\n']] }):wait()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    vim.wait(500)

    local result, done = nil, false
    peek._capture(pane, function(text)
      result = text
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.truthy(result:find("hello-from-peek-test", 1, true))
    assert.truthy(result:find("\27[31m", 1, true), "expected the raw SGR color code to survive capture -e")

    kill_pane(pane)
  end)

  it("reports failure (nil) for a pane that doesn't exist", function()
    local result, done = "unset", false
    peek._capture("no-such-pane-at-all", function(text)
      result = text
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 20)

    assert.is_nil(result)
  end)
end)

describe("atlas.peek.open (real tmux pane; claude-status discovery mocked)", function()
  local data = require("atlas.data")
  local real_sessions

  before_each(function()
    real_sessions = data.sessions
  end)

  after_each(function()
    data.sessions = real_sessions
    vim.cmd("silent! tabclose")
  end)

  it("takes over the window next to a sidebar-filetype window, not a floating modal", function()
    -- Simulate "the sidebar is open": one window with filetype
    -- AtlasSidebar, one plain window next to it -- the scenario this
    -- feature actually targets.
    vim.cmd("tabnew")
    local sidebar_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sidebar_buf].filetype = "AtlasSidebar"
    vim.api.nvim_win_set_buf(0, sidebar_buf)
    vim.cmd("vsplit")
    local main_win_before = vim.api.nvim_get_current_win()
    local scratch_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(main_win_before, scratch_buf)

    local pane = new_pane("atlas-test-peek-open-" .. string.format("%d", vim.loop.hrtime()))
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo peek-open-marker" }):wait()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    vim.wait(500)

    local sid = "peek-test-session"
    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done", title = "peek test" } }, nil)
    end

    local win_count_before = #vim.api.nvim_tabpage_list_wins(0)
    peek.open(sid)
    vim.wait(2000)

    assert.are.equal(win_count_before, #vim.api.nvim_tabpage_list_wins(0), "should reuse the existing window, not open a new one")

    local new_buf = vim.api.nvim_win_get_buf(main_win_before)
    assert.are_not.equal(scratch_buf, new_buf, "the main window's buffer should have been replaced")
    assert.are.equal("terminal", vim.bo[new_buf].buftype)

    local lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
    local found = false
    for _, l in ipairs(lines) do
      if l:find("peek-open-marker", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "expected the captured pane content in the peek buffer")

    -- q should stop the refresh timer without erroring.
    vim.api.nvim_set_current_win(main_win_before)
    vim.api.nvim_input("q")
    vim.wait(100)

    kill_pane(pane)
  end)

  it("stops the previous session's timer when switching to another session", function()
    vim.cmd("tabnew")
    local sidebar_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sidebar_buf].filetype = "AtlasSidebar"
    vim.api.nvim_win_set_buf(0, sidebar_buf)
    vim.cmd("vsplit")

    local pane_a = new_pane("atlas-test-peek-a-" .. string.format("%d", vim.loop.hrtime()))
    local pane_b = new_pane("atlas-test-peek-b-" .. string.format("%d", vim.loop.hrtime()))

    data.sessions = function(cb)
      cb({
        { session_id = "sess-a", tmux_pane = pane_a, state = "done", title = "A" },
        { session_id = "sess-b", tmux_pane = pane_b, state = "done", title = "B" },
      }, nil)
    end

    peek.open("sess-a")
    vim.wait(1500)
    local timer_a = peek._current_timer()
    assert.is_not_nil(timer_a)
    assert.is_false(timer_a:is_closing())

    peek.open("sess-b")
    vim.wait(1500)
    local timer_b = peek._current_timer()
    assert.is_not_nil(timer_b)
    assert.are_not.equal(timer_a, timer_b, "switching sessions should create a fresh timer")
    assert.is_true(timer_a:is_closing(), "the previous session's timer should have been stopped")
    assert.is_false(timer_b:is_closing())

    kill_pane(pane_a)
    kill_pane(pane_b)
  end)

  it("does not accumulate scrollback across repeated refreshes of unchanged content", function()
    vim.cmd("tabnew")
    local sidebar_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[sidebar_buf].filetype = "AtlasSidebar"
    vim.api.nvim_win_set_buf(0, sidebar_buf)
    vim.cmd("vsplit")

    local pane = new_pane("atlas-test-peek-static-" .. string.format("%d", vim.loop.hrtime()))
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo static-content" }):wait()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    vim.wait(300)

    local sid = "peek-static-session"
    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done" } }, nil)
    end

    peek.open(sid)
    vim.wait(1200) -- past the first refresh tick
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local count_after_first = vim.api.nvim_buf_line_count(buf)

    vim.wait(3000) -- a few more ticks, content on the pane never changes
    local count_after_several = vim.api.nvim_buf_line_count(buf)

    assert.are.equal(
      count_after_first,
      count_after_several,
      "buffer should not grow when the underlying pane content is unchanged"
    )

    kill_pane(pane)
  end)
end)
