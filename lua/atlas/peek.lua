-- Read-only, near-live view of a session's tmux pane inside Neovim.
--
-- Deliberately `tmux capture-pane` on a timer, not full control-mode RPC
-- (`tmux -CC`): capture-pane gives the pane's current *rendered* screen,
-- not a byte-level event stream, which is all a "what's this session
-- doing" peek needs. With `-e` it keeps the real ANSI color codes, fed
-- into a Neovim-native terminal buffer (`nvim_open_term`) so the peek
-- shows the session's actual colors rather than flat text.
--
-- Lives in the window next to the sidebar (taking over whatever buffer
-- was there), not a floating modal -- it's meant to be a normal buffer
-- you can focus on, not an overlay.

local data = require("atlas.data")

local M = {}

local function capture_ansi(pane, cb)
  vim.system({ "tmux", "capture-pane", "-e", "-p", "-t", pane }, { text = true }, function(result)
    vim.schedule(function()
      cb(result.code == 0 and (result.stdout or "") or nil)
    end)
  end)
end
M._capture = capture_ansi

-- Singleton: only one peek is ever live at a time, so re-pressing <CR>
-- on a (same or different) session doesn't leak timers/terminals.
local current = nil -- { buf, win, chan, timer, session_id }

--- The current peek's timer (or nil), for tests to assert it actually
--- stopped when switching to a different session.
function M._current_timer()
  return current and current.timer
end

local function stop_current()
  if not current then
    return
  end
  if current.timer and not current.timer:is_closing() then
    current.timer:stop()
    current.timer:close()
  end
  current = nil
end

local function find_main_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].filetype ~= "AtlasSidebar" then
      return win
    end
  end
  return nil
end

--- Opens a peek at session_id's tmux pane in the window next to the
--- sidebar (or a new vsplit if the sidebar is the only window),
--- refreshed every second with real ANSI colors until the buffer is
--- hidden/closed or another peek replaces it. No-ops (with a warning)
--- if the session isn't live or has no recorded tmux pane.
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
    if not session.tmux_pane or session.tmux_pane == "" then
      vim.notify("atlas: no tmux pane recorded for this session", vim.log.levels.WARN)
      return
    end

    stop_current()

    local win = find_main_window()
    local buf = vim.api.nvim_create_buf(false, true)
    local chan = vim.api.nvim_open_term(buf, {})

    if win then
      vim.api.nvim_win_set_buf(win, buf)
    else
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
    vim.api.nvim_set_current_win(win)

    current = { buf = buf, win = win, chan = chan, session_id = session_id }

    local function refresh()
      if not current or current.buf ~= buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      capture_ansi(session.tmux_pane, function(text)
        if not current or current.buf ~= buf or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        -- \27[2J alone only erases the visible screen, not scrollback —
        -- confirmed directly: the buffer grew by a few lines every tick
        -- even with byte-for-byte identical content, which is exactly
        -- the "one line trickles in, old content scrolls away" symptom.
        -- \27[3J (the same sequence the real `clear` command sends)
        -- erases scrollback too, so each snapshot truly replaces the
        -- last one instead of piling up.
        local body = (text or "(pane gone)"):gsub("\n", "\r\n")
        vim.api.nvim_chan_send(chan, "\27[H\27[2J\27[3J" .. body)
      end)
    end

    refresh()
    local timer = vim.uv.new_timer()
    current.timer = timer
    timer:start(1000, 1000, vim.schedule_wrap(refresh))

    vim.keymap.set("n", "q", stop_current, { buffer = buf, nowait = true, desc = "atlas: stop peek refresh" })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWinLeave" }, {
      buffer = buf,
      once = true,
      callback = function()
        if current and current.buf == buf then
          stop_current()
        end
      end,
    })
  end)
end

return M
