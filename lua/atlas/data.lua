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

function M.configure(opts)
  opts = opts or {}
  bin_dir = opts.bin_dir and vim.fn.expand(opts.bin_dir) or nil
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

local function run(cmd, cb)
  -- vim.system throws synchronously on a spawn failure (e.g. ENOENT)
  -- rather than reporting it through the result callback, so that has to
  -- be caught here too, not just a non-zero exit code below.
  local ok, err_or_handle = pcall(vim.system, cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(false, vim.trim(result.stderr or ""))
      else
        cb(true, result.stdout or "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      cb(false, "failed to run `" .. table.concat(cmd, " ") .. "`: " .. tostring(err_or_handle))
    end)
  end
end

local function run_json(cmd, cb)
  run(cmd, function(ok, out)
    if not ok then
      cb(nil, out)
      return
    end
    local decoded_ok, decoded = pcall(vim.json.decode, out)
    if not decoded_ok then
      cb(nil, "failed to parse JSON from `" .. table.concat(cmd, " ") .. "`: " .. tostring(decoded))
      return
    end
    cb(decoded, nil)
  end)
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
  run_json({ resolve("claude-status"), "json" }, cb)
end

--- Worktrees touched by each session (live, or ended within 14 days):
--- array of {session_id, cwd, title, transcript, updated, paths, live},
--- where `paths` maps a touched worktree path to its last-touched epoch.
function M.touched(cb)
  run_json({ resolve("claude-status"), "touched" }, cb)
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

--- Whether `dir` has anything to review: uncommitted or untracked files,
--- or commits that aren't in its target branch (the same merge-base
--- comparison `git review` uses). cb(true|false). Without a target
--- branch, only uncommitted/untracked files count.
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
    M.merge_base(dir, function(base)
      if not base then
        cb(false)
        return
      end
      run({ "git", "-C", dir, "rev-list", "--count", base .. "..HEAD" }, function(ok2, count)
        cb(ok2 and (tonumber(vim.trim(count)) or 0) > 0)
      end)
    end)
  end)
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
  run({ "git", "-C", path, "remote", "get-url", "origin" }, function(ok, out)
    cb(ok and vim.trim(out) or nil)
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
        checks = summarize_checks(pr.statusCheckRollup),
      }
    end
  end
  return nil
end
M._match_pr = match_pr

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
              "number,state,url,headRefName,isDraft,statusCheckRollup",
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

return M
