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
    real.worktrees, real.claude_panes, real.last_conversation = data.worktrees, data.claude_panes, data.last_conversation
    pr_calls = 0
    state = {
      sessions = { { session_id = "s1", state = "done", title = "first session", since = os.time() } },
      touched = { { session_id = "s1", paths = { ["/tmp/atlas-sb/repo-a"] = os.time() } } },
      changed = { ["/tmp/atlas-sb/repo-a"] = true },
      worktrees = {}, -- repo root -> { {path, branch}, ... }
      panes = {}, -- tmux panes running Claude: { {pane, cwd}, ... }
      chats = {}, -- worktree path -> last conversation epoch
    }
    -- Never the real tmux panes or ~/.claude: the developer's own
    -- sessions would show up in the tests.
    data.worktrees = function(root, cb)
      cb(vim.deepcopy(state.worktrees[root] or {}))
    end
    data.claude_panes = function(cb)
      cb(vim.deepcopy(state.panes))
    end
    data.last_conversation = function(path)
      return state.chats[path]
    end
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
    data.worktrees, data.claude_panes, data.last_conversation = real.worktrees, real.claude_panes, real.last_conversation
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

  describe("the repo's other worktrees", function()
    local R = "/tmp/atlas-sb/app"
    local peek = require("atlas.peek")
    local spawn = require("atlas.spawn")
    local real_open_pane, real_open_window

    before_each(function()
      real_open_pane, real_open_window = peek.open_pane, spawn.open_window
      for _, d in ipairs({ "", ".feat", ".old", ".pane/sub", ".touched" }) do
        vim.fn.mkdir(R .. d, "p")
      end
      data.repo_of = function(dir, cb)
        cb(dir:find("^/tmp/atlas%-sb/app") and { root = R, name = "app" } or nil)
      end
      state.sessions = { { session_id = "a", state = "done", title = "main work", cwd = R, tmux_pane = "%1", since = os.time() } }
      state.touched = { { session_id = "a", paths = { [R .. ".touched"] = os.time() } } }
      state.changed = { [R .. ".feat"] = true }
      state.worktrees[R] = {
        { path = R, branch = "main" },
        { path = R .. ".feat", branch = "feat" },
        { path = R .. ".old", branch = "old" },
        { path = R .. ".pane", branch = "pane-branch" },
        { path = R .. ".touched", branch = "touched" },
        { path = R .. ".gone", branch = "gone" }, -- not on disk
      }
      state.panes = {
        { pane = "%1", cwd = R }, -- the recorded session itself
        { pane = "%77", cwd = R .. ".pane/sub" }, -- Claude claude-status doesn't know
      }
      state.chats = { [R .. ".feat"] = os.time() - 2 * 86400 }
    end)

    after_each(function()
      peek.open_pane, spawn.open_window = real_open_pane, real_open_window
    end)

    local function open_and_wait()
      sidebar.toggle()
      assert.is_true(wait_for(function()
        local t = sidebar_text()
        return t and t:find("app.old", 1, true) ~= nil and t:find("changes", 1, true) ~= nil
      end), "expected the repo's other worktrees")
      local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
      vim.api.nvim_set_current_win(win)
      return win, vim.split(sidebar_text(), "\n")
    end

    local function line_of(lines, text)
      for i, l in ipairs(lines) do
        if l:find(text, 1, true) then
          return i
        end
      end
    end

    it("lists untracked Claude panes, then idle worktrees by last conversation, under the repo", function()
      local _, lines = open_and_wait()
      assert.are.equal("▾ app", lines[1])
      assert.truthy(lines[2]:find("main work", 1, true))
      assert.truthy(lines[3]:find("◇ pane-branch  not tracked", 1, true))
      assert.truthy(lines[4]:find("app.feat", 1, true))
      assert.truthy(lines[4]:find("changes", 1, true))
      assert.truthy(lines[4]:find("chat 2d ago", 1, true))
      assert.truthy(lines[5]:find("app.old", 1, true))
      assert.truthy(lines[5]:find("no chat", 1, true))
      -- Covered by the session, the recorded pane, or not on disk.
      assert.is_nil(line_of(lines, "app.touched  "), "a touched worktree isn't idle")
      assert.is_nil(line_of(lines, "app.gone"))
      assert.is_nil(line_of(lines, "◇ main"), "the recorded session's pane isn't listed again")
    end)

    it("⏎ on an untracked pane opens its live view; the legend fits each row", function()
      local opened
      peek.open_pane = function(pane)
        opened = pane
      end
      local win, lines = open_and_wait()
      vim.api.nvim_win_set_cursor(win, { line_of(lines, "not tracked"), 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
      assert.truthy(vim.wo[win].winbar:find("open", 1, true))
      vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
      assert.are.equal("%77", opened)

      vim.api.nvim_win_set_cursor(win, { line_of(lines, "app.old"), 0 })
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(win) })
      assert.truthy(vim.wo[win].winbar:find("start Claude", 1, true))
    end)

    it("c starts Claude in an idle worktree, continuing its last conversation if it had one", function()
      local started = {}
      spawn.open_window = function(path, name, opts)
        started[#started + 1] = { path = path, name = name, command = opts.command }
        return true
      end
      local win, lines = open_and_wait()
      vim.api.nvim_win_set_cursor(win, { line_of(lines, "app.feat"), 0 })
      vim.api.nvim_feedkeys("c", "x", false)
      vim.api.nvim_win_set_cursor(win, { line_of(lines, "app.old"), 0 })
      vim.api.nvim_feedkeys("c", "x", false)
      assert.are.same({
        { path = R .. ".feat", name = "feat", command = "claude --continue" },
        { path = R .. ".old", name = "old", command = "claude" },
      }, started)
    end)

    it("focus_session finds an untracked pane's row by its pane id", function()
      local win, lines = open_and_wait()
      vim.cmd("wincmd l")
      assert.is_true(sidebar.focus_session("%77"))
      assert.are.equal(line_of(lines, "not tracked"), vim.api.nvim_win_get_cursor(win)[1])
    end)
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
    assert.truthy(worktree_bar:find("review", 1, true))
    assert.truthy(worktree_bar:find("split", 1, true))
    assert.truthy(worktree_bar:find("copy", 1, true))
    assert.truthy(worktree_bar:find("o PR", 1, true) or worktree_bar:gsub("%%#[%w_]+#", ""):find("o PR", 1, true))
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

    it("focus_session moves focus and the cursor to that session's row", function()
      local win = open_and_wait("beta work")
      vim.cmd("wincmd l") -- somewhere else, like the session view
      assert.are_not.equal(win, vim.api.nvim_get_current_win())

      assert.is_true(sidebar.focus_session("b"))
      assert.are.equal(win, vim.api.nvim_get_current_win())
      assert.are.equal(line_of("beta work"), vim.api.nvim_win_get_cursor(win)[1])
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

  describe("PR status", function()
    local real_open

    before_each(function()
      real_open = vim.ui.open
    end)
    after_each(function()
      vim.ui.open = real_open
    end)

    local function worktree_line()
      for i, l in ipairs(vim.split(sidebar_text() or "", "\n")) do
        if l:find("repo-a", 1, true) then
          return i, l
        end
      end
    end

    local function with_pr(pr)
      data.pr_status = function(_, cb)
        pr_calls = pr_calls + 1
        cb({ ["/tmp/atlas-sb/repo-a"] = pr })
      end
    end

    local cases = {
      { "merged", { number = 1, state = "MERGED", checks = "passing" }, "\u{f419}", "AtlasPrMerged" },
      { "approved", { number = 2, state = "OPEN", review = "APPROVED", checks = "passing" }, "\u{f42e}", "AtlasPrApproved" },
      { "draft", { number = 3, state = "OPEN", is_draft = true, checks = "none" }, "\u{f4dd}", "AtlasPrDraft" },
      { "in review", { number = 4, state = "OPEN", review = "REVIEW_REQUIRED", checks = "pending" }, "\u{f407}", "AtlasPrReview" },
    }
    for _, c in ipairs(cases) do
      it("shows a " .. c[1] .. " PR as the first thing on the worktree row, coloured", function()
        with_pr(c[2])
        sidebar.toggle()
        assert.is_true(wait_for(function()
          local _, l = worktree_line()
          return l and l:find("#" .. c[2].number, 1, true) ~= nil
        end))
        local i, l = worktree_line()
        assert.are.equal("      " .. c[3] .. " repo-a", l:sub(1, #("      " .. c[3] .. " repo-a")))

        local b = vim.fn.bufnr("atlas://sidebar")
        local ns = vim.api.nvim_create_namespace("atlas_sidebar")
        local found = false
        for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, { i - 1, 0 }, { i - 1, -1 }, { details = true })) do
          if m[3] == 6 and m[4].hl_group == c[4] then
            found = true
          end
        end
        assert.is_true(found, "icon should be highlighted " .. c[4])
        sidebar.toggle()
      end)
    end

    it("keeps names aligned when there's no PR", function()
      with_pr(nil)
      sidebar.toggle()
      assert.is_true(wait_for(function()
        return worktree_line() ~= nil
      end))
      local _, l = worktree_line()
      assert.are.equal("        repo-a", l)
    end)

    it("o opens the worktree's PR in the browser", function()
      with_pr({ number = 9, state = "OPEN", url = "https://github.com/o/r/pull/9", checks = "none" })
      local opened
      vim.ui.open = function(url)
        opened = url
        return nil, nil
      end
      sidebar.toggle()
      assert.is_true(wait_for(function()
        local _, l = worktree_line()
        return l and l:find("#9", 1, true) ~= nil
      end))
      local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { (worktree_line()), 0 })
      vim.api.nvim_feedkeys("o", "x", false)
      assert.are.equal("https://github.com/o/r/pull/9", opened)
    end)

    it("o does nothing but tell you when there's no PR", function()
      with_pr(nil)
      local opened = false
      vim.ui.open = function()
        opened = true
      end
      sidebar.toggle()
      assert.is_true(wait_for(function()
        return worktree_line() ~= nil
      end))
      local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { (worktree_line()), 0 })
      vim.api.nvim_feedkeys("o", "x", false)
      assert.is_false(opened)
    end)
  end)

  it("shows no line numbers, even with LazyVim-style relativenumber/statuscolumn defaults", function()
    vim.o.relativenumber = true
    vim.o.statuscolumn = "%l "
    sidebar.toggle()
    local win = vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
    assert.is_false(vim.wo[win].number)
    assert.is_false(vim.wo[win].relativenumber)
    assert.are.equal("", vim.wo[win].statuscolumn)
    vim.o.relativenumber = false
    vim.o.statuscolumn = ""
  end)

  it("shows the name atlas gave a session it started, before Claude has a title", function()
    local spawn = require("atlas.spawn")
    local names_file = vim.fn.tempname() .. "/names.json"
    spawn._set_names_path(names_file)
    spawn.remember("/tmp/atlas-sb/repo-a", "login-fix-4f9a2c")
    state.sessions = { { session_id = "s1", state = "done", title = "", cwd = "/tmp/atlas-sb/repo-a", since = os.time() } }

    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("login-fix-4f9a2c", 1, true) ~= nil
    end))

    spawn._set_names_path(nil)
    vim.fn.delete(vim.fn.fnamemodify(names_file, ":h"), "rf")
  end)

  it("animates a blue spinner on working sessions, and stops when closed", function()
    state.sessions = {
      { session_id = "w", state = "working", title = "busy one", cwd = "/tmp/atlas-sb/repo-a", since = os.time() },
      { session_id = "d", state = "done", title = "idle one", cwd = "/tmp/atlas-sb/repo-a", since = os.time() },
    }
    state.touched = {}
    sidebar.toggle()
    assert.is_true(wait_for(function()
      local t = sidebar_text()
      return t and t:find("busy one", 1, true) ~= nil
    end))
    local b = vim.fn.bufnr("atlas://sidebar")
    local spin_ns = vim.api.nvim_create_namespace("atlas_sidebar_spinner")
    local function frame()
      local marks = vim.api.nvim_buf_get_extmarks(b, spin_ns, 0, -1, { details = true })
      assert.are.equal(1, #marks, "only the working session spins")
      return marks[1][4].virt_text[1][1], marks[1][4].virt_text[1][2], marks[1][2]
    end

    local first, hl, row = frame()
    local busy_row
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if l:find("busy one", 1, true) then
        busy_row = i - 1
      end
    end
    assert.are.equal(busy_row, row)
    assert.are.equal("AtlasStateWorking", hl)
    assert.are.equal("#3e8fb0", string.format("#%06x", vim.api.nvim_get_hl(0, { name = "AtlasStateWorking" }).fg))

    assert.is_true(vim.wait(1000, function()
      return (frame()) ~= first
    end, 20), "the spinner should advance")

    sidebar.toggle() -- close
    assert.is_false(sidebar._spinning())
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
