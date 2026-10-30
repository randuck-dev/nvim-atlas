local data = require("atlas.data")

-- Waits for an async atlas.data call to finish, returning whatever it
-- passed its callback. Fails the test if it doesn't finish in time.
local function await(fn)
  local out, done = nil, false
  fn(function(...)
    out = { ... }
    done = true
  end)
  vim.wait(5000, function()
    return done
  end, 20)
  assert.is_true(done, "callback never fired")
  return out
end

local function fixture_path(name)
  -- tests are always run from the repo root (see scripts/test.sh).
  return vim.fn.getcwd() .. "/tests/atlas/fixtures/" .. name
end

local function read_json_fixture(name)
  local lines = vim.fn.readfile(fixture_path(name))
  return vim.json.decode(table.concat(lines, "\n"))
end

describe("atlas.data._owner_repo", function()
  it("parses https github remotes", function()
    assert.are.equal(
      "randuck-dev/nvim-atlas",
      data._owner_repo("https://github.com/randuck-dev/nvim-atlas.git")
    )
  end)

  it("parses ssh github remotes", function()
    assert.are.equal("randuck-dev/dotfiles", data._owner_repo("git@github.com:randuck-dev/dotfiles.git"))
  end)

  it("returns nil for non-github remotes", function()
    assert.is_nil(data._owner_repo("https://gitlab.com/foo/bar.git"))
  end)
end)

describe("atlas.data._summarize_checks and _match_pr (real gh pr list fixture)", function()
  local prs = read_json_fixture("gh_pr_list.json")

  it("summarizes an all-SUCCESS PR as passing", function()
    local match = data._match_pr(prs, "fix/duplicate-location-header-on-isr-miss")
    assert.is_not_nil(match)
    assert.are.equal(100903, match.number)
    assert.are.equal("passing", match.checks)
  end)

  it("summarizes a PR with an unfinished check as pending", function()
    local match = data._match_pr(prs, "backport-100102-to-lts-active")
    assert.is_not_nil(match)
    assert.are.equal("pending", match.checks)
  end)

  it("summarizes a PR with a FAILURE conclusion as failing", function()
    local match = data._match_pr(prs, "fleet/segment-config-parity-tests")
    assert.is_not_nil(match)
    assert.are.equal("failing", match.checks)
  end)

  it("returns nil for a branch with no open PR", function()
    assert.is_nil(data._match_pr(prs, "no-such-branch"))
  end)

  it("summarizes an empty rollup as none", function()
    assert.are.equal("none", data._summarize_checks({}))
    assert.are.equal("none", data._summarize_checks(nil))
  end)
end)

describe("atlas.data.merge_base (real git-review call)", function()
  it("computes the merge base of a throwaway feature branch off main", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")

    local function git(args)
      local result = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
      assert.are.equal(0, result.code, "git " .. table.concat(args, " ") .. " failed: " .. (result.stderr or ""))
      return result
    end

    git({ "init", "-q", "-b", "main" })
    git({ "config", "user.email", "atlas-test@example.com" })
    git({ "config", "user.name", "atlas test" })
    vim.fn.writefile({ "one" }, dir .. "/file.txt")
    git({ "add", "." })
    git({ "commit", "-q", "-m", "init" })
    local base_sha = vim.trim(git({ "rev-parse", "HEAD" }).stdout)

    git({ "checkout", "-q", "-b", "feature" })
    vim.fn.writefile({ "one", "two" }, dir .. "/file.txt")
    git({ "commit", "-q", "-am", "feature change" })

    local result = await(function(cb)
      data.merge_base(dir, function(base, target, err)
        cb(base, target, err)
      end)
    end)
    local base, target, err = result[1], result[2], result[3]

    assert.is_nil(err)
    assert.are.equal(base_sha, base)
    assert.are.equal("main", target)

    vim.fn.delete(dir, "rf")
  end)
end)

describe("atlas.data.sessions and .touched (real claude-status on this machine)", function()
  it("sessions() returns well-shaped live session entries", function()
    local result = await(function(cb)
      data.sessions(function(sessions, err)
        cb(sessions, err)
      end)
    end)
    local sessions, err = result[1], result[2]

    assert.is_nil(err)
    assert.is_table(sessions)
    for _, session in ipairs(sessions) do
      assert.is_string(session.session_id)
      assert.is_string(session.state)
      assert.is_string(session.cwd)
    end
  end)

  it("touched() returns well-shaped touched-worktree entries", function()
    local result = await(function(cb)
      data.touched(function(touched, err)
        cb(touched, err)
      end)
    end)
    local touched, err = result[1], result[2]

    assert.is_nil(err)
    assert.is_table(touched)
    for _, entry in ipairs(touched) do
      assert.is_string(entry.session_id)
      assert.is_table(entry.paths)
    end
  end)
end)

describe("atlas.data.has_changes (real git fixtures)", function()
  local root

  local function git(dir, args)
    local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    assert(r.code == 0, "git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""))
  end

  local function check(path)
    local result, done = nil, false
    data.has_changes(path, function(c)
      result, done = c, true
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    assert.is_true(done)
    return result
  end

  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/main", "p")
    git(root .. "/main", { "init", "-q", "-b", "main" })
    git(root .. "/main", { "config", "user.email", "t@example.com" })
    git(root .. "/main", { "config", "user.name", "t" })
    vim.fn.writefile({ "one" }, root .. "/main/f.txt")
    git(root .. "/main", { "add", "." })
    git(root .. "/main", { "commit", "-q", "-m", "init" })
    git(root .. "/main", { "worktree", "add", "-q", root .. "/wt", "-b", "feature" })
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("is false for a clean worktree with no commits beyond its target", function()
    assert.is_false(check(root .. "/wt"))
  end)

  it("is true when the branch has commits not in its target", function()
    vim.fn.writefile({ "two" }, root .. "/wt/f.txt")
    git(root .. "/wt", { "commit", "-q", "-am", "change" })
    assert.is_true(check(root .. "/wt"))
  end)

  it("is true with uncommitted changes", function()
    vim.fn.writefile({ "edited" }, root .. "/wt/f.txt")
    assert.is_true(check(root .. "/wt"))
  end)

  it("is true with an untracked file", function()
    vim.fn.writefile({ "new" }, root .. "/wt/new.txt")
    assert.is_true(check(root .. "/wt"))
  end)

  it("is false for something that isn't a repository", function()
    local dir = root .. "/plain"
    vim.fn.mkdir(dir, "p")
    assert.is_false(check(dir))
  end)
end)

describe("atlas.data.repo_of (real git fixtures)", function()
  local root

  local function git(dir, args)
    local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
    assert(r.code == 0, "git " .. table.concat(args, " ") .. ": " .. (r.stderr or ""))
  end

  local function repo_of(dir)
    local result, done = "unset", false
    data.repo_of(dir, function(r)
      result, done = r, true
    end)
    vim.wait(5000, function()
      return done
    end, 20)
    return result
  end

  before_each(function()
    root = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(root .. "/myrepo/sub", "p")
    git(root .. "/myrepo", { "init", "-q", "-b", "main" })
    git(root .. "/myrepo", { "config", "user.email", "t@example.com" })
    git(root .. "/myrepo", { "config", "user.name", "t" })
    vim.fn.writefile({ "x" }, root .. "/myrepo/sub/f.txt")
    git(root .. "/myrepo", { "add", "." })
    git(root .. "/myrepo", { "commit", "-q", "-m", "init" })
    git(root .. "/myrepo", { "worktree", "add", "-q", root .. "/myrepo-feature", "-b", "feature" })
  end)

  after_each(function()
    vim.fn.delete(root, "rf")
  end)

  it("names the main checkout for the repo itself and a subfolder", function()
    assert.are.same({ root = root .. "/myrepo", name = "myrepo" }, repo_of(root .. "/myrepo"))
    assert.are.same({ root = root .. "/myrepo", name = "myrepo" }, repo_of(root .. "/myrepo/sub"))
  end)

  it("maps a linked worktree to its main checkout", function()
    assert.are.same({ root = root .. "/myrepo", name = "myrepo" }, repo_of(root .. "/myrepo-feature"))
  end)

  it("is nil outside a repo", function()
    vim.fn.mkdir(root .. "/plain", "p")
    assert.is_nil(repo_of(root .. "/plain"))
  end)
end)

describe("atlas.data.pr_kind", function()
  it("ranks merged > closed > draft > approved > changes requested > in review", function()
    assert.are.equal("merged", data.pr_kind({ state = "MERGED", review = "APPROVED" }))
    assert.are.equal("closed", data.pr_kind({ state = "CLOSED" }))
    assert.are.equal("draft", data.pr_kind({ state = "OPEN", is_draft = true, review = "APPROVED" }))
    assert.are.equal("approved", data.pr_kind({ state = "OPEN", review = "APPROVED" }))
    assert.are.equal("changes", data.pr_kind({ state = "OPEN", review = "CHANGES_REQUESTED" }))
    assert.are.equal("review", data.pr_kind({ state = "OPEN", review = "REVIEW_REQUIRED" }))
    assert.are.equal("review", data.pr_kind({ state = "OPEN", review = "" }))
  end)
end)
