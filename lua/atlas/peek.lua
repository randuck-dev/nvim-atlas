-- Read-only, near-live view of a session's tmux pane inside Neovim.
--
-- Deliberately `tmux capture-pane` on a timer, not full control-mode RPC
-- (`tmux -CC`): capture-pane gives the pane's current *rendered* screen
-- as clean text (verified directly: a real Claude Code pane came
-- through perfectly readable, no escape codes), which is all a "what's
-- this session doing" peek needs. Control-mode streams the raw
-- terminal byte stream instead (cursor moves, colors, redraws) -- making
-- that readable would mean writing a small terminal emulator, for no
-- benefit here.

local data = require("atlas.data")

local M = {}

local function capture(pane, cb)
  vim.system({ "tmux", "capture-pane", "-t", pane, "-p" }, { text = true }, function(result)
    vim.schedule(function()
      cb(result.code == 0 and (result.stdout or "") or nil)
    end)
  end)
end
M._capture = capture

--- Opens a floating window peeking at session_id's tmux pane, refreshed
--- every second until the window is closed (`q` or any other close).
--- No-ops (with a warning) if the session isn't live or has no recorded
--- tmux pane.
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

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "AtlasPeek"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false

    local width = math.floor(vim.o.columns * 0.8)
    local height = math.floor(vim.o.lines * 0.8)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      col = math.floor((vim.o.columns - width) / 2),
      row = math.floor((vim.o.lines - height) / 2),
      style = "minimal",
      border = "rounded",
      title = " " .. (session.title ~= "" and session.title or session.session_id) .. " (live, q to close) ",
      title_pos = "center",
    })

    local function refresh()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      capture(session.tmux_pane, function(text)
        if not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local lines = vim.split(text or "(pane gone)", "\n", { plain = true })
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
      end)
    end

    refresh()
    local timer = vim.uv.new_timer()
    timer:start(1000, 1000, vim.schedule_wrap(refresh))

    local stopped = false
    local function stop()
      if stopped then
        return
      end
      stopped = true
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end

    vim.keymap.set("n", "q", function()
      stop()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, desc = "atlas: close peek" })

    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(win),
      once = true,
      callback = stop,
    })
  end)
end

return M
