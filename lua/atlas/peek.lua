-- A real, interactive terminal onto a session's tmux pane, inside
-- Neovim: tmux is the backend, Neovim is the orchestration interface.
--
-- How: a real `tmux attach` client runs in a Neovim terminal buffer,
-- attached to a throwaway *grouped* view session (`new-session -t`),
-- which shares the target session's windows but has its own options.
-- Its status bar is turned off for the view session only, so the
-- user's real session keeps its own. tmux itself does all rendering,
-- input and resizing, so complex TUIs (like Claude Code) render
-- exactly as in a normal tmux client.
--
-- An earlier version re-emulated the pane from capture-pane snapshots
-- plus a pipe-pane byte relay. That drifted out of sync on TUIs doing
-- cursor-relative redraws (garbled fragments, a skewed cursor), because
-- our copy was never the source of truth. Attaching a real client
-- removes that whole class of problem instead of patching around it.
--
-- Lives in the window next to the sidebar (taking over whatever buffer
-- was there), not a floating modal. One view at a time: opening another
-- session tears the previous view session and client down first.

local data = require("atlas.data")

local M = {}

-- Key that leaves the view (terminal or normal mode) and jumps back to
-- the session's row in the sidebar. Ctrl-q, because Claude Code uses
-- Esc (interrupt) and Esc Esc (rewind) itself.
local leave_key = "<C-q>"

function M.configure(opts)
  opts = opts or {}
  leave_key = opts.leave_key or leave_key
end

local function tmux(args)
  local r = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
  return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

-- Exact-match session target. The trailing ":" matters: tmux accepts
-- "=name" for kill-session/has-session, but set-option and
-- show-options reject it ("no such session") -- which silently left
-- the view's status bar on. "=name:" works for all of them.
local function sess(name)
  return "=" .. name .. ":"
end

-- { buf, job, view } for the one live view, or nil.
local current = nil

-- Quitting Neovim with a view open must not leave its session behind.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if current then
      M.close()
    end
  end,
})

--- The current view's grouped tmux session name (or nil), for tests.
function M._current_view()
  return current and current.view
end

local function stop_current()
  if not current then
    return
  end
  local c = current
  current = nil
  if c.job then
    pcall(vim.fn.jobstop, c.job)
  end
  tmux({ "kill-session", "-t", sess(c.view) })
end
M.close = stop_current

local function find_main_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].filetype ~= "AtlasSidebar" then
      return win
    end
  end
  return nil
end

--- Creates a grouped view session showing `pane` (focused, in its
--- window), with the status bar off for the view only. Returns the
--- view session name, or nil and an error.
local function create_view(pane)
  if not require("atlas.deliver").is_pane_id(pane) then
    return nil, "not a tmux pane id: '" .. tostring(pane) .. "'"
  end
  local ok, out, err = tmux({ "display-message", "-p", "-t", pane, "#{session_id} #{window_id}" })
  if not ok then
    return nil, "pane " .. pane .. " not found: " .. err
  end
  local session_id, window_id = out:match("^(%S+)%s+(%S+)$")
  if not session_id then
    return nil, "unexpected tmux output: " .. out
  end

  -- Numeric names only: tmux parses '.' and ':' in targets as
  -- window/pane separators.
  local view = "atlas-view-" .. string.format("%d", vim.uv.hrtime())
  ok, _, err = tmux({ "new-session", "-d", "-t", session_id, "-s", view })
  if not ok then
    return nil, "could not create view session: " .. err
  end
  -- Not destroy-unattached: set on a session with no client yet, tmux
  -- destroys it immediately (confirmed). Cleanup happens in on_exit,
  -- close() and VimLeavePre instead.
  ok, _, err = tmux({ "set-option", "-t", sess(view), "status", "off" })
  if not ok then
    tmux({ "kill-session", "-t", sess(view) })
    return nil, "could not hide the view session's status bar: " .. err
  end
  tmux({ "select-window", "-t", sess(view) .. window_id })
  tmux({ "select-pane", "-t", pane })
  return view
end

--- Leaves terminal mode and focuses the sidebar on the row for `key`.
--- The view keeps running next to it.
local function back_to_sidebar(key)
  vim.cmd("stopinsert")
  vim.schedule(function()
    require("atlas.sidebar").focus_session(key)
  end)
end

--- Asks tmux to redraw the view client from scratch, so Neovim's
--- terminal grid can't keep a stale cursor row from an earlier partial
--- update.
local function refresh_client(view)
  local ok, tty = tmux({ "list-clients", "-t", sess(view), "-F", "#{client_tty}" })
  tty = ok and tty:match("^(%S+)")
  if tty then
    vim.system({ "tmux", "refresh-client", "-t", tty })
  end
end

--- Opens a real interactive terminal onto session_id's tmux pane in the
--- window next to the sidebar (or a new vsplit if the sidebar is the
--- only window), already in terminal mode for typing. <C-q>
--- (configurable) goes back to the sidebar, `q` in normal mode closes
--- it. No-ops (with a warning) if the session isn't live or has no
--- recorded tmux pane.
function M.open(session_id)
  data.sessions(function(sessions, err)
    if err then
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      return
    end

    local session
    for _, s in ipairs(sessions) do
      if s.session_id == session_id then
        session = s
      end
    end
    if not session then
      vim.notify("atlas: session not found (ended?)", vim.log.levels.WARN)
      return
    end
    local pane = session.tmux_pane
    if not pane or pane == "" then
      vim.notify("atlas: no tmux pane recorded for this session", vim.log.levels.WARN)
      return
    end
    M.open_pane(pane, session_id)
  end)
end

--- Like open(), for a tmux pane directly (e.g. a Claude claude-status
--- doesn't know about). `key` is what the sidebar knows the row by
--- (session id or pane id), for jumping back to it; default: the pane.
function M.open_pane(pane, key)
  key = key or pane
  do
    -- Same session already showing: jump back into it, typing.
    if current and current.key == key and vim.api.nvim_buf_is_valid(current.buf) then
      local win = vim.fn.bufwinid(current.buf)
      if win ~= -1 then
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
        return
      end
    end

    stop_current()

    local view, view_err = create_view(pane)
    if not view then
      vim.notify("atlas: " .. view_err, vim.log.levels.ERROR)
      return
    end

    local win = find_main_window()
    if not win then
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_set_current_win(win)
    -- Set before the client starts, so its first size already accounts
    -- for the bar. [0] = local to this buffer in this window only.
    vim.wo[win][0].winbar = "%#Comment# " .. leave_key .. " back to sidebar  ·  i type  ·  q close (normal mode)"

    -- jobstart(term=true) runs in the current buffer. TMUX is unset so
    -- tmux allows a client inside a tmux-hosted Neovim.
    local job = vim.fn.jobstart({ "env", "-u", "TMUX", "tmux", "attach-session", "-t", sess(view) }, {
      term = true,
      on_exit = function()
        -- The client is gone (detached, killed, or the pane closed):
        -- don't leave the view session behind.
        tmux({ "kill-session", "-t", sess(view) })
        if current and current.buf == buf then
          current = nil
        end
      end,
    })
    if job <= 0 then
      tmux({ "kill-session", "-t", sess(view) })
      vim.notify("atlas: could not start tmux client", vim.log.levels.ERROR)
      return
    end

    current = { buf = buf, job = job, view = view, key = key }
    -- Straight into terminal mode: no `A`/`i` needed to start typing.
    vim.cmd("startinsert")

    vim.keymap.set("n", "q", stop_current, { buffer = buf, nowait = true, desc = "atlas: close session view" })
    vim.keymap.set({ "t", "n" }, leave_key, function()
      back_to_sidebar(key)
    end, { buffer = buf, nowait = true, desc = "atlas: back to the sidebar" })
    vim.api.nvim_create_autocmd("TermEnter", {
      buffer = buf,
      callback = function()
        refresh_client(view)
      end,
    })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, {
      buffer = buf,
      once = true,
      callback = function()
        if current and current.buf == buf then
          stop_current()
        end
      end,
    })
  end
end

return M
