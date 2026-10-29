local peek = require("atlas.peek")

local function new_pane(name)
  vim.system({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" }):wait()
  return name
end

local function kill_pane(name)
  vim.system({ "tmux", "kill-session", "-t", name }):wait()
end

describe("atlas.peek._capture (real disposable tmux pane)", function()
  it("returns the pane's current rendered screen as clean text", function()
    local pane = new_pane("atlas-test-peek-" .. string.format("%d", vim.loop.hrtime()))
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo hello-from-peek-test" }):wait()
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
  end)

  it("opens a floating window and renders the pane's content into it", function()
    local pane = new_pane("atlas-test-peek-open-" .. string.format("%d", vim.loop.hrtime()))
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo peek-open-marker" }):wait()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    vim.wait(500)

    local sid = "peek-test-session"
    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done", title = "peek test" } }, nil)
    end

    local wins_before = vim.api.nvim_list_wins()
    peek.open(sid)
    vim.wait(2000)

    local wins_after = vim.api.nvim_list_wins()
    assert.is_true(#wins_after > #wins_before, "expected a new floating window to open")

    local new_win
    for _, w in ipairs(wins_after) do
      if not vim.tbl_contains(wins_before, w) then
        new_win = w
      end
    end
    assert.is_not_nil(new_win)

    local new_buf = vim.api.nvim_win_get_buf(new_win)
    local lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
    local found = false
    for _, l in ipairs(lines) do
      if l:find("peek-open-marker", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "expected the captured pane content in the peek buffer")

    vim.api.nvim_win_close(new_win, true)
    kill_pane(pane)
  end)
end)
