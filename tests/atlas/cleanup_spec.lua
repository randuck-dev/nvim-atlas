local cleanup = require("atlas.cleanup")

-- Real git fixtures: a main repo on `main` plus linked worktrees in
-- different states, all under a throwaway directory.
local root

local function git(dir, args)
  local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  assert(r.code == 0, "git " .. table.concat(args, " ") .. " failed: " .. (r.stderr or ""))
  return vim.trim(r.stdout or "")
end

local function branch_exists(name)
  local r = vim.system({ "git", "-C", root .. "/main", "rev-parse", "--verify", "-q", "refs/heads/" .. name }):wait()
  return r.code == 0
end

local function commit(dir, file, content, msg)
  vim.fn.writefile({ content }, dir .. "/" .. file)
  git(dir, { "add", "." })
  git(dir, { "commit", "-q", "-m", msg })
end

-- A linked worktree at root/<name> on a new branch <name>.
local function worktree(name)
  git(root .. "/main", { "worktree", "add", "-q", root .. "/" .. name, "-b", name })
  return root .. "/" .. name
end

describe("atlas.cleanup", function()
  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/main", "p")
    local main = root .. "/main"
    git(main, { "init", "-q", "-b", "main" })
    git(main, { "config", "user.email", "atlas-test@example.com" })
    git(main, { "config", "user.name", "atlas test" })
    commit(main, "f.txt", "one", "init")
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  describe("classify", function()
    it("marks a worktree whose branch is merged into its target as safe", function()
      local wt = worktree("feature-merged")
      commit(wt, "g.txt", "x", "feature work")
      git(root .. "/main", { "merge", "-q", "--ff-only", "feature-merged" })

      local item = cleanup.classify(wt, nil)
      assert.is_true(item.safe, item.reason)
      assert.are.equal("feature-merged", item.branch)
    end)

    it("keeps a worktree with commits not in the target", function()
      local wt = worktree("feature-open")
      commit(wt, "g.txt", "x", "unmerged work")

      local item = cleanup.classify(wt, nil)
      assert.is_false(item.safe)
      assert.truthy(item.reason:find("not in", 1, true))
    end)

    it("keeps a merged worktree that has uncommitted or untracked changes", function()
      local wt = worktree("feature-dirty")
      vim.fn.writefile({ "scratch" }, wt .. "/untracked.txt")

      local item = cleanup.classify(wt, nil)
      assert.is_false(item.safe)
      assert.truthy(item.reason:find("uncommitted", 1, true))
    end)

    it("never offers a repo's main checkout", function()
      local item = cleanup.classify(root .. "/main", { state = "MERGED", number = 1 })
      assert.is_false(item.safe)
      assert.truthy(item.reason:find("main checkout", 1, true))
    end)

    it("keeps a worktree whose PR is still open", function()
      local wt = worktree("feature-pr-open")
      local item = cleanup.classify(wt, { state = "OPEN", number = 7 })
      assert.is_false(item.safe)
      assert.truthy(item.reason:find("still open", 1, true))
    end)

    it("treats a merged PR as safe even if the branch isn't an ancestor (squash merges)", function()
      local wt = worktree("feature-squashed")
      commit(wt, "g.txt", "x", "work that got squash-merged")
      local item = cleanup.classify(wt, { state = "MERGED", number = 9 })
      assert.is_true(item.safe)
    end)

    it("reports a path that no longer exists", function()
      local item = cleanup.classify(root .. "/nope", nil)
      assert.is_false(item.safe)
      assert.truthy(item.reason:find("no longer exists", 1, true))
    end)
  end)

  describe("remove", function()
    it("removes a merged worktree and its local branch", function()
      local wt = worktree("done")
      commit(wt, "g.txt", "x", "work")
      git(root .. "/main", { "merge", "-q", "--ff-only", "done" })

      local ok, err = cleanup.remove(cleanup.classify(wt, nil))
      assert.is_true(ok, err)
      assert.are.equal(0, vim.fn.isdirectory(wt))
      assert.is_false(branch_exists("done"))
    end)

    it("refuses an item that wasn't classified safe", function()
      local wt = worktree("not-done")
      commit(wt, "g.txt", "x", "unmerged")

      local ok = cleanup.remove(cleanup.classify(wt, nil))
      assert.is_false(ok)
      assert.are.equal(1, vim.fn.isdirectory(wt))
      assert.is_true(branch_exists("not-done"))
    end)

    it("keeps an unmerged branch even when a merged PR made the worktree removable", function()
      -- A squash-merged PR: the worktree goes, but `branch -d` (not -D)
      -- refuses the branch since its commits aren't in main. That's the
      -- second guard working; the caller gets told.
      local wt = worktree("squashed")
      commit(wt, "g.txt", "x", "squashed work")

      local ok, err = cleanup.remove(cleanup.classify(wt, { state = "MERGED", number = 3 }))
      assert.is_false(ok)
      assert.truthy(err:find("branch -d failed", 1, true))
      assert.are.equal(0, vim.fn.isdirectory(wt))
      assert.is_true(branch_exists("squashed"))
    end)
  end)

  describe("run", function()
    local data = require("atlas.data")
    local real_pr, real_select

    before_each(function()
      real_pr, real_select = data.pr_status, vim.ui.select
      data.pr_status = function(_, cb)
        cb({})
      end
    end)

    after_each(function()
      data.pr_status, vim.ui.select = real_pr, real_select
    end)

    it("removes only the safe worktrees after confirmation", function()
      local merged = worktree("m")
      commit(merged, "g.txt", "x", "w")
      git(root .. "/main", { "merge", "-q", "--ff-only", "m" })
      local open = worktree("o")
      commit(open, "h.txt", "y", "w2")

      vim.ui.select = function(choices, _, on_choice)
        on_choice(choices[1])
      end
      local removed
      cleanup.run({ merged, open, root .. "/main" }, function(n)
        removed = n
      end)

      assert.are.equal(1, removed)
      assert.are.equal(0, vim.fn.isdirectory(merged))
      assert.are.equal(1, vim.fn.isdirectory(open))
      assert.are.equal(1, vim.fn.isdirectory(root .. "/main"))
    end)

    it("removes nothing when cancelled", function()
      local merged = worktree("m2")
      commit(merged, "g.txt", "x", "w")
      git(root .. "/main", { "merge", "-q", "--ff-only", "m2" })

      vim.ui.select = function(choices, _, on_choice)
        on_choice(choices[2]) -- "Cancel"
      end
      local removed
      cleanup.run({ merged }, function(n)
        removed = n
      end)

      assert.are.equal(0, removed)
      assert.are.equal(1, vim.fn.isdirectory(merged))
    end)
  end)

  describe("run with the session's own worktree", function()
    local data = require("atlas.data")
    local real_pr, real_select
    local tmux_session

    local function sh(args)
      local r = vim.system(args, { text = true }):wait()
      return r.code == 0, vim.trim(r.stdout or "")
    end

    -- A pane running in `dir`, standing in for the session's Claude.
    local function pane_in(dir)
      local name = "atlas-test-cleanup-" .. string.format("%d", vim.uv.hrtime())
      sh({ "tmux", "new-session", "-d", "-s", name, "-c", dir, "sleep 300" })
      local _, pane = sh({ "tmux", "list-panes", "-t", "=" .. name .. ":", "-F", "#{pane_id}" })
      assert(pane:match("^%%%d+$"), "could not resolve test pane")
      tmux_session = name
      return pane
    end

    local function pane_alive(pane)
      local ok, out = sh({ "tmux", "display-message", "-p", "-t", pane, "#{pane_id}" })
      return ok and out == pane
    end

    before_each(function()
      real_pr, real_select = data.pr_status, vim.ui.select
      data.pr_status = function(_, cb)
        cb({})
      end
      vim.ui.select = function(choices, _, on_choice)
        on_choice(choices[1])
      end
      tmux_session = nil
    end)

    after_each(function()
      data.pr_status, vim.ui.select = real_pr, real_select
      if tmux_session then
        sh({ "tmux", "kill-session", "-t", "=" .. tmux_session .. ":" })
      end
    end)

    it("closes the session's pane, then removes its finished worktree and branch", function()
      local wt = worktree("own-done")
      local pane = pane_in(wt)

      local removed
      cleanup.run({}, function(n)
        removed = n
      end, { own = { path = wt, pane = pane } })

      assert.are.equal(1, removed)
      assert.is_false(pane_alive(pane), "the session's pane should be closed")
      assert.are.equal(0, vim.fn.isdirectory(wt))
      assert.is_false(branch_exists("own-done"))
    end)

    it("leaves the session alone when its worktree isn't finished", function()
      local wt = worktree("own-dirty")
      vim.fn.writefile({ "wip" }, wt .. "/wip.txt")
      local pane = pane_in(wt)

      local removed
      cleanup.run({}, function(n)
        removed = n
      end, { own = { path = wt, pane = pane } })

      assert.are.equal(0, removed)
      assert.is_true(pane_alive(pane), "an unfinished session must not be closed")
      assert.are.equal(1, vim.fn.isdirectory(wt))
    end)

    it("never offers a main checkout, even as the session's own folder", function()
      local pane = pane_in(root .. "/main")
      local removed
      cleanup.run({}, function(n)
        removed = n
      end, { own = { path = root .. "/main", pane = pane } })

      assert.are.equal(0, removed)
      assert.is_true(pane_alive(pane))
      assert.are.equal(1, vim.fn.isdirectory(root .. "/main"))
    end)

    it("works from a subfolder of the worktree", function()
      local wt = worktree("own-sub")
      vim.fn.mkdir(wt .. "/sub", "p")
      local pane = pane_in(wt .. "/sub")

      cleanup.run({}, nil, { own = { path = wt .. "/sub", pane = pane } })

      assert.are.equal(0, vim.fn.isdirectory(wt))
      assert.is_false(branch_exists("own-sub"))
    end)
  end)
end)
