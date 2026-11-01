local history = require("atlas.history")

-- A fake ~/.claude/projects plus the folders its conversations ran in.
-- Temp folders are skipped by default, so tests pass `skip = {}` (or
-- their own list).
local base, projects, cache_file

local function encode(path)
  return (path:gsub("[^%w-]", "-"))
end

local function write(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

-- A conversation that ran in `cwd`, last written `age` seconds ago.
local function chat(cwd, id, age, records)
  local file = projects .. "/" .. encode(cwd) .. "/" .. id .. ".jsonl"
  local lines = {
    vim.json.encode({ type = "queue-operation", operation = "enqueue" }),
    vim.json.encode({ type = "user", cwd = cwd, message = { role = "user", content = "hi" } }),
  }
  for _, r in ipairs(records or {}) do
    lines[#lines + 1] = vim.json.encode(r)
  end
  write(file, lines)
  local t = os.time() - (age or 0)
  vim.uv.fs_utime(file, t, t)
  return file
end

local function repo(path)
  vim.fn.mkdir(path .. "/.git", "p")
end

local function worktree(main, path, name)
  vim.fn.mkdir(path, "p")
  write(path .. "/.git", { "gitdir: " .. main .. "/.git/worktrees/" .. name })
end

describe("atlas.history", function()
  before_each(function()
    base = vim.fn.resolve(vim.fn.tempname())
    projects = base .. "/projects"
    cache_file = base .. "/cache/history-dirs.json"
    vim.fn.mkdir(projects, "p")
    history._reset(cache_file)
  end)

  after_each(function()
    vim.fn.delete(base, "rf")
    history._reset(nil)
  end)

  it("groups conversations by repo and worktree, most recent first", function()
    local app = base .. "/w/app"
    repo(app)
    worktree(app, base .. "/w/app.feat", "feat")
    repo(base .. "/w/lib")
    chat(app, "a1", 300)
    chat(app, "a2", 100)
    vim.fn.mkdir(app .. "/sub/dir", "p")
    chat(app .. "/sub/dir", "a3", 5000) -- a subfolder belongs to the checkout
    chat(base .. "/w/app.feat", "f1", 10)
    chat(base .. "/w/lib", "l1", 9000)

    local repos, removed = history.scan(projects, { skip = {} })
    assert.are.equal(0, removed)
    assert.are.equal(2, #repos)
    assert.are.equal("app", repos[1].name)
    assert.are.equal(app, repos[1].root)
    assert.are.equal("lib", repos[2].name)

    local wts = repos[1].worktrees
    assert.are.same({ base .. "/w/app.feat", app }, { wts[1].path, wts[2].path })
    local ids = {}
    for _, c in ipairs(wts[2].chats) do
      ids[#ids + 1] = c.id
    end
    assert.are.same({ "a2", "a1", "a3" }, ids)
    assert.are.equal(app .. "/sub/dir", wts[2].chats[3].cwd, "resume needs the folder it ran in")
  end)

  it("leaves out removed folders (counted), non-repos, empty files and skipped prefixes", function()
    repo(base .. "/w/app")
    chat(base .. "/w/app", "ok", 0)
    chat(base .. "/w/gone", "g1", 0) -- folder never existed
    chat(base .. "/w/gone", "g2", 0)
    vim.fn.mkdir(base .. "/w/plain", "p")
    chat(base .. "/w/plain", "p1", 0)
    repo(base .. "/scratch/x")
    chat(base .. "/scratch/x", "s1", 0)
    vim.fn.writefile({}, projects .. "/" .. encode(base .. "/w/app") .. "/empty.jsonl")

    local repos, removed = history.scan(projects, { skip = { base .. "/scratch/" } })
    assert.are.equal(1, #repos)
    assert.are.equal(1, #repos[1].worktrees[1].chats)
    assert.are.equal(2, removed)
  end)

  it("finds the main checkout of a linked worktree, and of a bare repo's", function()
    repo(base .. "/w/app")
    worktree(base .. "/w/app", base .. "/w/app-wt", "wt")
    assert.are.same({ worktree = base .. "/w/app-wt", root = base .. "/w/app", name = "app" }, history.git_of(base .. "/w/app-wt"))
    vim.fn.mkdir(base .. "/w/bare.git/worktrees/b", "p")
    vim.fn.mkdir(base .. "/w/b", "p")
    write(base .. "/w/b/.git", { "gitdir: " .. base .. "/w/bare.git/worktrees/b" })
    assert.are.equal(base .. "/w/bare.git", history.git_of(base .. "/w/b/deep").root)
    assert.is_nil(history.git_of("/"))
  end)

  it("remembers each folder's cwd on disk, so a restart doesn't read transcripts again", function()
    repo(base .. "/w/app")
    local file = chat(base .. "/w/app", "a1", 0)
    history.scan(projects, { skip = {} })
    assert.are.equal(1, vim.fn.filereadable(cache_file))

    -- A "restart" whose transcript no longer says where it ran: the
    -- cached cwd is used.
    history._reset(cache_file)
    vim.fn.writefile({ vim.json.encode({ type = "user" }) }, file)
    local repos = history.scan(projects, { skip = {} })
    assert.are.equal(1, #repos)
  end)

  it("scan_async gives the same result as scan", function()
    repo(base .. "/w/app")
    for i = 1, 150 do -- more folders than one batch
      local d = base .. "/w/app/d" .. i
      vim.fn.mkdir(d, "p")
      chat(d, "c" .. i, i)
    end
    local sync = history.scan(projects, { skip = {} })
    local async
    history.scan_async(projects, { skip = {} }, function(repos)
      async = repos
    end)
    assert.is_true(vim.wait(3000, function()
      return async ~= nil
    end))
    assert.are.same(sync, async)
    assert.are.equal(150, #async[1].worktrees[1].chats)
  end)

  describe("title", function()
    it("prefers /rename, then Claude's title, then the -n name, then the last prompt, using the latest of each", function()
      local cwd = base .. "/w/app"
      local f = chat(cwd, "t1", 0, {
        { type = "last-prompt", lastPrompt = "fix the  thing\nplease" },
      })
      assert.are.equal("fix the thing please", history.title(f))
      f = chat(cwd, "t2", 0, {
        { type = "last-prompt", lastPrompt = "p" },
        { type = "agent-name", agentName = "app-abc123" },
      })
      assert.are.equal("app-abc123", history.title(f))
      f = chat(cwd, "t3", 0, {
        { type = "ai-title", aiTitle = "old title" },
        { type = "agent-name", agentName = "app-abc123" },
        { type = "ai-title", aiTitle = "New title" },
      })
      assert.are.equal("New title", history.title(f))
      f = chat(cwd, "t4", 0, {
        { type = "custom-title", customTitle = "my name" },
        { type = "ai-title", aiTitle = "New title" },
      })
      assert.are.equal("my name", history.title(f))
      assert.is_nil(history.title(chat(cwd, "t5", 0)))
    end)

    it("reads only the end of a large transcript, and notices when it changes", function()
      local cwd = base .. "/w/app"
      local pad = string.rep("x", 1000)
      local recs = { { type = "ai-title", aiTitle = "early" } }
      for _ = 1, 200 do
        recs[#recs + 1] = { type = "attachment", x = pad }
      end
      recs[#recs + 1] = { type = "ai-title", aiTitle = "late" }
      local f = chat(cwd, "big", 0, recs)
      assert.are.equal("late", history.title(f))

      local lines = vim.fn.readfile(f)
      lines[#lines + 1] = vim.json.encode({ type = "custom-title", customTitle = "renamed" })
      vim.fn.writefile(lines, f)
      assert.are.equal("renamed", history.title(f))
    end)
  end)
end)
