local spawn = require("atlas.spawn")

-- Real git repos and a disposable tmux session. Windows run `sleep`,
-- never `claude`, so tests don't start real Claude sessions.
local root, tmux_session

local function sh(args)
  local r = vim.system(args, { text = true }):wait()
  return r.code == 0, vim.trim(r.stdout or "")
end

local function git(dir, args)
  local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  assert(r.code == 0, "git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""))
  return vim.trim(r.stdout or "")
end

local function windows()
  local _, out = sh({ "tmux", "list-windows", "-t", tmux_session, "-F", "#W" })
  local res = {}
  for w in (out .. "\n"):gmatch("(.-)\n") do
    if w ~= "" then
      res[#res + 1] = w
    end
  end
  return res
end

describe("atlas.spawn", function()
  local real_input

  before_each(function()
    real_input = vim.ui.input
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/repo", "p")
    git(root .. "/repo", { "init", "-q", "-b", "main" })
    git(root .. "/repo", { "config", "user.email", "t@example.com" })
    git(root .. "/repo", { "config", "user.name", "t" })
    vim.fn.writefile({ "x" }, root .. "/repo/f.txt")
    git(root .. "/repo", { "add", "." })
    git(root .. "/repo", { "commit", "-q", "-m", "init" })

    local name = "atlas-test-spawn-" .. string.format("%d", vim.uv.hrtime())
    sh({ "tmux", "new-session", "-d", "-s", name, "-x", "80", "-y", "24" })
    local _, id = sh({ "tmux", "display-message", "-p", "-t", "=" .. name .. ":", "#{session_id}" })
    assert(id:match("^%$%d+$"), "could not resolve test tmux session id")
    tmux_session = id
  end)

  after_each(function()
    vim.ui.input = real_input
    sh({ "tmux", "kill-session", "-t", tmux_session })
    vim.fn.delete(root, "rf")
  end)

  it("creates a sibling worktree on a new branch (git fallback)", function()
    local path, err = spawn.create_worktree(root .. "/repo", "feature/x", { use_wt = false })
    assert.is_not_nil(path, err)
    assert.are.equal(root .. "/repo-feature-x", vim.fn.resolve(path))
    assert.are.equal("feature/x", git(path, { "rev-parse", "--abbrev-ref", "HEAD" }))
  end)

  it("reports a failure instead of a path when the branch already exists", function()
    git(root .. "/repo", { "branch", "taken" })
    local path, err = spawn.create_worktree(root .. "/repo", "taken", { use_wt = false })
    assert.is_nil(path)
    assert.truthy(err:find("failed", 1, true))
  end)

  it("opens a background window named after the branch, marked like wt-spawn", function()
    local _, active_before = sh({ "tmux", "display-message", "-p", "-t", tmux_session, "#{window_id}" })
    local ok, err = spawn.open_window(root .. "/repo", "feature/y", { session = tmux_session, command = "sleep 300" })
    assert.is_true(ok, err)

    assert.truthy(vim.tbl_contains(windows(), "feature-y"))
    local _, active_after = sh({ "tmux", "display-message", "-p", "-t", tmux_session, "#{window_id}" })
    assert.are.equal(active_before, active_after, "the new window must not take focus")
    local _, marked = sh({ "tmux", "show-options", "-wqv", "-t", tmux_session .. ":feature-y", "@claude" })
    assert.are.equal("1", marked)
    local _, cwd = sh({ "tmux", "display-message", "-p", "-t", tmux_session .. ":feature-y", "#{pane_current_path}" })
    assert.are.equal(root .. "/repo", vim.fn.resolve(cwd))
  end)

  it("doesn't open a second window for the same branch", function()
    spawn.open_window(root .. "/repo", "dup", { session = tmux_session, command = "sleep 300" })
    spawn.open_window(root .. "/repo", "dup", { session = tmux_session, command = "sleep 300" })
    local n = 0
    for _, w in ipairs(windows()) do
      if w == "dup" then
        n = n + 1
      end
    end
    assert.are.equal(1, n)
  end)

  it("prompt: asks for a branch, creates the worktree and opens the window", function()
    vim.ui.input = function(_, cb)
      cb("new-thing")
    end
    local result
    spawn.prompt(root .. "/repo", function(ok)
      result = ok
    end, { use_wt = false, session = tmux_session, command = "sleep 300" })

    assert.is_true(result)
    assert.are.equal(1, vim.fn.isdirectory(root .. "/repo-new-thing"))
    assert.truthy(vim.tbl_contains(windows(), "new-thing"))
  end)

  it("prompt: does nothing when cancelled", function()
    vim.ui.input = function(_, cb)
      cb(nil)
    end
    local result
    spawn.prompt(root .. "/repo", function(ok)
      result = ok
    end, { use_wt = false, session = tmux_session, command = "sleep 300" })
    assert.is_false(result)
    assert.are.equal(0, vim.fn.isdirectory(root .. "/repo-"))
  end)
end)
