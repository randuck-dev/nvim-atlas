local peek = require("atlas.peek")
local data = require("atlas.data")

local function sh(args)
  local r = vim.system(args, { text = true }):wait()
  return r.code == 0, vim.trim(r.stdout or "")
end

-- A disposable tmux session; returns its name and its first pane id.
-- The pane id is asserted to be a real "%N" id: an empty target makes
-- tmux fall back to the *current* pane, which once sent this test's
-- keystrokes into the developer's own session.
local function new_session()
  local name = "atlas-test-peek-" .. string.format("%d", vim.uv.hrtime())
  sh({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" })
  local _, pane = sh({ "tmux", "list-panes", "-t", "=" .. name .. ":", "-F", "#{pane_id}" })
  assert(pane:match("^%%%d+$"), "could not resolve pane id for test session " .. name .. ": '" .. pane .. "'")
  return name, pane
end

local function kill_session(name)
  sh({ "tmux", "kill-session", "-t", "=" .. name .. ":" })
end

local function session_exists(name)
  return (sh({ "tmux", "has-session", "-t", "=" .. name .. ":" }))
end

local function pane_text(pane)
  local _, out = sh({ "tmux", "capture-pane", "-p", "-t", pane })
  return out
end

local function buf_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Sidebar window + a separate main window, like real usage.
local function open_sidebar_and_main_window()
  vim.cmd("tabnew")
  local sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[sidebar_buf].filetype = "AtlasSidebar"
  vim.api.nvim_win_set_buf(0, sidebar_buf)
  vim.cmd("vsplit")
  local main_win = vim.api.nvim_get_current_win()
  -- :vsplit shows the same (sidebar) buffer in the new window too.
  vim.api.nvim_win_set_buf(main_win, vim.api.nvim_create_buf(false, true))
  return main_win
end

local function mock_sessions(list)
  data.sessions = function(cb)
    cb(list, nil)
  end
end

describe("atlas.peek (real tmux client on a grouped view session)", function()
  local real_sessions
  local to_kill

  before_each(function()
    real_sessions = data.sessions
    to_kill = {}
  end)

  after_each(function()
    peek.close()
    data.sessions = real_sessions
    for _, s in ipairs(to_kill) do
      kill_session(s)
    end
    vim.cmd("silent! tabclose")
  end)

  it("takes over the window next to the sidebar and shows the pane's content", function()
    local main_win = open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    sh({ "tmux", "send-keys", "-t", pane, "echo peek-open-marker", "Enter" })
    vim.wait(300)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    local wins_before = #vim.api.nvim_tabpage_list_wins(0)
    peek.open("s1")

    local buf = vim.api.nvim_win_get_buf(main_win)
    assert.are.equal(wins_before, #vim.api.nvim_tabpage_list_wins(0), "should reuse the main window")
    assert.are.equal("terminal", vim.bo[buf].buftype)
    assert.is_true(vim.wait(3000, function()
      return buf_text(buf):find("peek-open-marker", 1, true) ~= nil
    end, 50), "expected the pane's existing content in the view")
  end)

  it("shows new output live", function()
    local main_win = open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local buf = vim.api.nvim_win_get_buf(main_win)
    vim.wait(800)
    sh({ "tmux", "send-keys", "-t", pane, "echo live-marker", "Enter" })

    assert.is_true(vim.wait(3000, function()
      return buf_text(buf):find("live-marker", 1, true) ~= nil
    end, 50), "expected output written after opening to appear")
  end)

  it("sends what's typed in the view to the real pane", function()
    local main_win = open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local buf = vim.api.nvim_win_get_buf(main_win)
    vim.wait(800)
    -- Writing to the terminal job's channel is exactly what keystrokes
    -- in terminal mode do.
    vim.api.nvim_chan_send(vim.bo[buf].channel, "echo typed-marker\r")

    assert.is_true(vim.wait(3000, function()
      return pane_text(pane):find("typed%-marker\n") ~= nil or pane_text(pane):find("typed-marker", 1, true) ~= nil
    end, 50), "expected typed input to reach the real pane")
  end)

  it("turns the status bar off for the view only, not the real session", function()
    open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local view = peek._current_view()
    assert.is_not_nil(view)

    local ok, view_status = sh({ "tmux", "show-options", "-v", "-t", "=" .. view .. ":", "status" })
    assert.is_true(ok)
    assert.are.equal("off", view_status)
    -- The real session gets no session-level override at all: `show-options`
    -- without -g lists only the session's own settings.
    local ok2, real_opts = sh({ "tmux", "show-options", "-t", "=" .. name .. ":" })
    assert.is_true(ok2)
    assert.is_nil(real_opts:match("^status ") or real_opts:match("\nstatus "))
  end)

  it("removes the previous view session when switching sessions", function()
    open_sidebar_and_main_window()
    local a, pane_a = new_session()
    local b, pane_b = new_session()
    table.insert(to_kill, a)
    table.insert(to_kill, b)
    mock_sessions({
      { session_id = "a", tmux_pane = pane_a, state = "done" },
      { session_id = "b", tmux_pane = pane_b, state = "done" },
    })

    peek.open("a")
    local view_a = peek._current_view()
    assert.is_true(session_exists(view_a))

    peek.open("b")
    local view_b = peek._current_view()
    assert.are_not.equal(view_a, view_b)
    assert.is_false(session_exists(view_a), "the old view session should be gone")
    assert.is_true(session_exists(view_b))
    assert.is_true(session_exists(a), "the real session must survive")
  end)

  it("removes the view session on close, leaving the real session alone", function()
    open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local view = peek._current_view()
    peek.close()

    assert.is_false(session_exists(view))
    assert.is_true(session_exists(name))
    assert.is_nil(peek._current_view())
  end)

  it("removes the view session when the tmux client exits on its own", function()
    local main_win = open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local view = peek._current_view()
    vim.wait(500)
    vim.fn.jobstop(vim.bo[vim.api.nvim_win_get_buf(main_win)].channel)

    assert.is_true(vim.wait(3000, function()
      return not session_exists(view)
    end, 50), "the view session should be removed when its client exits")
    assert.is_true(session_exists(name))
  end)

  it("renders a full-screen TUI exactly as tmux has it", function()
    -- The earlier snapshot-based version garbled TUIs that redraw parts
    -- of the screen. A real client shouldn't: compare the view with
    -- tmux's own capture of the pane while Vim (cursor moves, partial
    -- redraws, a status line) runs in it.
    local main_win = open_sidebar_and_main_window()
    local name, pane = new_session()
    table.insert(to_kill, name)
    local file = vim.fn.tempname()
    local content = {}
    for i = 1, 60 do
      content[i] = string.format("line %02d of a file being edited in a TUI", i)
    end
    vim.fn.writefile(content, file)
    sh({ "tmux", "send-keys", "-t", pane, "vim -u NONE -N " .. file, "Enter" })
    vim.wait(800)
    mock_sessions({ { session_id = "s1", tmux_pane = pane, state = "done" } })

    peek.open("s1")
    local buf = vim.api.nvim_win_get_buf(main_win)
    vim.wait(800)
    -- Partial redraws: scroll, jump, search.
    for _, keys in ipairs({ "20j", "gg", "G", "/line 33", "Enter" }) do
      if keys == "Enter" then
        sh({ "tmux", "send-keys", "-t", pane, "Enter" })
      else
        sh({ "tmux", "send-keys", "-t", pane, keys })
      end
      vim.wait(150)
    end

    local function view_lines()
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = l:gsub("%s+$", "")
      end
      return out
    end
    local function pane_lines()
      local _, out = sh({ "tmux", "capture-pane", "-p", "-t", pane })
      local res = {}
      for l in (out .. "\n"):gmatch("(.-)\n") do
        res[#res + 1] = l:gsub("%s+$", "")
      end
      return res
    end

    local matched = vim.wait(3000, function()
      local v, p = view_lines(), pane_lines()
      for i = 1, #p do
        if v[i] ~= p[i] then
          return false
        end
      end
      return #p > 0
    end, 100)
    if not matched then
      local v, p = view_lines(), pane_lines()
      for i = 1, #p do
        if v[i] ~= p[i] then
          error(string.format("row %d differs:\n view: %q\n pane: %q", i, tostring(v[i]), p[i]))
        end
      end
    end
    assert.truthy(table.concat(view_lines(), "\n"):find("line 33", 1, true))

    sh({ "tmux", "send-keys", "-t", pane, "Escape", ":qa!", "Enter" })
    vim.fn.delete(file)
  end)

  it("refuses a pane value that isn't a tmux pane id", function()
    open_sidebar_and_main_window()
    mock_sessions({ { session_id = "s1", tmux_pane = "not-a-pane", state = "done" } })
    peek.open("s1")
    assert.is_nil(peek._current_view())
  end)

  it("warns and does nothing for a session without a tmux pane", function()
    open_sidebar_and_main_window()
    mock_sessions({ { session_id = "s1", tmux_pane = "", state = "done" } })
    peek.open("s1")
    assert.is_nil(peek._current_view())
  end)
end)
