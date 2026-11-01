-- Every Claude Code conversation on this machine, from the transcripts
-- Claude keeps in ~/.claude/projects/<encoded cwd>/<session id>.jsonl,
-- grouped by repo and worktree. Not just the sessions claude-status
-- tracks: anything that ever ran.
--
-- Built to stay cheap with hundreds of repos and thousands of
-- conversations:
-- - The folder name encodes the cwd lossily (every non-alphanumeric
--   char becomes "-"), so the real cwd is read from the first few KB of
--   one transcript per folder, once, and cached.
-- - Repos and worktrees are found by walking up to `.git` in Lua (no git
--   process per folder), also cached.
-- - Titles need the end of each transcript (Claude re-appends title
--   records as it goes), so they're only read for conversations that
--   are actually shown, and cached until the file changes.

local M = {}

local uv = vim.uv

local HEAD_BYTES = 64 * 1024 -- the cwd shows up within the first ~20KB
local TAIL_BYTES = 64 * 1024

-- Throwaway places: scratchpads, test fixtures.
local SKIP_PREFIXES = { "/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/" }

local dir_cache = nil -- project folder name -> cwd; loaded from disk on first use
local dir_cache_dirty = false
local git_cache = {} -- cwd -> { worktree, root, name } (false: not in a repo)
local title_cache = {} -- transcript path -> { mtime, size, title }
local cache_path_override = nil

-- Folder -> cwd never changes, so it's kept across restarts: with
-- thousands of folders, the first scan is the only slow one.
local function cache_path()
  return cache_path_override or (vim.fn.stdpath("state") .. "/nvim-atlas/history-dirs.json")
end

local function load_dir_cache()
  if dir_cache then
    return
  end
  dir_cache = {}
  local p = cache_path()
  if vim.fn.filereadable(p) == 1 then
    local ok, d = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
    if ok and type(d) == "table" and not vim.islist(d) then
      dir_cache = d
    end
  end
end

local function save_dir_cache()
  if not dir_cache_dirty then
    return
  end
  dir_cache_dirty = false
  vim.fn.mkdir(vim.fn.fnamemodify(cache_path(), ":h"), "p")
  pcall(vim.fn.writefile, { vim.json.encode(next(dir_cache) and dir_cache or vim.empty_dict()) }, cache_path())
end

--- Forgets everything cached; `cache_file` moves the on-disk cache (for tests).
function M._reset(cache_file)
  cache_path_override = cache_file
  dir_cache, dir_cache_dirty, git_cache, title_cache = nil, false, {}, {}
end

local function read_range(path, offset, len)
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local chunk = uv.fs_read(fd, len, offset)
  uv.fs_close(fd)
  return chunk
end

--- The cwd recorded in a transcript (the first `"cwd":"..."`), or nil.
--- Reads a few KB at a time: it's usually within the first 1-20KB.
function M._cwd_of(file)
  local fd = uv.fs_open(file, "r", 438)
  if not fd then
    return nil
  end
  local head, raw = "", nil
  while #head < HEAD_BYTES do
    local chunk = uv.fs_read(fd, 8192, #head)
    if not chunk or chunk == "" then
      break
    end
    head = head .. chunk
    raw = head:match('"cwd":"(.-[^\\])"')
    if raw then
      break
    end
  end
  uv.fs_close(fd)
  if not raw then
    return nil
  end
  local ok, cwd = pcall(vim.json.decode, '"' .. raw .. '"')
  return ok and cwd or nil
end

-- Claude's folder name for a path: every non-alphanumeric char as "-".
local function encode(path)
  return (path:gsub("[^%w-]", "-"))
end

local function skipped(path, prefixes)
  for _, p in ipairs(prefixes) do
    if path:sub(1, #p) == p then
      return true
    end
  end
  return false
end

--- The worktree and repo `dir` is in, from the nearest `.git`: a folder
--- (main checkout) or a file pointing at <repo>/.git/worktrees/<name>
--- (linked worktree). { worktree, root = main checkout, name }, or nil.
function M.git_of(dir)
  local cached = git_cache[dir]
  if cached ~= nil then
    return cached or nil
  end
  local result = false
  local d = dir
  while d and d ~= "" do
    local git = d .. "/.git"
    local st = uv.fs_stat(git)
    if st and st.type == "directory" then
      result = { worktree = d, root = d }
      break
    elseif st and st.type == "file" then
      local line = (read_range(git, 0, 4096) or ""):match("gitdir:%s*([^\r\n]+)")
      local root = d
      if line then
        if line:sub(1, 1) ~= "/" then
          line = vim.fs.normalize(d .. "/" .. line)
        end
        -- <repo>/.git/worktrees/<name>, or <repo>.git/worktrees/<name>
        -- for a bare repo. Anything else (a submodule): its own repo.
        local common = line:match("^(.*)/worktrees/[^/]+/?$")
        if common then
          root = common:match("^(.*)/%.git$") or common
        end
      end
      result = { worktree = d, root = root }
      break
    end
    local parent = vim.fs.dirname(d)
    if parent == d then
      break
    end
    d = parent
  end
  if result then
    result.name = vim.fn.fnamemodify(result.root, ":t")
  end
  git_cache[dir] = result
  return result or nil
end

-- A scan in progress: start_scan() lists the folders, step() handles
-- the next `n` of them (returns true when all are done), finish()
-- sorts and returns the result.
local function start_scan(projects_dir, opts)
  projects_dir = projects_dir or vim.fn.expand("~/.claude/projects")
  local skip = (opts and opts.skip) or SKIP_PREFIXES
  -- The same prefixes as folder names, to skip before reading anything.
  local skip_names = {}
  for i, p in ipairs(skip) do
    skip_names[i] = encode(p)
  end
  load_dir_cache()
  local names = {}
  local handle = uv.fs_scandir(projects_dir)
  while handle do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "directory" and not skipped(name, skip_names) then
      names[#names + 1] = name
    end
  end
  return {
    dir = projects_dir,
    skip = skip,
    names = names,
    next = 1,
    repos = {},
    by_root = {},
    by_wt = {},
    removed = 0,
  }
end

local function scan_folder(sc, name)
  local dir = sc.dir .. "/" .. name
  local files = {}
  local h = uv.fs_scandir(dir)
  while h do
    local f, ft = uv.fs_scandir_next(h)
    if not f then
      break
    end
    if ft == "file" and f:sub(-6) == ".jsonl" then
      local st = uv.fs_stat(dir .. "/" .. f)
      if st and st.size > 0 then
        files[#files + 1] = { id = f:sub(1, -7), file = dir .. "/" .. f, mtime = st.mtime.sec }
      end
    end
  end
  if #files == 0 then
    return
  end
  local cwd = dir_cache[name]
  if cwd == nil then
    cwd = false
    for _, f in ipairs(files) do
      cwd = M._cwd_of(f.file) or false
      if cwd then
        break
      end
    end
    dir_cache[name] = cwd
    dir_cache_dirty = true
  end
  if not cwd or skipped(cwd, sc.skip) then
    return
  end
  if vim.fn.isdirectory(cwd) == 0 then
    sc.removed = sc.removed + #files
    return
  end
  local git = M.git_of(cwd)
  if not git then
    return
  end
  local repo = sc.by_root[git.root]
  if not repo then
    repo = { root = git.root, name = git.name, mtime = 0, worktrees = {} }
    sc.by_root[git.root] = repo
    sc.repos[#sc.repos + 1] = repo
  end
  local wt = sc.by_wt[git.worktree]
  if not wt then
    wt = { path = git.worktree, mtime = 0, chats = {} }
    sc.by_wt[git.worktree] = wt
    table.insert(repo.worktrees, wt)
  end
  for _, f in ipairs(files) do
    f.cwd = cwd
    table.insert(wt.chats, f)
    wt.mtime = math.max(wt.mtime, f.mtime)
  end
  repo.mtime = math.max(repo.mtime, wt.mtime)
end

local function step(sc, n)
  local last = math.min(#sc.names, sc.next + n - 1)
  for i = sc.next, last do
    scan_folder(sc, sc.names[i])
  end
  sc.next = last + 1
  return sc.next > #sc.names
end

local function finish(sc)
  local function newest(a, b)
    if a.mtime ~= b.mtime then
      return a.mtime > b.mtime
    end
    return (a.path or a.root or a.id) < (b.path or b.root or b.id)
  end
  for _, repo in ipairs(sc.repos) do
    for _, wt in ipairs(repo.worktrees) do
      table.sort(wt.chats, newest)
    end
    table.sort(repo.worktrees, newest)
  end
  table.sort(sc.repos, newest)
  save_dir_cache()
  return sc.repos, sc.removed
end

--- All conversations, grouped. Returns a list of repos, most recently
--- active first:
---   { root, name, mtime, worktrees = { { path, mtime, chats = {
---     { id, file, cwd, mtime }, ... } }, ... } }
--- Worktrees and chats are most recent first too. Folders that no
--- longer exist, aren't in a git repo, or are scratch space are left
--- out; the second result counts conversations whose folder is gone.
--- opts.skip: path prefixes to leave out (default: temp folders).
function M.scan(projects_dir, opts)
  local sc = start_scan(projects_dir, opts)
  step(sc, #sc.names)
  return finish(sc)
end

--- Like scan(), spread over the event loop (a batch of folders per
--- tick) so a large ~/.claude/projects never freezes the UI.
--- cb(repos, removed).
function M.scan_async(projects_dir, opts, cb)
  local sc = start_scan(projects_dir, opts)
  local function tick()
    if step(sc, 100) then
      cb(finish(sc))
    else
      vim.schedule(tick)
    end
  end
  vim.schedule(tick)
end

local TITLE_KEYS = {
  { type = "custom-title", field = "customTitle" }, -- /rename
  { type = "ai-title", field = "aiTitle" },
  { type = "agent-name", field = "agentName" }, -- claude -n
  { type = "last-prompt", field = "lastPrompt" },
}

local function title_in(text)
  local best = {}
  -- The first line may be cut off mid-way; it won't parse, which is fine.
  for line in text:gmatch("[^\n]+") do
    for i, k in ipairs(TITLE_KEYS) do
      if line:find('"type":"' .. k.type .. '"', 1, true) then
        local ok, rec = pcall(vim.json.decode, line)
        if ok and type(rec) == "table" and type(rec[k.field]) == "string" and rec[k.field] ~= "" then
          best[i] = rec[k.field]
        end
      end
    end
  end
  for i = 1, #TITLE_KEYS do
    if best[i] then
      return (best[i]:gsub("%s+", " "))
    end
  end
end

--- A conversation's title: its /rename name, else Claude's generated
--- title, else its `claude -n` name, else the last prompt. nil if none found.
function M.title(file)
  local st = uv.fs_stat(file)
  if not st then
    return nil
  end
  local c = title_cache[file]
  if c and c.mtime == st.mtime.sec and c.size == st.size then
    return c.title
  end
  local offset = math.max(0, st.size - TAIL_BYTES)
  local title = title_in(read_range(file, offset, TAIL_BYTES) or "")
  if not title and offset > 0 then
    title = title_in(read_range(file, 0, HEAD_BYTES) or "")
  end
  title_cache[file] = { mtime = st.mtime.sec, size = st.size, title = title }
  return title
end

return M
