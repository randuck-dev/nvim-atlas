-- Notes left on a worktree's diff while reviewing it, persisted per
-- session so the sidebar can show a pending count and deliver.lua
-- (later) can send them into the hub session.

local review = require("atlas.review")

local M = {}

local function annotations_path(session_id)
  local dir = vim.fn.stdpath("state") .. "/nvim-atlas/annotations"
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. session_id .. ".json"
end

--- All pending annotations for `session_id`:
--- {worktree, file, line_start, line_end, text, created}[].
function M.load(session_id)
  local path = annotations_path(session_id)
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function save(session_id, list)
  vim.fn.writefile({ vim.json.encode(list) }, annotations_path(session_id))
end

--- Appends `entry` ({worktree, file, line, text}) to session_id's pending
--- annotations and persists them. Pure data op, no UI.
function M.record(session_id, entry)
  local list = M.load(session_id)
  entry = vim.tbl_extend("force", { created = os.time() }, entry)
  table.insert(list, entry)
  save(session_id, list)
  return list
end

--- How many of session_id's pending annotations are on `worktree_path`.
function M.pending_for(session_id, worktree_path)
  local n = 0
  for _, a in ipairs(M.load(session_id)) do
    if a.worktree == worktree_path then
      n = n + 1
    end
  end
  return n
end

--- Clears all pending annotations for `session_id` on `worktree_path`
--- (used once they've been delivered).
function M.clear_for(session_id, worktree_path)
  local list = vim.tbl_filter(function(a)
    return a.worktree ~= worktree_path
  end, M.load(session_id))
  save(session_id, list)
end

local function current_file()
  local ok, lib = pcall(require, "diffview.lib")
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if not view or not view.infer_cur_file then
    return nil
  end
  local entry = view:infer_cur_file()
  return entry and entry.path or nil
end

--- Prompts for a note on the current diffview file, over lines
--- `line1`-`line2` (pass the same value twice for a single line), and
--- records it against the enclosing atlas review tab's worktree. Meant
--- to be driven by a range-aware command/keymap (see init.lua) so a
--- visual selection becomes the range directly — select with `V`, extend
--- with `j`, hit the keymap, type the note, `<CR>`, select the next bit
--- and repeat. No-ops (with a warning) outside an atlas review tab, or
--- when the current file can't be resolved from diffview.
function M.add(line1, line2)
  local ctx = review.context()
  if not ctx then
    vim.notify("atlas: not in an atlas review tab", vim.log.levels.WARN)
    return
  end

  local file = current_file()
  if not file then
    vim.notify("atlas: couldn't resolve the current file in diffview", vim.log.levels.WARN)
    return
  end

  line1 = line1 or vim.api.nvim_win_get_cursor(0)[1]
  line2 = line2 or line1
  if line1 > line2 then
    line1, line2 = line2, line1
  end

  local where = line1 == line2 and (file .. ":" .. line1) or string.format("%s:%d-%d", file, line1, line2)
  vim.ui.input({ prompt = "Note on " .. where .. ": " }, function(text)
    if not text or text == "" then
      return
    end
    M.record(ctx.session_id, { worktree = ctx.path, file = file, line_start = line1, line_end = line2, text = text })
    vim.notify("atlas: note added", vim.log.levels.INFO)
  end)
end

return M
