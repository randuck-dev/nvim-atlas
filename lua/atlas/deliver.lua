-- Getting pending notes out of atlas and into a hub session, via tmux
-- send-keys into the pane claude-status already tracks per session —
-- not an in-Neovim-terminal mechanism, because hub sessions actually run
-- as plain tmux windows (bin/tmux-wt-spawn.sh), not inside Neovim.
--
-- Multi-line messages MUST be wrapped in bracketed-paste escapes
-- (\x1b[200~ ... \x1b[201~) before sending. Verified directly against a
-- real tmux pane: without the wrapping, embedded newlines get executed
-- as separate shell commands (one line even errored as a stray `cd`) —
-- with it, the whole block lands intact and unexecuted, like a real
-- terminal paste. This is not optional.

local data = require("atlas.data")
local annotate = require("atlas.annotate")

local M = {}

local BRACKETED_PASTE_START = "\27[200~"
local BRACKETED_PASTE_END = "\27[201~"

--- The formatted note block for `session_id`'s pending notes on
--- `worktree_path` ("## <label>\n- file:line: text\n..."), or nil if
--- there are none.
function M.format_for_worktree(session_id, worktree_path, label)
  local notes = vim.tbl_filter(function(a)
    return a.worktree == worktree_path
  end, annotate.load(session_id))

  if #notes == 0 then
    return nil
  end

  local lines = { "## " .. (label or worktree_path) }
  for _, n in ipairs(notes) do
    local where = n.line_start == n.line_end and (n.file .. ":" .. n.line_start)
      or string.format("%s:%d-%d", n.file, n.line_start, n.line_end)
    lines[#lines + 1] = string.format("- %s: %s", where, n.text)
  end
  return table.concat(lines, "\n")
end

--- Copies `session_id`'s pending notes on `worktree_path` to the system
--- clipboard (register "+"), formatted and ready to paste into the hub
--- session by hand. Doesn't clear the notes (clearing happens on an
--- actual confirmed send, not a copy that may or may not get pasted).
function M.copy_for_worktree(session_id, worktree_path, label)
  local text = M.format_for_worktree(session_id, worktree_path, label)
  if not text then
    vim.notify("atlas: no pending notes for this worktree", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("atlas: copied notes to clipboard — paste into the session", vim.log.levels.INFO)
end

--- Sends `text` into tmux pane `pane` as a single pasted block, bracketed
--- so embedded newlines land as literal content instead of getting
--- executed line-by-line (verified directly: without this, each line
--- runs as a separate command). Does not submit it.
local function tmux_paste(pane, text)
  local result = vim.system(
    { "tmux", "send-keys", "-l", "-t", pane, BRACKETED_PASTE_START .. text .. BRACKETED_PASTE_END },
    { text = true }
  ):wait()
  if result.code ~= 0 then
    return false, vim.trim(result.stderr or "")
  end
  return true, nil
end
M._tmux_paste = tmux_paste

--- Presses a real Enter in tmux pane `pane`, submitting whatever's there.
local function tmux_submit(pane)
  local result = vim.system({ "tmux", "send-keys", "-t", pane, "Enter" }, { text = true }):wait()
  if result.code ~= 0 then
    return false, vim.trim(result.stderr or "")
  end
  return true, nil
end

--- Pastes `text` into `pane` and submits it. Synchronous: these are
--- fast, local, user-triggered tmux calls, not something polled in a loop.
local function tmux_send(pane, text)
  local ok, err = tmux_paste(pane, text)
  if not ok then
    return false, err
  end
  return tmux_submit(pane)
end

--- Sends all of `session_id`'s pending notes, across every worktree it
--- has pending notes on, into its tmux pane as one message (grouped by
--- worktree), and clears them on success. Re-fetches session/touched
--- data fresh rather than trusting whatever the sidebar last rendered.
--- Calls `cb(ok)` when done.
function M.send(session_id, cb)
  cb = cb or function() end

  data.sessions(function(sessions, err)
    if err then
      vim.notify("atlas: " .. err, vim.log.levels.ERROR)
      cb(false)
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
      cb(false)
      return
    end
    if not session.tmux_pane or session.tmux_pane == "" then
      vim.notify("atlas: no tmux pane recorded for this session", vim.log.levels.WARN)
      cb(false)
      return
    end

    data.touched(function(touched, terr)
      if terr then
        vim.notify("atlas: " .. terr, vim.log.levels.ERROR)
        cb(false)
        return
      end

      local entry
      for _, t in ipairs(touched) do
        if t.session_id == session_id then
          entry = t
        end
      end
      local paths = entry and vim.tbl_keys(entry.paths) or {}
      table.sort(paths)

      local blocks = {}
      for _, path in ipairs(paths) do
        local block = M.format_for_worktree(session_id, path, vim.fn.fnamemodify(path, ":t"))
        if block then
          blocks[#blocks + 1] = { path = path, text = block }
        end
      end

      if #blocks == 0 then
        vim.notify("atlas: no pending notes to send", vim.log.levels.WARN)
        cb(false)
        return
      end

      local message = table.concat(
        vim.tbl_map(function(b)
          return b.text
        end, blocks),
        "\n\n"
      )

      local ok, send_err = tmux_send(session.tmux_pane, message)
      if not ok then
        vim.notify("atlas: failed to send: " .. send_err, vim.log.levels.ERROR)
        cb(false)
        return
      end

      for _, b in ipairs(blocks) do
        annotate.clear_for(session_id, b.path)
      end
      vim.notify(string.format("atlas: sent notes for %d worktree(s)", #blocks), vim.log.levels.INFO)
      cb(true)
    end)
  end)
end

return M
