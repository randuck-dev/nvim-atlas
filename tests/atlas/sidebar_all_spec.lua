-- The sidebar's "All sessions" tree, on a fake ~/.claude/projects.
local sidebar = require("atlas.sidebar")
local data = require("atlas.data")
local history = require("atlas.history")
local sections = require("atlas.sections")
local peek = require("atlas.peek")
local spawn = require("atlas.spawn")

local real = {}
local state
local base, projects, app, lib

local function encode(path)
  return (path:gsub("[^%w-]", "-"))
end

local function chat(cwd, id, age, title)
  local file = projects .. "/" .. encode(cwd) .. "/" .. id .. ".jsonl"
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local lines = { vim.json.encode({ type = "user", cwd = cwd }) }
  if title then
    lines[#lines + 1] = vim.json.encode({ type = "ai-title", aiTitle = title })
  end
  vim.fn.writefile(lines, file)
  local t = os.time() - age
  vim.uv.fs_utime(file, t, t)
end

local function sidebar_lines()
  local b = vim.fn.bufnr("atlas://sidebar")
  return b ~= -1 and vim.api.nvim_buf_get_lines(b, 0, -1, false) or {}
end

local function line_of(text)
  for i, l in ipairs(sidebar_lines()) do
    if l:find(text, 1, true) then
      return i
    end
  end
end

local function wait_for(text)
  assert.is_true(
    vim.wait(3000, function()
      return line_of(text) ~= nil
    end, 20),
    "expected '" .. text .. "' in:\n" .. table.concat(sidebar_lines(), "\n")
  )
  return line_of(text)
end

local function win()
  return vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar"))
end

local function press(line, keys)
  vim.api.nvim_set_current_win(win())
  vim.api.nvim_win_set_cursor(win(), { line, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("atlas.sidebar All sessions", function()
  before_each(function()
    for _, k in ipairs({ "sessions", "touched", "pr_status", "changed", "repo_of", "worktrees", "claude_panes", "last_conversation" }) do
      real[k] = data[k]
    end
    real.scan_async, real.open_pane, real.open, real.open_window = history.scan_async, peek.open_pane, peek.open, spawn.open_window
    state = { sessions = {}, panes = {} }
    data.sessions = function(cb)
      cb(vim.deepcopy(state.sessions), nil)
    end
    data.touched = function(cb)
      cb({}, nil)
    end
    data.pr_status = function(_, cb)
      cb({})
    end
    data.changed = function(_, cb)
      cb({})
    end
    data.repo_of = function(_, cb)
      cb(nil)
    end
    data.worktrees = function(_, cb)
      cb({})
    end
    data.claude_panes = function(cb)
      cb(vim.deepcopy(state.panes))
    end
    data.last_conversation = function()
      return nil
    end

    base = vim.fn.resolve(vim.fn.tempname())
    projects = base .. "/projects"
    app, lib = base .. "/w/app", base .. "/w/lib"
    vim.fn.mkdir(app .. "/.git", "p")
    vim.fn.mkdir(lib .. "/.git", "p")
    vim.fn.mkdir(app .. ".feat", "p")
    vim.fn.writefile({ "gitdir: " .. app .. "/.git/worktrees/feat" }, app .. ".feat/.git")
    chat(app, "a-old", 3 * 86400, "Old work")
    chat(app .. ".feat", "f-1", 3600, "Feature work")
    chat(lib, "l-1", 60, "Lib work")

    history._reset(base .. "/history-dirs.json")
    sidebar._reset()
    sections._set_path(base .. "/sections.json")
    sidebar.configure({ poll_ms = 100, pr_poll_ms = 60000, projects_dir = projects, history_skip = {} })
    vim.cmd("tabnew")
  end)

  after_each(function()
    if vim.fn.bufwinid(vim.fn.bufnr("atlas://sidebar")) ~= -1 then
      sidebar.toggle()
    end
    for k, f in pairs(real) do
      if data[k] then
        data[k] = f
      end
    end
    history.scan_async, peek.open_pane, peek.open, spawn.open_window = real.scan_async, real.open_pane, real.open, real.open_window
    sidebar.configure({ poll_ms = 5000, pr_poll_ms = 30000, projects_dir = false, history_skip = false })
    sections._set_path(nil)
    history._reset(nil)
    vim.cmd("silent! tabclose")
    vim.fn.delete(base, "rf")
  end)

  it("starts collapsed at the bottom and doesn't scan until opened", function()
    local scans = 0
    history.scan_async = function(...)
      scans = scans + 1
      return real.scan_async(...)
    end
    sidebar.toggle()
    local l = wait_for("▸ All sessions")
    assert.are.equal(#sidebar_lines(), l)
    vim.wait(300)
    assert.are.equal(0, scans)

    press(l, "<Right>")
    wait_for("▾ All sessions  (2 repos)")
    assert.are.equal(1, scans)
    assert.is_true(sections.is_expanded("all"), "remembered across restarts")
    -- Most recently active repo first, folded.
    assert.truthy(line_of("▸ lib  1 chat · 1m ago"))
    assert.truthy(line_of("▸ app  2 worktrees · 2 chats · 1h ago"))
    assert.is_true(line_of("lib") < line_of("▸ app"))
  end)

  it("unfolds repo → worktrees → conversations; ← folds back up a level at a time", function()
    sections.set_expanded("all", true)
    sidebar.toggle()
    press(wait_for("▸ app"), "<Right>")
    local feat = wait_for("▸ app.feat  1 chat · 1h ago")
    assert.truthy(line_of("▸ app  "))
    assert.is_true(feat < line_of("▸ app  ") + 3)

    press(line_of("▸ app  "), "<Right>") -- already open: no-op
    press(line_of("▸ app.feat"), "<CR>") -- not live: ⏎ unfolds
    wait_for("Feature work  1h ago")

    -- ← on a conversation folds its worktree and lands on it.
    press(line_of("Feature work"), "<Left>")
    assert.is_nil(line_of("Feature work"))
    assert.are.equal(line_of("▸ app.feat"), vim.api.nvim_win_get_cursor(win())[1])
    -- ← on a folded worktree folds its repo.
    press(line_of("▸ app.feat"), "<Left>")
    assert.is_nil(line_of("app.feat"))
    assert.are.equal(line_of("▸ app  "), vim.api.nvim_win_get_cursor(win())[1])
  end)

  it("⏎ on a stopped conversation resumes it in a new tmux window", function()
    sections.set_expanded("all", true)
    sections.set_expanded("all:repo:" .. app, true)
    sections.set_expanded("all:wt:" .. app, true)
    local started
    spawn.open_window = function(path, name, opts)
      started = { path = path, name = name, command = opts.command }
      return true
    end
    sidebar.toggle()
    press(wait_for("Old work  3d ago"), "<CR>")
    assert.are.same({ path = app, name = "app-a-old", command = "claude --resume 'a-old'" }, started)
  end)

  it("marks live worktrees and conversations, sorts them first, and ⏎ jumps in", function()
    sections.set_expanded("all", true)
    sections.set_expanded("all:repo:" .. app, true)
    sections.set_expanded("all:wt:" .. app, true)
    state.sessions = { { session_id = "a-old", state = "input", cwd = app, title = "Old work, now live", tmux_pane = "%5" } }
    state.panes = { { pane = "%5", cwd = app }, { pane = "%9", cwd = lib } }
    local opened, opened_pane
    peek.open = function(id)
      opened = id
    end
    peek.open_pane = function(p)
      opened_pane = p
    end
    sidebar.toggle()
    wait_for("▾ ● app")
    -- The session also shows in the usual list at the top; this is the
    -- All tree's row for it.
    local live_chat
    for i, l in ipairs(sidebar_lines()) do
      if i > line_of("All sessions") and l:find("● Old work, now live", 1, true) then
        live_chat = i
      end
    end
    assert.truthy(live_chat)
    -- app has the session waiting on you; lib only an untracked pane.
    assert.truthy(line_of("▾ app  ● "))
    assert.truthy(line_of("▸ lib  ◇ "))
    assert.is_true(line_of("▸ app.feat") > line_of("▾ ● app"), "live worktree first")

    press(live_chat, "<CR>")
    assert.are.equal("a-old", opened)
    press(line_of("▾ ● app"), "<CR>")
    assert.are.equal("a-old", opened)

    press(line_of("▸ lib"), "<Right>")
    press(wait_for("◇ lib"), "<CR>")
    assert.are.equal("%9", opened_pane)
  end)

  it("shows a worktree's latest ten conversations, then '… N older' to see the rest", function()
    for i = 1, 12 do
      chat(lib, "x" .. i, 100 + i, "chat number " .. i)
    end
    sections.set_expanded("all", true)
    sections.set_expanded("all:repo:" .. lib, true)
    sections.set_expanded("all:wt:" .. lib, true)
    sidebar.toggle()
    local more = wait_for("… 3 older")
    assert.truthy(line_of("chat number 9"))
    assert.is_nil(line_of("chat number 10"))
    press(more, "<CR>")
    wait_for("chat number 12")
    assert.is_nil(line_of("older"))
  end)

  it("c starts Claude in a worktree, continuing; n makes a new one in its repo", function()
    sections.set_expanded("all", true)
    sections.set_expanded("all:repo:" .. app, true)
    local started, prompted
    spawn.open_window = function(path, name, opts)
      started = { path = path, name = name, command = opts.command }
      return true
    end
    local real_prompt = spawn.prompt
    spawn.prompt = function(root)
      prompted = root
    end
    sidebar.toggle()
    press(wait_for("▸ app.feat"), "c")
    assert.are.same({ path = app .. ".feat", name = "app.feat", command = "claude --continue" }, started)
    press(line_of("▸ app.feat"), "n")
    spawn.prompt = real_prompt
    assert.are.equal(app, prompted)
  end)
end)
