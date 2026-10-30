-- Start a new worktree in a repo and a Claude session in it, from the
-- sidebar. Mirrors ~/.dotfiles/tmux-wt-spawn.sh (prefix C) so both
-- behave the same: the worktree is made with worktrunk (`wt switch -c`)
-- off the repo's main checkout, and a tmux window named after the
-- branch runs `claude`, marked @claude with monitor-silence like the
-- script's windows. Differences: the repo is the one picked in the
-- sidebar rather than the active pane's, and the window opens in the
-- background (-d) so focus stays in Neovim -- the new session shows up
-- in the sidebar, and <CR> on it opens it. Without `wt`, falls back to
-- `git worktree add ../<repo>-<branch> -b <branch>`.

local M = {}

-- Names atlas gave the sessions it started, by worktree path, so the
-- sidebar can show them right away: `claude -n <name>` names the session
-- in Claude itself, but claude-status reads titles from the transcript,
-- which doesn't exist until the session's first message.
local names_override = nil
local function names_path()
  return names_override or (vim.fn.stdpath("state") .. "/nvim-atlas/names.json")
end

--- For tests: store names somewhere else (nil restores the default).
function M._set_names_path(p)
  names_override = p
end

local function load_names()
  local p = names_path()
  if vim.fn.filereadable(p) == 0 then
    return {}
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
  return (ok and type(data) == "table" and not vim.islist(data)) and data or {}
end

--- All remembered names: { [worktree path] = name }.
M.names = load_names

--- The name atlas gave the session it started in `path`, or nil.
function M.name_for(path)
  return path and load_names()[path] or nil
end

function M.remember(path, name)
  local names = load_names()
  names[path] = name
  vim.fn.mkdir(vim.fn.fnamemodify(names_path(), ":h"), "p")
  vim.fn.writefile({ vim.json.encode(names) }, names_path())
end

--- "<branch>-<6 hex>": the branch (made safe as a name) plus a short
--- random suffix, so sessions on similar branches stay easy to tell apart.
function M.session_name(branch)
  local slug = branch:gsub("[^%w._-]", "-")
  local bytes = vim.uv.random(3)
  local hex = bytes and (bytes:gsub(".", function(c)
    return string.format("%02x", c:byte())
  end)) or string.format("%06x", math.random(0, 0xffffff))
  return slug .. "-" .. hex
end

local function run(args, cwd)
  local r = vim.system(args, { text = true, cwd = cwd }):wait()
  return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

--- Path of the worktree checked out on `branch`, or nil.
local function worktree_for_branch(root, branch)
  local ok, out = run({ "git", "-C", root, "worktree", "list", "--porcelain" })
  if not ok then
    return nil
  end
  local path
  for line in (out .. "\n"):gmatch("(.-)\n") do
    local p = line:match("^worktree (.+)$")
    if p then
      path = p
    elseif line == "branch refs/heads/" .. branch then
      return path
    end
  end
  return nil
end

--- Creates a worktree for `branch` in the repo whose main checkout is
--- `root`. opts.use_wt (default: whether `wt` is installed). Returns
--- path or nil, err.
function M.create_worktree(root, branch, opts)
  opts = opts or {}
  local use_wt = opts.use_wt
  if use_wt == nil then
    use_wt = vim.fn.executable("wt") == 1
  end

  local ok, _, err
  if use_wt then
    ok, _, err = run({ "wt", "switch", "-c", branch }, root)
  else
    local path = vim.fn.fnamemodify(root, ":h") .. "/" .. vim.fn.fnamemodify(root, ":t") .. "-" .. branch:gsub("/", "-")
    ok, _, err = run({ "git", "-C", root, "worktree", "add", path, "-b", branch })
  end
  if not ok then
    return nil, (use_wt and "wt switch -c" or "git worktree add") .. " failed: " .. err
  end

  local path = worktree_for_branch(root, branch)
  if not path or vim.fn.isdirectory(path) == 0 then
    return nil, "worktree created, but couldn't find its path for " .. branch
  end
  return path
end

--- The shell command a spawned window runs: opts.command, else
--- `claude -n <opts.session_name>` (plain `claude` without a name), then
--- a shell, so the window stays useful after Claude exits.
function M.command_for(opts)
  opts = opts or {}
  local claude = opts.session_name and ("claude -n " .. vim.fn.shellescape(opts.session_name)) or "claude"
  return (opts.command or claude) .. "; exec ${SHELL:-zsh}"
end

--- Opens a background tmux window named after `branch` in tmux session
--- `session` (default: the session this Neovim runs in), running
--- opts.command in `path` (default: `claude -n <opts.session_name>`, or
--- plain `claude` without one). If a window with that name exists,
--- leaves it alone. Returns ok, err.
function M.open_window(path, branch, opts)
  opts = opts or {}
  local session = opts.session
  if not session then
    local ok, out = run({ "tmux", "display-message", "-p", "#{session_id}" })
    if not ok or out == "" then
      return false, "not inside tmux"
    end
    session = out
  end
  local name = branch:gsub("/", "-")
  local command = M.command_for(opts)

  local _, windows = run({ "tmux", "list-windows", "-t", session, "-F", "#W" })
  for w in (windows .. "\n"):gmatch("(.-)\n") do
    if w == name then
      return true
    end
  end

  local ok, _, err = run({ "tmux", "new-window", "-d", "-t", session .. ":", "-n", name, "-c", path, command })
  if not ok then
    return false, "tmux new-window failed: " .. err
  end
  local target = session .. ":" .. name
  run({ "tmux", "set-option", "-w", "-t", target, "@claude", "1" })
  run({ "tmux", "set-option", "-w", "-t", target, "monitor-silence", "30" })
  return true
end

--- Prompts for a branch name, then creates the worktree in `root` and
--- starts a Claude session in it. cb(ok) when done.
function M.prompt(root, cb, opts)
  cb = cb or function() end
  local repo = vim.fn.fnamemodify(root, ":t")
  vim.ui.input({ prompt = "New worktree in " .. repo .. ", branch: " }, function(branch)
    branch = branch and vim.trim(branch) or ""
    if branch == "" then
      cb(false)
      return
    end
    local path, err = M.create_worktree(root, branch, opts)
    if not path then
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      cb(false)
      return
    end
    local name = M.session_name(branch)
    local ok, werr = M.open_window(path, branch, vim.tbl_extend("force", opts or {}, { session_name = name }))
    if not ok then
      vim.notify("atlas: worktree created at " .. path .. ", but " .. werr, vim.log.levels.WARN)
      cb(false)
      return
    end
    M.remember(path, name)
    vim.notify("atlas: started " .. name .. " in " .. repo, vim.log.levels.INFO)
    cb(true, name)
  end)
end

return M
