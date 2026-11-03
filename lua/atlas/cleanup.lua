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
  local r = require("atlas.perf").system(vim.list_extend({ "git", "-C", dir }, args), { text = true }):wait()
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
  -- A session's folder can be a subfolder; removal needs the worktree root.
  local _, top = git(path, { "rev-parse", "--show-toplevel" })
  if top ~= "" then
    item.path = top
  end

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

  local r = require("atlas.perf").system({ "git-review", "--base", path }, { text = true }):wait()
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
    local note = it.own and it.safe and ", closes the session" or ""
    lines[#lines + 1] = string.format("  %s %s (%s%s)", it.safe and "remove" or "keep  ", name, it.reason, note)
  end
  return table.concat(lines, "\n")
end

--- Closes the tmux pane a session runs in, ending the session. If the
--- live view is showing it, that closes first: its tmux client would
--- otherwise jump to another window once the pane is gone. Refuses
--- anything that isn't a real "%N" pane id. Returns ok, err.
function M.close_pane(pane)
  if not require("atlas.deliver").is_pane_id(pane) then
    return false, "no valid tmux pane for the session"
  end
  require("atlas.peek").close_view_of(pane)
  local r = require("atlas.perf").system({ "tmux", "kill-pane", "-t", pane }, { text = true }):wait()
  if r.code ~= 0 then
    return false, "could not close the session's pane: " .. vim.trim(r.stderr or "")
  end
  return true
end

local CLOSE_ONLY = "Close the session, keep its worktree"

--- Asks before removing a session's finished worktrees, then removes
--- the safe ones. `paths` are the worktrees it touched outside its own
--- folder. opts.own = { path, pane }: the session's own folder and tmux
--- pane. If that folder is a linked worktree that's safe to remove,
--- it's offered too, and confirming closes the session's pane first (a
--- worktree with a live session inside it isn't finished). If it isn't
--- safe, closing the session is offered on its own, keeping the
--- worktree. opts.prs: PR status by path, already known (the sidebar's
--- cache), instead of asking GitHub again.
--- Calls cb(removed_count, closed) when done; removed_count is 0 if
--- cancelled or nothing was removed, `closed` true if the session was.
function M.run(paths, cb, opts)
  cb = cb or function() end
  opts = opts or {}
  local all = vim.list_extend({}, paths)
  if opts.own and opts.own.path then
    all[#all + 1] = opts.own.path
  end
  local function with_prs(fn)
    if opts.prs then
      fn(opts.prs)
    else
      data.pr_status(all, fn)
    end
  end
  with_prs(function(pr_by_path)
    local items, own = {}, nil
    require("atlas.perf").measure("cleanup: classify worktrees", function()
      for _, p in ipairs(paths) do
        items[#items + 1] = M.classify(p, pr_by_path[p])
      end
      if opts.own and opts.own.path then
        own = M.classify(opts.own.path, pr_by_path[opts.own.path])
        own.own = true
        own.pane = opts.own.pane
        -- Never remove a worktree twice if it was also in `paths`.
        local dup = false
        for _, it in ipairs(items) do
          if it.path == own.path then
            dup = true
          end
        end
        if not dup then
          items[#items + 1] = own
        end
      end
    end)
    local safe = vim.tbl_filter(function(it)
      return it.safe
    end, items)
    local pane = own and require("atlas.deliver").is_pane_id(own.pane) and own.pane or nil
    -- The session can only go along with its worktree if that's safe;
    -- otherwise closing it is a separate choice.
    local own_safe = own and own.safe

    local choices = {}
    if #safe > 0 then
      choices[#choices + 1] = "Remove " .. #safe .. " worktree(s) and their local branches"
    end
    if pane and not own_safe then
      if #safe > 0 then
        choices[#choices + 1] = "Remove " .. #safe .. " worktree(s) and close the session"
      end
      choices[#choices + 1] = CLOSE_ONLY
    end
    if #choices == 0 then
      vim.notify("atlas: nothing to clean up\n" .. summary(items), vim.log.levels.INFO)
      cb(0, false)
      return
    end
    choices[#choices + 1] = "Cancel"

    vim.ui.select(choices, {
      prompt = "atlas cleanup:\n" .. summary(items) .. "\n",
    }, function(choice)
      if not choice or choice == "Cancel" then
        cb(0, false)
        return
      end
      local do_remove = choice:match("^Remove") ~= nil
      local do_close = choice == CLOSE_ONLY or choice:find("close the session", 1, true) ~= nil or (do_remove and own_safe)
      local removed, failures, closed = 0, {}, false
      if do_close and pane then
        local ok, err = M.close_pane(pane)
        closed = ok
        if not ok then
          failures[#failures + 1] = err
        elseif do_remove and own_safe then
          -- Give the shell/claude a moment to exit before git checks the tree.
          vim.wait(300)
        end
      end
      if do_remove then
        for _, it in ipairs(safe) do
          local ok, err = true, nil
          if it.own and not closed then
            ok, err = false, "the session is still running in it"
          end
          if ok then
            ok, err = M.remove(it)
          end
          if ok then
            removed = removed + 1
          else
            failures[#failures + 1] = vim.fn.fnamemodify(it.path, ":t") .. ": " .. err
          end
        end
      end
      local msg = do_remove and ("atlas: removed " .. removed .. " worktree(s)") or "atlas: closed the session"
      if do_remove and closed then
        msg = msg .. " and closed the session"
      end
      if #failures > 0 then
        msg = msg .. "\n" .. table.concat(failures, "\n")
      end
      vim.notify(msg, #failures > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
      cb(removed, closed)
    end)
  end)
end

return M
