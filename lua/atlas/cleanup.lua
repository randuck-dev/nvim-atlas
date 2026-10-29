-- "I'm done with this session": remove its worktrees and their local
-- branches once their work has landed.
--
-- Deliberately conservative, because it deletes things:
-- - only linked worktrees are candidates, never a repo's main checkout
--   (sessions touch those too, e.g. ~/.dotfiles);
-- - only worktrees whose work provably landed are removed: PR merged, or
--   the branch is already contained in its target branch;
-- - anything with uncommitted/untracked changes, an open PR or unmerged
--   commits is skipped and reported with the reason, never removed;
-- - removal uses `git worktree remove` (no --force) and `git branch -d`
--   (not -D), both of which refuse to drop unmerged work themselves --
--   a second, independent guard after the classification here;
-- - remote branches are never touched.

local data = require("atlas.data")

local M = {}

local function git(dir, args)
  local r = vim.system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
  return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

--- Classifies one path. `pr` is its entry from data.pr_status, or nil.
--- Returns { path, safe, reason, branch, common_dir }:
--- safe = true means it can be removed; otherwise `reason` says why not.
function M.classify(path, pr)
  local item = { path = path, safe = false }

  if vim.fn.isdirectory(path) == 0 then
    item.reason = "no longer exists"
    return item
  end

  local ok, git_dir = git(path, { "rev-parse", "--absolute-git-dir" })
  local ok2, common = git(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" })
  if not ok or not ok2 then
    item.reason = "not a git repository"
    return item
  end
  if git_dir == common then
    item.reason = "main checkout, not a worktree"
    return item
  end
  item.common_dir = common

  local _, branch = git(path, { "rev-parse", "--abbrev-ref", "HEAD" })
  if branch == "" or branch == "HEAD" then
    item.reason = "detached HEAD"
    return item
  end
  item.branch = branch

  local _, dirty = git(path, { "status", "--porcelain" })
  if dirty ~= "" then
    item.reason = "uncommitted or untracked changes"
    return item
  end

  if pr and pr.state == "MERGED" then
    item.safe = true
    item.reason = "PR #" .. pr.number .. " merged"
    return item
  end
  if pr and pr.state == "OPEN" then
    item.reason = "PR #" .. pr.number .. " still open"
    return item
  end

  local r = vim.system({ "git-review", "--base", path }, { text = true }):wait()
  local target = (r.stdout or ""):match("^%S+%s+(%S+)")
  if r.code ~= 0 or not target then
    item.reason = "no target branch to compare with"
    return item
  end
  if git(path, { "merge-base", "--is-ancestor", "HEAD", target }) then
    item.safe = true
    item.reason = "merged into " .. target
  else
    item.reason = "has commits not in " .. target
  end
  return item
end

--- Removes one safe item: the worktree, then its local branch.
--- Returns ok, err.
function M.remove(item)
  if not item.safe then
    return false, "not safe to remove: " .. tostring(item.reason)
  end
  local ok, _, err = git(item.common_dir, { "worktree", "remove", item.path })
  if not ok then
    return false, "worktree remove failed: " .. err
  end
  ok, _, err = git(item.common_dir, { "branch", "-d", item.branch })
  if not ok then
    return false, "worktree removed, but branch -d failed: " .. err
  end
  return true
end

local function summary(items)
  local lines = {}
  for _, it in ipairs(items) do
    local name = vim.fn.fnamemodify(it.path, ":t")
    lines[#lines + 1] = string.format("  %s %s (%s)", it.safe and "remove" or "keep  ", name, it.reason)
  end
  return table.concat(lines, "\n")
end

--- Asks before removing session_id's finished worktrees, then removes
--- the safe ones. `paths` are the session's touched worktree paths.
--- Calls cb(removed_count) when done (or 0 if cancelled / nothing to do).
function M.run(paths, cb)
  cb = cb or function() end
  data.pr_status(paths, function(pr_by_path)
    local items = {}
    for _, p in ipairs(paths) do
      items[#items + 1] = M.classify(p, pr_by_path[p])
    end
    local safe = vim.tbl_filter(function(it)
      return it.safe
    end, items)

    if #safe == 0 then
      vim.notify("atlas: nothing to clean up\n" .. summary(items), vim.log.levels.INFO)
      cb(0)
      return
    end

    vim.ui.select({ "Remove " .. #safe .. " worktree(s) and their local branches", "Cancel" }, {
      prompt = "atlas cleanup:\n" .. summary(items) .. "\n",
    }, function(choice)
      if not choice or not choice:match("^Remove") then
        cb(0)
        return
      end
      local removed, failures = 0, {}
      for _, it in ipairs(safe) do
        local ok, err = M.remove(it)
        if ok then
          removed = removed + 1
        else
          failures[#failures + 1] = vim.fn.fnamemodify(it.path, ":t") .. ": " .. err
        end
      end
      local msg = "atlas: removed " .. removed .. " worktree(s)"
      if #failures > 0 then
        msg = msg .. "\n" .. table.concat(failures, "\n")
      end
      vim.notify(msg, #failures > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      cb(removed)
    end)
  end)
end

return M
