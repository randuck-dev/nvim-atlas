local sidebar = require("atlas.sidebar")
local data = require("atlas.data")
local annotate = require("atlas.annotate")

-- The sidebar's three data sources, swapped for fixtures so tests can
-- change what claude-status/gh "report" and count gh calls.
local real = {}
local sections_file
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
    real.sessions, real.touched, real.pr_status, real.changed, real.repo_of = data.sessions, data.touched, data.pr_status, data.changed, data.repo_of
    pr_calls = 0
    state = {
      sessions = { { session_id = "s1", state = "done", title = "first session", since = os.time() } },
      touched = { { session_id = "s1", paths = { ["/tmp/atlas-sb/repo-a"] = os.time() } } },
      changed = { ["/tmp/atlas-sb/repo-a"] = true },
    }
    -- Folders under /work/<repo>[-anything] belong to <repo>.
    data.repo_of = function(dir, cb)
      local name = dir:match("^/work/([%w]+)")
      cb(name and { root = "/work/" .. name, name = name } or nil)
    end
    data.changed = function(paths, cb)
      local set = {}
      for _, p in ipairs(paths) do
        if state.changed[p] then
          set[p] = true
        end
      end
      cb(set)
    end
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
    sidebar._reset()
    sections_file = vim.fn.tempname() .. "/sections.json"
    require("atlas.sections")._set_path(sections_file)
    sidebar.configure({ poll_ms = 100, pr_poll_ms = 60000 })
    -- The sidebar hides worktrees that don't exist on disk.
    vim.fn.mkdir("/tmp/atlas-sb/repo-a", "p")
    vim.cmd("tabnew")
  end)

  after_each(function()
    if sidebar_text() then
      sidebar.toggle() -- close
    end
    data.sessions, data.touched, data.pr_status, data.changed, data.repo_of = real.sessions, real.touched, real.pr_status, real.changed, real.repo_of
    sidebar.configure({ poll_ms = 5000, pr_poll_ms = 30000 })
    vim.cmd("silent! tabclose")
    vim.fn.delete("/tmp/atlas-sb", "rf")
    require("atlas.sections")._set_path(nil)
    vim.fn.delete(vim.fn.fnamemodify(sections_file, ":h"), "rf")
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

  it("shows sessions without waiting for slow PR/CI status, then adds it", function()
    local deliver_prs
    data.pr_status = function(_, cb)
      pr_calls = pr_calls + 1
      deliver_prs = function()
        cb({ ["/tmp/atlas-sb/repo-a"] = { number = 77, state = "OPEN", checks = "pending" } })
      end
    end

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("first session", 1, true) ~= nil
    end), "sessions should render while gh is still running")
    assert.falsy(sidebar_text():find("#77", 1, true))

    deliver_prs() -- gh finally answers
    assert.is_true(wait_for(function()
      return sidebar_text():find("#77", 1, true) ~= nil
    end))
  end)

  it("shows the last known state instantly when reopened", function()
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("first session", 1, true) ~= nil
    end))
    sidebar.toggle() -- close

    -- From now on claude-status never answers; reopening must still show
    -- the previous list immediately, not a blank or loading sidebar.
    data.sessions = function() end
    sidebar.toggle()
    assert.truthy(sidebar_text():find("first session", 1, true))
  end)

  it("only shows worktrees that have changes", function()
    vim.fn.mkdir("/tmp/atlas-sb/repo-quiet", "p")
    state.touched[1].paths["/tmp/atlas-sb/repo-quiet"] = os.time()

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("repo-a", 1, true) ~= nil
    end))
    assert.falsy(sidebar_text():find("repo-quiet", 1, true))

    -- The session starts changing it: it shows up on the next poll.
    state.changed["/tmp/atlas-sb/repo-quiet"] = true
    assert.is_true(wait_for(function()
      return sidebar_text():find("repo-quiet", 1, true) ~= nil
    end))
  end)

  it("still shows an unchanged worktree that has pending notes", function()
    local sid = "atlas-sb-test-" .. string.format("%d", vim.uv.hrtime())
    vim.fn.mkdir("/tmp/atlas-sb/repo-noted", "p")
    state.sessions = { { session_id = sid, state = "done", title = "noted", since = os.time() } }
    state.touched = { { session_id = sid, paths = { ["/tmp/atlas-sb/repo-noted"] = os.time() } } }
    state.changed = {}
    annotate.record(sid, { worktree = "/tmp/atlas-sb/repo-noted", file = "f", line_start = 1, line_end = 1, text = "x" })

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("repo-noted", 1, true) ~= nil
    end))
    vim.fn.delete(vim.fn.stdpath("state") .. "/nvim-atlas/annotations/" .. sid .. ".json")
  end)

  it("groups sessions under the repo that owns their folder", function()
    state.sessions = {
      { session_id = "a", state = "done", title = "alpha work", cwd = "/work/alpha", since = os.time() },
      { session_id = "b", state = "input", title = "alpha other", cwd = "/work/alpha-feature", since = os.time() },
      { session_id = "c", state = "working", title = "beta work", cwd = "/work/beta", since = os.time() },
    }
    state.touched = {}

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("beta work", 1, true) ~= nil
    end))
    local lines = vim.split(sidebar_text(), "\n")
    -- alpha first (one of its sessions needs input), both its sessions
    -- under it, then beta.
    assert.are.same({ "▾ alpha", "▾ beta" }, vim.tbl_filter(function(l)
      return l:match("^▾") ~= nil
    end, lines))
    local text = table.concat(lines, "\n")
    local alpha_at = text:find("▾ alpha", 1, true)
    local beta_at = text:find("▾ beta", 1, true)
    assert.is_true(alpha_at < text:find("alpha other", 1, true))
    assert.is_true(text:find("alpha work", 1, true) < beta_at)
    assert.is_true(beta_at < text:find("beta work", 1, true))
  end)

  it("starts a new worktree in the repo under the cursor with n", function()
    state.sessions = { { session_id = "a", state = "done", title = "alpha work", cwd = "/work/alpha", since = os.time() } }
    state.touched = {}
    local spawn = require("atlas.spawn")
    local real_prompt = spawn.prompt
    local asked_root
    spawn.prompt = function(root, cb)
      asked_root = root
      cb(false)
    end

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("alpha work", 1, true) ~= nil
    end))
    -- Cursor on the session row: `n` uses its repo.
    local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_feedkeys("n", "x", false)
    spawn.prompt = real_prompt

    assert.are.equal("/work/alpha", asked_root)
  end)

  it("shows the keys for the row under the cursor in the top bar", function()
    -- cwd must exist: a session whose folder is gone gets different keys.
    state.sessions = { { session_id = "s1", state = "done", title = "alpha work", cwd = "/tmp/atlas-sb/repo-a", since = os.time() } }
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("repo-a", 1, true) ~= nil
    end))
    local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
    vim.api.nvim_set_current_win(win)

    local function bar_at(line)
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
      return vim.wo[win].winbar
    end

    local repo_bar, session_bar, worktree_bar = bar_at(1), bar_at(2), bar_at(3)
    assert.truthy(repo_bar:find("new worktree", 1, true))
    assert.falsy(repo_bar:find("send", 1, true))
    assert.truthy(session_bar:find("send", 1, true))
    assert.truthy(session_bar:find("clean", 1, true))
    assert.truthy(session_bar:find("move", 1, true))
    assert.truthy(worktree_bar:find("diff", 1, true))
    assert.truthy(worktree_bar:find("copy notes", 1, true))
    for _, bar in ipairs({ repo_bar, session_bar, worktree_bar }) do
      assert.truthy(bar:gsub("%%#[%w_]+#", ""):find("? more", 1, true), "every row should point at ? for the full list")
    end
  end)

  it("? shows and hides the full key list, aligned", function()
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("first session", 1, true) ~= nil
    end))
    assert.falsy(sidebar_text():find("clean up finished worktrees", 1, true))

    local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys("?", "x", false)
    local text = sidebar_text()
    assert.truthy(text:find("clean up finished worktrees", 1, true))
    assert.truthy(text:find("<leader>aa", 1, true))
    assert.truthy(vim.wo[win].winbar:gsub("%%#[%w_]+#", ""):find("? less", 1, true))

    -- Descriptions line up even though "⏎" is several bytes wide.
    local cols = {}
    for _, l in ipairs(vim.split(text, "\n")) do
      local _, desc = l:match("^  (%S+)%s+(.+)$")
      if desc and (desc:find("worktrees", 1, true) or desc:find("live view", 1, true) or desc:find("close sidebar", 1, true)) then
        cols[#cols + 1] = vim.fn.strdisplaywidth(l) - vim.fn.strdisplaywidth(desc)
      end
    end
    assert.are.equal(3, #cols)
    assert.are.equal(cols[1], cols[2])
    assert.are.equal(cols[2], cols[3])

    vim.api.nvim_feedkeys("?", "x", false)
    assert.falsy(sidebar_text():find("clean up finished worktrees", 1, true))
  end)

  it("marks a session whose folder was removed and offers to close it with X", function()
    state.sessions = {
      { session_id = "g", state = "done", title = "orphaned", cwd = "/tmp/atlas-sb/removed-wt", tmux_pane = "%999", since = os.time() },
    }
    state.touched = {}
    local cleanup = require("atlas.cleanup")
    local real_close, real_select = cleanup.close_pane, vim.ui.select
    local closed
    cleanup.close_pane = function(pane)
      closed = pane
      return true
    end
    vim.ui.select = function(choices, _, on_choice)
      on_choice(choices[1])
    end

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("orphaned", 1, true) ~= nil
    end))
    assert.truthy(sidebar_text():find("removed-wt (folder removed)", 1, true))

    local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
    assert.truthy(vim.wo[win].winbar:find("close session", 1, true))

    vim.api.nvim_feedkeys("X", "x", false)
    cleanup.close_pane, vim.ui.select = real_close, real_select
    assert.are.equal("%999", closed)
  end)

  describe("sections", function()
    local sections = require("atlas.sections")
    local real_select, real_input

    before_each(function()
      real_select, real_input = vim.ui.select, vim.ui.input
      vim.fn.mkdir("/tmp/atlas-sb/alpha", "p")
      vim.fn.mkdir("/tmp/atlas-sb/beta", "p")
      data.repo_of = function(dir, cb)
        local name = dir:match("^/tmp/atlas%-sb/(%a+)$")
        cb(name and { root = dir, name = name } or nil)
      end
      state.sessions = {
        { session_id = "a", state = "done", title = "alpha work", cwd = "/tmp/atlas-sb/alpha", tmux_pane = "%1", since = os.time() },
        { session_id = "b", state = "done", title = "beta work", cwd = "/tmp/atlas-sb/beta", tmux_pane = "%2", since = os.time() },
      }
      state.touched = {}
    end)

    after_each(function()
      vim.ui.select, vim.ui.input = real_select, real_input
    end)

    local function open_and_wait(text)
      sidebar.toggle()
      assert.is_true(wait_for(function()
        local t = sidebar_text()
        return t and t:find(text, 1, true) ~= nil
      end))
      local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
      vim.api.nvim_set_current_win(win)
      return win
    end

    local function line_of(text)
      for i, l in ipairs(vim.split(sidebar_text(), "\n")) do
        if l:find(text, 1, true) then
          return i
        end
      end
    end

    it("shows sections first, with their sessions and the repo name, the rest by repo", function()
      sections.assign("a", "to deploy")
      sections.add("observability")
      open_and_wait("beta work")

      local lines = vim.split(sidebar_text(), "\n")
      assert.are.equal("▾ to deploy", lines[1])
      assert.truthy(lines[2]:find("alpha work", 1, true))
      assert.truthy(lines[2]:find("alpha", #"  ◆ alpha work", true), "repo name shown under a section")
      assert.are.equal("▾ observability", lines[3])
      assert.truthy(lines[4]:find("(empty", 1, true))
      assert.are.equal("▾ beta", lines[5])
      assert.truthy(lines[6]:find("beta work", 1, true))
      assert.is_nil(line_of("▾ alpha"), "a session in a section isn't also listed under its repo")
    end)

    it("m moves a session into a chosen section", function()
      sections.add("observability")
      local win = open_and_wait("beta work")
      vim.ui.select = function(choices, _, on_choice)
        assert.truthy(vim.tbl_contains(choices, "observability"))
        assert.truthy(vim.tbl_contains(choices, "+ new section…"))
        on_choice("observability")
      end
      vim.api.nvim_win_set_cursor(win, { line_of("beta work"), 0 })
      vim.api.nvim_feedkeys("m", "x", false)

      assert.are.equal("observability", sections.section_of("b"))
      assert.is_true(line_of("▾ observability") < line_of("beta work"))
      assert.is_nil(line_of("▾ beta"))
    end)

    it("m can make a new section on the spot", function()
      local win = open_and_wait("alpha work")
      vim.ui.select = function(_, _, on_choice)
        on_choice("+ new section…")
      end
      vim.ui.input = function(_, cb)
        cb("to deploy")
      end
      vim.api.nvim_win_set_cursor(win, { line_of("alpha work"), 0 })
      vim.api.nvim_feedkeys("m", "x", false)

      assert.are.equal("to deploy", sections.section_of("a"))
      assert.are.equal(1, line_of("▾ to deploy"))
    end)

    it("m can take a session back out of its section", function()
      sections.assign("a", "to deploy")
      local win = open_and_wait("alpha work")
      vim.ui.select = function(choices, _, on_choice)
        on_choice(choices[#choices]) -- "remove from to deploy"
      end
      vim.api.nvim_win_set_cursor(win, { line_of("alpha work"), 0 })
      vim.api.nvim_feedkeys("m", "x", false)

      assert.is_nil(sections.section_of("a"))
      assert.is_true(line_of("▾ alpha") < line_of("alpha work"))
    end)

    it("S makes an empty section; d deletes one and its sessions go back to their repo", function()
      local win = open_and_wait("alpha work")
      vim.ui.input = function(_, cb)
        cb("observability")
      end
      vim.api.nvim_feedkeys("S", "x", false)
      assert.truthy(line_of("▾ observability"))

      sections.assign("a", "observability")
      sidebar.redraw()
      vim.ui.select = function(_, _, on_choice)
        on_choice("Delete section")
      end
      vim.api.nvim_win_set_cursor(win, { line_of("▾ observability"), 0 })
      vim.api.nvim_feedkeys("d", "x", false)

      assert.is_nil(line_of("▾ observability"))
      assert.is_true(line_of("▾ alpha") < line_of("alpha work"))
    end)

    local function press(win, line, keys)
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    it("← collapses a section, → and ⏎ open it again", function()
      sections.assign("a", "to deploy")
      local win = open_and_wait("alpha work")

      press(win, line_of("▾ to deploy"), "<Left>")
      assert.truthy(line_of("▸ to deploy  (1)"))
      assert.is_nil(line_of("alpha work"), "a collapsed section hides its sessions")
      assert.truthy(line_of("beta work"), "other groups are unaffected")
      assert.is_true(sections.is_collapsed("section:to deploy"), "remembered across restarts")

      press(win, line_of("▸ to deploy"), "<Right>")
      assert.truthy(line_of("▾ to deploy"))
      assert.truthy(line_of("alpha work"))

      press(win, line_of("▾ to deploy"), "<Left>")
      press(win, line_of("▸ to deploy"), "<CR>")
      assert.truthy(line_of("alpha work"))
    end)

    it("← on a session inside a section collapses it and jumps to its header", function()
      sections.assign("a", "to deploy")
      local win = open_and_wait("alpha work")

      press(win, line_of("alpha work"), "<Left>")
      assert.truthy(line_of("▸ to deploy"))
      assert.are.equal(line_of("▸ to deploy"), vim.api.nvim_win_get_cursor(win)[1])
    end)

    it("a collapsed group still shows that something is waiting on you", function()
      state.sessions[1].state = "input"
      sections.assign("a", "to deploy")
      local win = open_and_wait("alpha work")

      press(win, line_of("▾ to deploy"), "<Left>")
      assert.truthy(line_of("▸ to deploy  (1)  ●"))
    end)

    it("repo groups fold too, and h/l work like ←/→", function()
      local win = open_and_wait("beta work")

      press(win, line_of("▾ beta"), "h")
      assert.truthy(line_of("▸ beta  (1)"))
      assert.is_nil(line_of("beta work"))

      press(win, line_of("▸ beta"), "l")
      assert.truthy(line_of("beta work"))
    end)

    it("R renames a section", function()
      sections.assign("a", "obs")
      local win = open_and_wait("alpha work")
      vim.ui.input = function(_, cb)
        cb("observability")
      end
      vim.api.nvim_win_set_cursor(win, { line_of("▾ obs"), 0 })
      vim.api.nvim_feedkeys("R", "x", false)

      assert.truthy(line_of("▾ observability"))
      assert.are.equal("observability", sections.section_of("a"))
    end)
  end)

  it("hides worktrees that no longer exist on disk", function()
    state.touched[1].paths["/tmp/atlas-sb/gone"] = os.time()
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("repo-a", 1, true) ~= nil
    end))
    assert.falsy(sidebar_text():find("gone", 1, true))
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
