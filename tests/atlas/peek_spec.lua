local peek = require("atlas.peek")

local function new_pane(name)
  vim.system({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" }):wait()
  return name
end

local function kill_pane(name)
  vim.system({ "tmux", "kill-session", "-t", name }):wait()
end

local function capture(pane)
  local r = vim.system({ "tmux", "capture-pane", "-p", "-t", pane }, { text = true }):wait()
  return r.stdout or ""
end

local function open_sidebar_and_main_window()
  vim.cmd("tabnew")
  local sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].filetype = "AtlasSidebar"
  vim.api.nvim_win_set_buf(0, sidebar_buf)
  vim.cmd("vsplit")
  local main_win = vim.api.nvim_get_current_win()
  -- :vsplit duplicates the current buffer into the new window, so
  -- without this it'd show the sidebar buffer too -- find_main_window()
  -- would then (correctly) find no non-sidebar window at all.
  vim.api.nvim_win_set_buf(main_win, vim.api.nvim_create_buf(false, true))
  return main_win
end

describe("atlas.peek._capture (real disposable tmux pane)", function()
  it("returns the pane's current rendered screen, ANSI codes included", function()
    local pane = new_pane("atlas-test-peek-" .. string.format("%d", vim.loop.hrtime()))
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

  it("reports the real pane's cursor position", function()
    local pane = new_pane("atlas-test-peek-cursor-" .. string.format("%d", vim.loop.hrtime()))
    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo hi" }):wait()
    vim.wait(300)

    local x, y, done = nil, nil, false
    peek._cursor_pos(pane, function(cx, cy)
      x, y = cx, cy
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.is_true(y >= 0, "cursor row should be a valid non-negative position")
    assert.is_true(x > 0, "cursor column should have advanced past the typed text")

    kill_pane(pane)
  end)

  it("reports failure (nil, nil) for a pane that doesn't exist", function()
    local x, y, done = "unset", "unset", false
    peek._cursor_pos("no-such-pane-at-all", function(cx, cy)
      x, y = cx, cy
      done = true
    end)
    vim.wait(3000, function()
      return done
    end, 20)

    assert.is_true(done)
    assert.is_nil(x)
    assert.is_nil(y)
  end)
end)

describe("atlas.peek._cup", function()
  it("converts tmux's 0-indexed cursor_x/cursor_y to a 1-indexed CUP sequence", function()
    assert.are.equal("\27[1;1H", peek._cup(0, 0))
    assert.are.equal("\27[5;33H", peek._cup(32, 4))
  end)
end)

describe("atlas.peek._capture error handling", function()
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

  it("takes over the window next to a sidebar-filetype window, seeded with the pane's current content", function()
    local main_win_before = open_sidebar_and_main_window()
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
    vim.wait(1500)

    assert.are.equal(win_count_before, #vim.api.nvim_tabpage_list_wins(0), "should reuse the existing window, not open a new one")

    local new_buf = vim.api.nvim_win_get_buf(main_win_before)
    assert.are_not.equal(scratch_buf, new_buf)
    assert.are.equal("terminal", vim.bo[new_buf].buftype)

    local lines = vim.api.nvim_buf_get_lines(new_buf, 0, -1, false)
    local found = false
    for _, l in ipairs(lines) do
      if l:find("peek-open-marker", 1, true) then
        found = true
      end
    end
    assert.is_true(found, "expected the seeded pane content in the peek buffer")

    kill_pane(pane)
  end)

  -- Whether reseed() actually lands the *visible* cursor at the right
  -- spot isn't covered by an automated test: nvim_win_get_cursor simply
  -- doesn't track a terminal buffer's cursor position in --headless mode
  -- at all -- confirmed directly, and not specific to this code: even a
  -- plain real `:terminal` job running `printf` showed the exact same
  -- stuck-at-{1,0} behavior with multi-line output in the buffer.
  -- That's a no-UI-attached limitation of headless Neovim, not something
  -- a different assertion could work around. What's covered instead:
  -- _cup()'s 0-indexed-to-1-indexed math (pure, tested directly above),
  -- and that reseed()'s full capture+cursor-position chain runs without
  -- erroring (the "takes over the window..." test above exercises this
  -- same path end to end). The actual visual placement needs confirming
  -- in a real interactive session, not headless -- that's the only
  -- environment where this is observable at all.

  it("streams new output live: text sent to the pane after opening shows up without re-opening", function()
    local main_win = open_sidebar_and_main_window()
    local pane = new_pane("atlas-test-peek-live-" .. string.format("%d", vim.loop.hrtime()))

    local sid = "peek-live-session"
    data.sessions = function(cb)
      cb({ { session_id = sid, tmux_pane = pane, state = "done" } }, nil)
    end

    peek.open(sid)
    vim.wait(1000) -- past the initial seed + pipe-pane startup

    -- Nothing sent yet, so the marker shouldn't be there.
    local buf = vim.api.nvim_win_get_buf(main_win)
    local before = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.falsy(before:find("live-relay-marker", 1, true))

    vim.system({ "tmux", "send-keys", "-l", "-t", pane, "echo live-relay-marker" }):wait()
    vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }):wait()
    vim.wait(1500) -- give the fifo relay time to deliver it

    local after = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    assert.truthy(after:find("live-relay-marker", 1, true), "expected output sent after opening to stream in live")

    kill_pane(pane)
  end)

  -- The "forwards typed input" path (on_input -> `tmux send-keys -l`)
  -- isn't covered by an automated test: nvim_open_term's on_input only
  -- fires on genuine terminal-mode keystroke dispatch, and that doesn't
  -- reliably trigger when simulated via nvim_feedkeys(..., 't', false)
  -- inside plenary's coroutine-based test runner (tried both
  -- vim.wait() and a real vim.cmd("sleep ...") drain; same result
  -- either way). Verified directly instead with a standalone headless
  -- script (plain `-S script.lua`, not through plenary): typing
  -- "echo typed-input-marker<CR>" into the peek buffer made the real
  -- disposable tmux pane actually execute it and print the marker. The
  -- mechanism itself is the same `tmux send-keys` primitive
  -- deliver_spec.lua already exercises thoroughly against real panes,
  -- just invoked per-keystroke instead of as one batched paste.

  it("tears down the previous session's reader job and tmux pipe-pane when switching sessions", function()
    open_sidebar_and_main_window()
    local pane_a = new_pane("atlas-test-peek-switch-a-" .. string.format("%d", vim.loop.hrtime()))
    local pane_b = new_pane("atlas-test-peek-switch-b-" .. string.format("%d", vim.loop.hrtime()))

    data.sessions = function(cb)
      cb({
        { session_id = "sw-a", tmux_pane = pane_a, state = "done" },
        { session_id = "sw-b", tmux_pane = pane_b, state = "done" },
      }, nil)
    end

    peek.open("sw-a")
    vim.wait(1000)
    local reader_a = peek._current_reader()
    assert.is_not_nil(reader_a)

    peek.open("sw-b")
    vim.wait(1000)
    local reader_b = peek._current_reader()
    assert.is_not_nil(reader_b)
    assert.are_not.equal(reader_a, reader_b)

    -- pane_a's pipe-pane should be off now (tmux's own per-pane flag).
    local r = vim.system({ "tmux", "display-message", "-p", "-t", pane_a, "#{pane_pipe}" }, { text = true }):wait()
    assert.are.equal("0", vim.trim(r.stdout or ""), "pane A's pipe-pane should have been turned off")

    kill_pane(pane_a)
    kill_pane(pane_b)
  end)
end)
