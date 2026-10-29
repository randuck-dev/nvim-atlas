-- A real, interactive terminal onto a session's tmux pane, inside
-- Neovim: tmux is the backend, Neovim is the orchestration interface.
--
-- Output: a continuous `tmux pipe-pane` relay (through a fifo, read by
-- our own long-running `cat` job) forwards new bytes as they're
-- produced -- verified directly against a real pane that a single
-- continuous relay delivers everything written after it starts.
-- PLUS a periodic full resync (`capture-pane` snapshot + clear +
-- redraw, every few seconds): our local terminal emulator only
-- approximates the real pane's state from a snapshot, it isn't the
-- single source of truth the way tmux's own `attach` is, so complex
-- full-screen TUIs that do cursor-relative partial redraws (confirmed
-- directly against a real Claude Code session: fragments like
-- "pi.nvim_open_term(buf, {" showed up, meaning our copy had drifted
-- out of sync) can drift from reality over time. The periodic resync
-- bounds how bad that drift gets rather than letting it compound
-- forever; it doesn't eliminate the possibility, true frame-perfect
-- mirroring of an arbitrary TUI would need tmux's own control-mode
-- protocol, a materially bigger piece of work than this.
--
-- Input: nvim_open_term's on_input forwards whatever you type straight
-- into the real pane via `tmux send-keys -l`, so this is genuinely
-- interactive, not read-only.
--
-- Lives in the window next to the sidebar (taking over whatever buffer
-- was there), not a floating modal -- a normal buffer you switch into
-- and out of like any other.

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

-- capture-pane's text dump doesn't say where the cursor actually is, so
-- after writing it our local cursor lands wherever the content happened
-- to leave it -- not necessarily where the real pane's cursor is. The
-- live relay's bytes assume the correct position (that's what the real
-- program they came from assumed), so a mismatch here means every
-- cursor-relative update afterward renders at the wrong row/col.
-- Confirmed directly: tmux reports this via its own format variables.
local function get_cursor_pos(pane, cb)
  vim.system({ "tmux", "display-message", "-p", "-t", pane, "#{cursor_x} #{cursor_y}" }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        cb(nil, nil)
        return
      end
      local x, y = (result.stdout or ""):match("(%d+)%s+(%d+)")
      cb(tonumber(x), tonumber(y))
    end)
  end)
end
M._cursor_pos = get_cursor_pos

-- tmux's cursor_x/cursor_y are 0-indexed; CUP (\27[row;colH) is 1-indexed.
local function cup(x, y)
  return string.format("\27[%d;%dH", y + 1, x + 1)
end
M._cup = cup

-- Singleton: only one interactive peek is ever live at a time, so
-- switching sessions always tears the previous one down first (reader
-- job, tmux pipe-pane, fifo) rather than leaking any of them.
local current = nil -- { buf, win, chan, pane, fifo, reader }

--- The current peek's reader job handle (or nil) -- exposed for tests
--- to assert it actually gets killed when switching sessions.
function M._current_reader()
  return current and current.reader
end

local function stop_current()
  if not current then
    return
  end
  local c = current
  current = nil
  vim.system({ "tmux", "pipe-pane", "-t", c.pane })
  if c.reader then
    pcall(function()
      c.reader:kill(15)
    end)
  end
  if c.resync_timer and not c.resync_timer:is_closing() then
    c.resync_timer:stop()
    c.resync_timer:close()
  end
  vim.loop.fs_unlink(c.fifo)
end

--- Full resync: fresh capture-pane snapshot, clear, redraw. Used both
--- for the very first paint and periodically afterward to correct any
--- drift the live byte relay accumulates.
local function reseed(buf, chan, pane)
  capture_ansi(pane, function(text)
    if not current or current.buf ~= buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    local body = (text or ""):gsub("\n", "\r\n")
    vim.api.nvim_chan_send(chan, "\27[H\27[2J\27[3J" .. body)

    get_cursor_pos(pane, function(x, y)
      if not current or current.buf ~= buf or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if x and y then
        vim.api.nvim_chan_send(chan, cup(x, y))
      end
    end)
  end)
end
M._reseed = reseed

local function find_main_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.bo[b].filetype ~= "AtlasSidebar" then
      return win
    end
  end
  return nil
end

--- Resizes the real tmux pane to match the Neovim window showing it, so
--- TUI apps inside it wrap/render at the right width instead of
--- whatever size the pane happened to be when attached.
local function resize_pane_to_win(pane, win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local cols = vim.api.nvim_win_get_width(win)
  local rows = vim.api.nvim_win_get_height(win)
  vim.system({ "tmux", "resize-pane", "-t", pane, "-x", tostring(cols), "-y", tostring(rows) })
end

--- Opens a real interactive terminal onto session_id's tmux pane in the
--- window next to the sidebar (or a new vsplit if the sidebar is the
--- only window). Type into it (`i` to enter terminal mode, same as any
--- :terminal buffer) and it goes straight into the real pane. No-ops
--- (with a warning) if the session isn't live or has no recorded tmux
--- pane.
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

    stop_current()

    local win = find_main_window()
    local buf = vim.api.nvim_create_buf(false, true)
    local chan = vim.api.nvim_open_term(buf, {
      on_input = function(_, _, _, data_in)
        -- on_input fires once per keystroke, not batched. Independent
        -- async spawns here can complete out of order (confirmed: fast
        -- typing scrambled), so this blocks briefly (a few ms, a
        -- subprocess spawn) to keep keystrokes landing in order.
        vim.system({ "tmux", "send-keys", "-l", "-t", pane, "--", data_in }):wait()
      end,
    })

    if win then
      vim.api.nvim_win_set_buf(win, buf)
    else
      vim.cmd("vsplit")
      win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, buf)
    end
    vim.api.nvim_set_current_win(win)

    resize_pane_to_win(pane, win)

    local fifo = string.format("/tmp/atlas-peek-%s.fifo", string.format("%d", vim.loop.hrtime()))
    vim.loop.fs_unlink(fifo) -- in case a stale one from a previous crash exists
    vim.system({ "mkfifo", fifo }):wait()

    current = { buf = buf, win = win, chan = chan, pane = pane, fifo = fifo }

    -- Paint the current screen immediately, start the live relay for
    -- everything from this point on, and resync periodically to bound
    -- drift for TUIs that do complex partial/relative redraws.
    reseed(buf, chan, pane)

    current.reader = vim.system({ "cat", fifo }, {
      stdout = function(_, chunk)
        if chunk and current and current.buf == buf then
          vim.schedule(function()
            if vim.api.nvim_buf_is_valid(buf) then
              vim.api.nvim_chan_send(chan, chunk)
            end
          end)
        end
      end,
    })

    vim.system({ "tmux", "pipe-pane", "-o", "-t", pane, "cat > " .. fifo })

    local resync_timer = vim.uv.new_timer()
    current.resync_timer = resync_timer
    resync_timer:start(
      3000,
      3000,
      vim.schedule_wrap(function()
        if current and current.buf == buf then
          reseed(buf, chan, pane)
        end
      end)
    )

    vim.keymap.set("n", "q", stop_current, { buffer = buf, nowait = true, desc = "atlas: close interactive peek" })
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWinLeave" }, {
      buffer = buf,
      once = true,
      callback = function()
        if current and current.buf == buf then
          stop_current()
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinResized", {
      callback = function()
        if current and current.buf == buf and vim.tbl_contains(vim.v.event.windows, win) then
          resize_pane_to_win(pane, win)
        end
      end,
    })
  end)
end

return M
