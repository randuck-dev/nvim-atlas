-- User-named sections ("to deploy", "observability", ...) that sessions
-- can be moved into, for organising work beyond "which repo is it in".
-- Persisted in stdpath("state")/nvim-atlas/sections.json as
-- { sections = { name, ... } (display order), assign = { [session_id] = name } }.

local M = {}

local path_override = nil

local function path()
  return path_override or (vim.fn.stdpath("state") .. "/nvim-atlas/sections.json")
end

--- For tests: store somewhere else (nil restores the default).
function M._set_path(p)
  path_override = p
end

function M.load()
  local p = path()
  if vim.fn.filereadable(p) == 0 then
    return { sections = {}, assign = {} }
  end
  local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(p), "\n"))
  if not ok or type(data) ~= "table" then
    return { sections = {}, assign = {} }
  end
  data.sections = type(data.sections) == "table" and data.sections or {}
  data.assign = type(data.assign) == "table" and data.assign or {}
  -- An empty JSON object decodes as an empty list; both mean "none".
  if vim.islist(data.assign) then
    data.assign = {}
  end
  return data
end

local function save(data)
  vim.fn.mkdir(vim.fn.fnamemodify(path(), ":h"), "p")
  local assign = next(data.assign) and data.assign or vim.empty_dict()
  vim.fn.writefile({ vim.json.encode({ sections = data.sections, assign = assign }) }, path())
end

local function index_of(list, name)
  for i, n in ipairs(list) do
    if n == name then
      return i
    end
  end
end

--- Section names in display order.
function M.list()
  return M.load().sections
end

--- Section a session is in, or nil.
function M.section_of(session_id)
  local data = M.load()
  local name = data.assign[session_id]
  if name and index_of(data.sections, name) then
    return name
  end
  return nil
end

--- Adds a section (no-op if it exists). Returns ok, err.
function M.add(name)
  name = vim.trim(name or "")
  if name == "" then
    return false, "section name can't be empty"
  end
  local data = M.load()
  if not index_of(data.sections, name) then
    table.insert(data.sections, name)
    save(data)
  end
  return true
end

--- Renames a section, keeping its sessions in it. Returns ok, err.
function M.rename(old, new)
  new = vim.trim(new or "")
  if new == "" then
    return false, "section name can't be empty"
  end
  local data = M.load()
  local i = index_of(data.sections, old)
  if not i then
    return false, "no section named " .. old
  end
  if new ~= old and index_of(data.sections, new) then
    return false, "a section named " .. new .. " already exists"
  end
  data.sections[i] = new
  for sid, name in pairs(data.assign) do
    if name == old then
      data.assign[sid] = new
    end
  end
  save(data)
  return true
end

--- Deletes a section; its sessions go back to having none.
function M.remove(name)
  local data = M.load()
  local i = index_of(data.sections, name)
  if i then
    table.remove(data.sections, i)
  end
  for sid, n in pairs(data.assign) do
    if n == name then
      data.assign[sid] = nil
    end
  end
  save(data)
end

--- Puts a session in a section (creating it if needed), or takes it out
--- of any section when `name` is nil.
function M.assign(session_id, name)
  local data = M.load()
  if name then
    if not index_of(data.sections, name) then
      table.insert(data.sections, name)
    end
    data.assign[session_id] = name
  else
    data.assign[session_id] = nil
  end
  save(data)
end

return M
