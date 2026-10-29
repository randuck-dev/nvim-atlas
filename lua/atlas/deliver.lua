-- Getting pending notes out of atlas and into a hub session. For now
-- that's entirely "copy a formatted summary to the clipboard, paste it
-- yourself" — deliberately the whole of delivery until it's decided how
-- (or whether) Neovim should drive the hub session's terminal directly.
-- That's a real workflow question, not just plumbing: today hub
-- sessions run as plain tmux windows (bin/tmux-wt-spawn.sh), not inside
-- Neovim, so an in-Neovim-terminal delivery mechanism would mean
-- changing how hub sessions get started, not just how notes get sent.

local annotate = require("atlas.annotate")

local M = {}

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
--- session. Notifies either way; doesn't clear the notes (clearing
--- happens once there's an actual send to confirm against, not a copy
--- that may or may not get pasted anywhere).
function M.copy_for_worktree(session_id, worktree_path, label)
  local text = M.format_for_worktree(session_id, worktree_path, label)
  if not text then
    vim.notify("atlas: no pending notes for this worktree", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg("+", text)
  vim.notify("atlas: copied notes to clipboard — paste into the session", vim.log.levels.INFO)
end

return M
