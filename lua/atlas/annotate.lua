-- Notes left on a worktree's diff while reviewing it, persisted per
-- session so the sidebar can show a pending count and deliver.lua
-- (later) can send them into the hub session.

local review = require("atlas.review")

local M = {}

-- Notes are shown as diagnostics in their own namespace, displayed as
-- virtual lines under the line they're on (plus a gutter sign). That
-- display is configured for this namespace only, so it doesn't touch
-- how LSP diagnostics look; ]d/[d and diagnostic lists see notes too.
local ns = vim.api.nvim_create_namespace("atlas_annotations")
M.ns = ns
local configured = false
local function ensure_config()
  if configured then
    return
  end
  configured = true
  vim.diagnostic.config({
    virtual_lines = true,
    virtual_text = false,
    underline = false,
    signs = { text = { [vim.diagnostic.severity.HINT] = "✎" } },
    update_in_insert = false,
  }, ns)
end

--- Shows notes in `bufnr` as diagnostics below their lines.
--- `items` = { { lnum (0-indexed), end_lnum (0-indexed), text } }.
function M.show(bufnr, items)
  ensure_config()
  local diags = {}
  for _, it in ipairs(items) do
    diags[#diags + 1] = {
      lnum = it[1],
      end_lnum = it[2],
      col = 0,
      severity = vim.diagnostic.severity.HINT,
      source = "atlas",
      message = "note: " .. it[3],
    }
  end
  vim.diagnostic.set(ns, bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr, diags)
end

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

--- Shows session_id's pending notes on worktree_path/file in bufnr
--- (0 = current) as diagnostics below their first line, replacing what
--- was shown before. One per note, however many lines it covers.
function M.render_inline(bufnr, session_id, worktree_path, file)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local items = {}
  for _, n in ipairs(M.load(session_id)) do
    if n.worktree == worktree_path and n.file == file then
      local l1 = math.min((n.line_start or 1) - 1, line_count - 1)
      local l2 = math.min((n.line_end or n.line_start or 1) - 1, line_count - 1)
      if l1 >= 0 then
        items[#items + 1] = { l1, l2, n.text }
      end
    end
  end
  M.show(bufnr, items)
end

--- Re-renders inline notes for whatever file is current in the
--- enclosing atlas review tab, using whichever buffer is passed (default
--- current). No-ops outside an atlas review tab, same as M.add().
function M.refresh_inline(bufnr)
  local ctx = review.context()
  if not ctx then
    return
  end
  local file = current_file()
  if not file then
    return
  end
  M.render_inline(bufnr or 0, ctx.session_id, ctx.path, file)
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

  line1 = line1 or vim.api.nvim_win_get_cursor(0)[1]
  line2 = line2 or line1
  if line1 > line2 then
    line1, line2 = line2, line1
  end

  -- In the unified review, buffer lines aren't file lines: atlas's own
  -- row map turns them into a file and its (new) line numbers.
  local unified = require("atlas.unified")
  local file
  if unified.is_unified(0) then
    file, line1, line2 = unified.resolve(0, line1, line2)
    if not file then
      vim.notify("atlas: put the cursor on a line of a file's diff", vim.log.levels.WARN)
      return
    end
  else
    file = current_file()
    if not file then
      vim.notify("atlas: couldn't resolve the current file in diffview", vim.log.levels.WARN)
      return
    end
  end

  local where = line1 == line2 and (file .. ":" .. line1) or string.format("%s:%d-%d", file, line1, line2)
  vim.ui.input({ prompt = "Note on " .. where .. ": " }, function(text)
    if not text or text == "" then
      return
    end
    M.record(ctx.session_id, { worktree = ctx.path, file = file, line_start = line1, line_end = line2, text = text })
    if unified.is_unified(0) then
      unified.render_notes(0)
    else
      M.render_inline(0, ctx.session_id, ctx.path, file)
    end
    vim.notify("atlas: note added", vim.log.levels.INFO)
  end)
end

return M
