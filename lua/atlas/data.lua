-- Reads the data atlas is built on, all from existing tools rather than
-- tracking anything itself: `claude-status` (session state + touched
-- worktrees), `git-review` (merge-base diff range), `gh` (PR/CI status).
-- Every public function is async (cb-based), built on vim.system, so the
-- caller (the background pollers, ultimately) never blocks on a shell-out.

local M = {}

-- Where claude-status/git-review actually live, if $PATH doesn't already
-- have them (Neovim's launch environment often differs from an
-- interactive shell that's sourced .zshrc — a GUI/terminal-launch gotcha,
-- not anything specific to this plugin). nil means: trust $PATH as-is.
-- Set via atlas.setup({ bin_dir = ... }); deliberately not hardcoded here
-- so this repo stays installable without assuming any one person's dotfiles layout.
local bin_dir = nil

-- At most this many background processes at once; the rest wait their
-- turn. Checking 40 worktrees used to start ~80 processes in one burst,
-- each slowing the others down and Neovim stalling while it spawned
-- them.
local max_jobs = 4

function M.configure(opts)
  opts = opts or {}
  bin_dir = opts.bin_dir and vim.fn.expand(opts.bin_dir) or nil
  max_jobs = opts.max_jobs or max_jobs
end

local function resolve(cmd)
  if bin_dir then
    local candidate = bin_dir .. "/" .. cmd
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end
  return cmd
end
M._resolve = resolve

local active, queue = 0, {}

local pump

local function start(cmd, cb)
  active = active + 1
  local function finish(...)
    active = active - 1
    pump()
    cb(...)
  end
  -- vim.system throws synchronously on a spawn failure (e.g. ENOENT)
  -- rather than reporting it through the result callback, so that has to
  -- be caught here too, not just a non-zero exit code below.
  local ok, err_or_handle = pcall(require("atlas.perf").system, cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        finish(false, vim.trim(result.stderr or ""))
      else
        finish(true, result.stdout or "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      finish(false, "failed to run `" .. table.concat(cmd, " ") .. "`: " .. tostring(err_or_handle))
    end)
  end
end

pump = function()
  while active < max_jobs and #queue > 0 do
    local job = table.remove(queue, 1)
    start(job.cmd, job.cb)
  end
end

-- Runs cmd in the background: cb(true, stdout) or cb(false, stderr).
-- Queued behind other atlas processes (see max_jobs); `first` jumps the
-- queue, for what the sidebar shows first (session state).
local function run(cmd, cb, first)
  table.insert(queue, first and 1 or #queue + 1, { cmd = cmd, cb = cb })
  pump()
end

--- Processes running and waiting (for tests).
function M._jobs()
  return active, #queue
end

local function run_json(cmd, cb, first)
  run(cmd, function(ok, out)
    if not ok then
      cb(nil, out)
      return
    end
    local decoded_ok, decoded = pcall(require("atlas.perf").measure, "json decode", vim.json.decode, out)
    if not decoded_ok then
      cb(nil, "failed to parse JSON from `" .. table.concat(cmd, " ") .. "`: " .. tostring(decoded))
      return
    end
    cb(decoded, nil)
  end, first)
end

-- Runs `fns` (each `function(done)`, calling `done(result)` once finished)
-- in parallel; invokes `cb(results)` (same order as `fns`) once all finish.
local function parallel(fns, cb)
  if #fns == 0 then
    cb({})
    return
  end
  local results = {}
  local remaining = #fns
  for i, fn in ipairs(fns) do
    fn(function(result)
      results[i] = result
      remaining = remaining - 1
      if remaining == 0 then
        cb(results)
      end
    end)
  end
end

--- All live Claude Code sessions: array of {state, cwd, tmux_pane,
--- session_id, pid, updated, since, transcript, title, detail, last_prompt}.
function M.sessions(cb)
  run_json({ resolve("claude-status"), "json" }, cb, true)
end

--- Worktrees touched by each session (live, or ended within 14 days):
--- array of {session_id, cwd, title, transcript, updated, paths, live},
--- where `paths` maps a touched worktree path to its last-touched epoch.
function M.touched(cb)
  run_json({ resolve("claude-status"), "touched" }, cb, true)
end

--- "<merge-base-sha> <target-ref>" for `dir`, via `git-review --base`.
function M.merge_base(dir, cb)
  run({ resolve("git-review"), "--base", dir }, function(ok, out)
    if not ok then
      cb(nil, nil, out)
      return
    end
    local base, target = out:match("^(%S+)%s+(%S+)")
    if not base then
      cb(nil, nil, "unexpected `git-review --base` output: " .. out)
      return
    end
    cb(base, target, nil)
  end)
end

--- What to review `dir` against: cb(base, target, err). Normally its
--- merge base with the target branch (merge_base). A new repo has
--- nothing to compare with -- no commits yet, or no remote and the
--- target is the branch you're on -- so then base is the empty tree and
--- everything in the repo shows as new; target is "(new repo)".
function M.review_base(dir, cb)
  local function from_scratch()
    run({ "git", "-C", dir, "hash-object", "-t", "tree", "/dev/null" }, function(ok, out)
      if ok then
        cb(vim.trim(out), "(new repo)", nil)
      else
        cb(nil, nil, "not a git repo: " .. dir)
      end
    end)
  end
  M.merge_base(dir, function(base, target, err)
    if not base then
      -- No commits or no target: still review it if it's a repo.
      run({ "git", "-C", dir, "rev-parse", "--git-dir" }, function(is_repo)
        if is_repo then
          from_scratch()
        else
          cb(nil, nil, (err and err ~= "") and err or ("not a git repo: " .. dir))
        end
      end)
      return
    end
    run({ "git", "-C", dir, "remote" }, function(_, remotes)
      if vim.trim(remotes or "") ~= "" then
        cb(base, target, nil)
        return
      end
      run({ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }, function(_, branch)
        if vim.trim(branch or "") == target then
          from_scratch()
        else
          cb(base, target, nil)
        end
      end)
    end)
  end)
end

--- The repo `dir` belongs to, identified by its main checkout, so every
--- worktree of a repo maps to the same place (e.g. devtool.hub ->
--- devtool). cb({ root = main checkout path, name = its folder name }),
--- or cb(nil) if `dir` isn't in a git repo.
function M.repo_of(dir, cb)
  run({ "git", "-C", dir, "rev-parse", "--path-format=absolute", "--git-common-dir" }, function(ok, out)
    if not ok then
      cb(nil)
      return
    end
    local common = vim.trim(out):gsub("/+$", "")
    local root = common:match("^(.*)/%.git$") or common
    cb({ root = root, name = vim.fn.fnamemodify(root, ":t") })
  end)
end

-- Whether a worktree has commits beyond its target only changes when
-- HEAD or the target moves, so has_changes remembers the answer with
-- the commits it was worked out from: dir -> { refs, key, ahead }.
-- Checking it again is then one `git rev-parse` instead of git-review
-- (a shell script running three gits), `git remote` and `git rev-list`.
local ahead_cache = {}

-- Each worktree's origin URL, for PR lookups: path -> { url, at }.
-- Re-read every few minutes; remotes almost never change.
local origins = {}
local ORIGIN_TTL_MS = 5 * 60 * 1000

-- Works out (and remembers) whether `dir` has commits beyond its target.
local function ahead_of_target(dir, cb)
  M.review_base(dir, function(base, target)
    if not base then
      ahead_cache[dir] = nil
      cb(false)
      return
    end
    local new_repo = target == "(new repo)"
    local refs = new_repo and { "HEAD" } or { "HEAD", target }
    run(vim.list_extend({ "git", "-C", dir, "rev-parse" }, refs), function(ok, shas)
      if not ok then
        ahead_cache[dir] = nil
        cb(false)
        return
      end
      local head = vim.trim(shas):match("^(%x+)")
      -- A new repo: anything committed is new.
      local range = new_repo and head or (base .. ".." .. head)
      run({ "git", "-C", dir, "rev-list", "--count", range }, function(ok2, count)
        local ahead = ok2 and (tonumber(vim.trim(count)) or 0) > 0
        if ok2 then
          ahead_cache[dir] = { refs = refs, key = vim.trim(shas), ahead = ahead }
        end
        cb(ahead)
      end)
    end)
  end)
end

--- Whether `dir` has anything to review: uncommitted or untracked files,
--- or commits that aren't in its target branch (the same merge-base
--- comparison `git review` uses). cb(true|false). In a new repo (see
--- review_base), any commit counts.
function M.has_changes(dir, cb)
  run({ "git", "-C", dir, "status", "--porcelain" }, function(ok, out)
    if not ok then
      cb(false) -- not a repo (anymore): nothing to review
      return
    end
    if vim.trim(out) ~= "" then
      cb(true)
      return
    end
    local cached = ahead_cache[dir]
    if not cached then
      ahead_of_target(dir, cb)
      return
    end
    run(vim.list_extend({ "git", "-C", dir, "rev-parse" }, cached.refs), function(ok2, shas)
      if ok2 and vim.trim(shas) == cached.key then
        cb(cached.ahead)
      else
        ahead_of_target(dir, cb)
      end
    end)
  end)
end

-- Where a worktree's .git folder is (its own folder for a linked
-- worktree), read from disk; nil if it isn't a git checkout.
local gitdirs = {}
local function gitdir_of(dir)
  if gitdirs[dir] then
    return gitdirs[dir]
  end
  local st = vim.uv.fs_stat(dir .. "/.git")
  local g
  if st and st.type == "directory" then
    g = dir .. "/.git"
  elseif st and st.type == "file" then
    local f = io.open(dir .. "/.git")
    local line = f and f:read("*l")
    if f then
      f:close()
    end
    g = line and line:match("^gitdir:%s*(.-)%s*$")
    if g and g:sub(1, 1) ~= "/" then
      g = vim.fs.normalize(dir .. "/" .. g)
    end
  end
  gitdirs[dir] = g
  return g
end

--- A cheap fingerprint of `dir`'s git state, from file stats only (no
--- process): its index and HEAD. Staging, committing, switching branch
--- or resetting changes it; editing a file doesn't. nil if `dir` isn't
--- a git checkout.
function M.git_state(dir)
  local g = gitdir_of(dir)
  if not g then
    return nil
  end
  local parts = {}
  for _, name in ipairs({ "index", "HEAD" }) do
    local st = vim.uv.fs_stat(g .. "/" .. name)
    parts[#parts + 1] = st and (st.mtime.sec .. "." .. st.mtime.nsec .. ":" .. st.size) or "-"
  end
  return table.concat(parts, "|")
end

--- Forgets cached git answers (for tests).
function M._reset_caches()
  ahead_cache, gitdirs, origins = {}, {}, {}
end

--- has_changes for many paths at once, in parallel. cb(set) where
--- set[path] = true for each path that has changes.
function M.changed(paths, cb)
  parallel(
    vim.tbl_map(function(path)
      return function(done)
        M.has_changes(path, function(changed)
          done({ path = path, changed = changed })
        end)
      end
    end, paths),
    function(results)
      local set = {}
      for _, r in ipairs(results) do
        if r.changed then
          set[r.path] = true
        end
      end
      cb(set)
    end
  )
end

--- "owner/repo" for a GitHub origin URL (ssh or https); nil if the URL
--- isn't a github.com remote.
local function owner_repo(origin_url)
  local path = origin_url:match("github%.com[:/]([%w_.-]+/[%w_.-]+)")
  if not path then
    return nil
  end
  return (path:gsub("%.git$", ""))
end
M._owner_repo = owner_repo

local function git_origin(path, cb)
  local c = origins[path]
  if c and vim.uv.now() - c.at < ORIGIN_TTL_MS then
    cb(c.url)
    return
  end
  run({ "git", "-C", path, "remote", "get-url", "origin" }, function(ok, out)
    local url = ok and vim.trim(out) or nil
    origins[path] = { url = url, at = vim.uv.now() }
    cb(url)
  end)
end

local function git_branch(path, cb)
  run({ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" }, function(ok, out)
    cb(ok and vim.trim(out) or nil)
  end)
end

--- One glyph summarizing a PR's statusCheckRollup: "none" (no checks),
--- "pending" (something hasn't finished), "passing", or "failing".
local function summarize_checks(rollup)
  if not rollup or #rollup == 0 then
    return "none"
  end
  local pending = false
  for _, check in ipairs(rollup) do
    local conclusion = check.conclusion
    if conclusion and conclusion ~= "" then
      if conclusion ~= "SUCCESS" and conclusion ~= "NEUTRAL" and conclusion ~= "SKIPPED" then
        return "failing"
      end
    else
      pending = true
    end
  end
  return pending and "pending" or "passing"
end
M._summarize_checks = summarize_checks

--- Finds `branch`'s PR in `prs` (as returned by `gh pr list`), summarized
--- to {number, state, url, is_draft, checks}; nil if there isn't one.
local function match_pr(prs, branch)
  for _, pr in ipairs(prs) do
    if pr.headRefName == branch then
      return {
        number = pr.number,
        state = pr.state,
        url = pr.url,
        is_draft = pr.isDraft,
        review = pr.reviewDecision, -- APPROVED | CHANGES_REQUESTED | REVIEW_REQUIRED | ""
        checks = summarize_checks(pr.statusCheckRollup),
      }
    end
  end
  return nil
end
M._match_pr = match_pr

--- One word for where a PR stands, in priority order: "merged",
--- "closed" (not merged), "draft", "approved", "changes" (changes
--- requested), or "review" (open, waiting for review).
function M.pr_kind(pr)
  if pr.state == "MERGED" then
    return "merged"
  elseif pr.state == "CLOSED" then
    return "closed"
  elseif pr.is_draft then
    return "draft"
  elseif pr.review == "APPROVED" then
    return "approved"
  elseif pr.review == "CHANGES_REQUESTED" then
    return "changes"
  end
  return "review"
end

--- PR/CI status for a set of worktree paths, one `gh pr list` call per
--- distinct repo (grouped by origin) rather than one per worktree, so API
--- usage stays bounded as the number of touched worktrees grows.
--- cb(results) where results[path] = {number, state, url, is_draft, checks}
--- for paths with a matching open-or-closed PR; paths without one are
--- simply absent from `results`.
function M.pr_status(paths, cb)
  if #paths == 0 then
    cb({})
    return
  end

  parallel(
    vim.tbl_map(function(path)
      return function(done)
        git_origin(path, function(origin)
          git_branch(path, function(branch)
            done({ path = path, origin = origin, branch = branch })
          end)
        end)
      end
    end, paths),
    function(infos)
      local groups = {} -- "owner/repo" -> { info, ... }
      for _, info in ipairs(infos) do
        local repo = info.origin and owner_repo(info.origin)
        if repo then
          groups[repo] = groups[repo] or {}
          table.insert(groups[repo], info)
        end
      end

      local repo_names = vim.tbl_keys(groups)
      parallel(
        vim.tbl_map(function(repo)
          return function(done)
            run_json({
              "gh", "pr", "list", "-R", repo, "--state", "all", "--json",
              "number,state,url,headRefName,isDraft,reviewDecision,statusCheckRollup",
            }, function(prs)
              done({ repo = repo, prs = prs or {} })
            end)
          end
        end, repo_names),
        function(repo_results)
          local prs_by_repo = {}
          for _, r in ipairs(repo_results) do
            prs_by_repo[r.repo] = r.prs
          end

          local results = {}
          for repo, infos_for_repo in pairs(groups) do
            local prs = prs_by_repo[repo] or {}
            for _, info in ipairs(infos_for_repo) do
              local match = match_pr(prs, info.branch)
              if match then
                results[info.path] = match
              end
            end
          end
          cb(results)
        end
      )
    end
  )
end

--- Parses `git worktree list --porcelain` into { {path, branch}, ... },
--- main checkout first. branch is nil for a detached HEAD; bare
--- entries are left out.
function M._parse_worktrees(text)
  local list, cur = {}, nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local path = line:match("^worktree (.+)$")
    if path then
      cur = { path = path }
      list[#list + 1] = cur
    elseif cur and line == "bare" then
      cur.bare = true
    elseif cur then
      local ref = line:match("^branch (.+)$")
      if ref then
        cur.branch = ref:gsub("^refs/heads/", "")
      end
    end
  end
  return vim.tbl_filter(function(w)
    return not w.bare
  end, list)
end

--- Every worktree of the repo whose main checkout is `root`.
--- cb(list) as in _parse_worktrees; {} if it isn't a repo.
function M.worktrees(root, cb)
  run({ "git", "-C", root, "worktree", "list", "--porcelain" }, function(ok, out)
    cb(ok and M._parse_worktrees(out) or {})
  end)
end

-- A process name that is Claude Code itself: "claude", or Nix's
-- ".claude-wrapped". Not helpers like claude-status.
local function is_claude(comm)
  local name = vim.fn.fnamemodify(comm, ":t")
  return name == "claude" or name == ".claude-wrapped"
end

--- Which tmux panes run Claude, from `tmux list-panes -a` output
--- ("pane_id|pane_pid|path" lines) and `ps -ax -o pid=,ppid=,comm=`
--- output: Claude is the pane's process or runs under it (e.g. a
--- shell that started it). One entry per pane, { pane, cwd }.
function M._claude_panes_from(panes_text, ps_text)
  local comm, children = {}, {}
  for line in (ps_text .. "\n"):gmatch("(.-)\n") do
    local pid, ppid, c = line:match("^%s*(%d+)%s+(%d+)%s+(.+)$")
    if pid then
      comm[pid] = c
      children[ppid] = children[ppid] or {}
      table.insert(children[ppid], pid)
    end
  end
  local function runs_claude(pid, depth)
    if comm[pid] and is_claude(comm[pid]) then
      return true
    end
    if depth == 0 then
      return false
    end
    for _, child in ipairs(children[pid] or {}) do
      if runs_claude(child, depth - 1) then
        return true
      end
    end
    return false
  end
  local list, seen = {}, {}
  for line in (panes_text .. "\n"):gmatch("(.-)\n") do
    local pane, pid, cwd = line:match("^(%%%d+)|(%d+)|(.*)$")
    -- Grouped sessions list the same pane more than once.
    if pane and not seen[pane] then
      seen[pane] = true
      if runs_claude(pid, 3) then
        list[#list + 1] = { pane = pane, cwd = cwd }
      end
    end
  end
  return list
end

--- tmux panes running Claude Code, whether or not claude-status knows
--- about them. cb(list) as in _claude_panes_from; {} without tmux.
function M.claude_panes(cb)
  run({ "tmux", "list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}|#{pane_current_path}" }, function(ok, panes)
    if not ok then
      cb({})
      return
    end
    run({ "ps", "-ax", "-o", "pid=,ppid=,comm=" }, function(ok2, ps)
      cb(ok2 and M._claude_panes_from(panes, ps) or {})
    end)
  end)
end

--- When Claude Code last wrote a conversation for `path` (epoch
--- seconds), or nil if it never had one there. Claude keeps them in
--- ~/.claude/projects/<path with every non-alphanumeric char as "-">.
function M.last_conversation(path, projects_dir)
  projects_dir = projects_dir or vim.fn.expand("~/.claude/projects")
  local dir = projects_dir .. "/" .. path:gsub("[^%w-]", "-")
  local newest
  for _, f in ipairs(vim.fn.glob(dir .. "/*.jsonl", false, true)) do
    local st = vim.uv.fs_stat(f)
    if st and (not newest or st.mtime.sec > newest) then
      newest = st.mtime.sec
    end
  end
  return newest
end

return M
