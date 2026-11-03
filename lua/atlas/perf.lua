-- Where atlas spends time and CPU, always on and cheap (a clock read and
-- a few table updates per event), so when the fan spins up you can ask
-- a running Neovim with :AtlasStats instead of reproducing it first.
--
-- Three things are tracked since start (or the last reset):
--   * every process atlas starts, by command ("git status",
--     "claude-status touched", ...): how many, wall time, failures, and
--     how many git calls failed on a lock;
--   * Lua work on Neovim's main thread (rendering, scans), which is what
--     makes Neovim itself busy;
--   * CPU: Neovim's own, and that of its exited child processes
--     (everything they started too, e.g. the jq calls inside
--     claude-status). Children include non-atlas ones (LSP servers that
--     exited, other plugins' jobs), so compare with the process table.
--
-- All of atlas starts processes through M.system, which also sets
-- GIT_OPTIONAL_LOCKS=0: background reads like `git status` then never
-- take .git/index.lock, so they can't make a `git add`/`commit` that
-- Claude runs at the same moment fail with "index.lock: File exists".

local uv = vim.uv

local M = {}

local started -- uv.hrtime() at start/reset
local cpu_start -- { self, children } CPU seconds at start/reset
local procs -- label -> { n, ns, max, fail, lock }
local lua -- name -> { n, ns, max }
local running, peak, lock_fails, spawn_fails

-- CPU seconds of this process (main thread and libuv threads).
local function self_cpu()
  local r = uv.getrusage()
  return r.utime.sec + r.utime.usec / 1e6 + r.stime.sec + r.stime.usec / 1e6
end

-- CPU seconds of exited child processes (and theirs), via getrusage
-- (RUSAGE_CHILDREN) through LuaJIT's FFI; nil without it. The struct
-- starts with two timevals: 8-byte seconds, then microseconds (4 bytes
-- plus padding on macOS, 8 on Linux: the low 4 bytes on little-endian
-- are the same value). The asm alias avoids clashing with another
-- plugin's own getrusage declaration.
local children_cpu = (function()
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return function()
      return nil
    end
  end
  local declared = pcall(
    ffi.cdef,
    [[
      typedef struct { int64_t sec; int32_t usec; int32_t pad_; } atlas_timeval;
      typedef struct { atlas_timeval utime; atlas_timeval stime; int64_t rest[16]; } atlas_rusage;
      int atlas_getrusage(int who, atlas_rusage *usage) __asm__("getrusage");
    ]]
  )
  if not declared then
    return function()
      return nil
    end
  end
  local buf = ffi.new("atlas_rusage")
  return function()
    if ffi.C.atlas_getrusage(-1, buf) ~= 0 then
      return nil
    end
    return tonumber(buf.utime.sec) + buf.utime.usec / 1e6 + tonumber(buf.stime.sec) + buf.stime.usec / 1e6
  end
end)()

function M.reset()
  started = uv.hrtime()
  cpu_start = { self = self_cpu(), children = children_cpu() }
  procs, lua = {}, {}
  running, peak, lock_fails, spawn_fails = 0, 0, 0, 0
end
M.reset()

--- A short name for a command line: the program plus its subcommand,
--- e.g. "git status", "claude-status json", "gh pr list".
function M.label(cmd)
  local prog = vim.fs.basename(cmd[1] or "?")
  local i = 2
  if prog == "env" then
    -- env [-u NAME]... prog args
    while cmd[i] == "-u" do
      i = i + 2
    end
    prog = vim.fs.basename(cmd[i] or "?")
    i = i + 1
  end
  if prog == "git" then
    -- Skip global options: -C <dir>, -c <k=v>, --flags.
    while cmd[i] do
      if cmd[i] == "-C" or cmd[i] == "-c" then
        i = i + 2
      elseif cmd[i]:sub(1, 1) == "-" then
        i = i + 1
      else
        break
      end
    end
  end
  local sub = cmd[i]
  if prog == "gh" and cmd[i + 1] then
    sub = sub .. " " .. cmd[i + 1]
  end
  return sub and (prog .. " " .. sub) or prog
end

local function record(label, t0, res)
  local ns = uv.hrtime() - t0
  running = running - 1
  local p = procs[label]
  if not p then
    p = { n = 0, ns = 0, max = 0, fail = 0, lock = 0 }
    procs[label] = p
  end
  p.n = p.n + 1
  p.ns = p.ns + ns
  p.max = math.max(p.max, ns)
  if res.code ~= 0 then
    p.fail = p.fail + 1
    local err = type(res.stderr) == "string" and res.stderr or ""
    if err:find("index.lock", 1, true) or err:find("%.lock'?: File exists") then
      p.lock = p.lock + 1
      lock_fails = lock_fails + 1
    end
  end
end

--- vim.system, recorded. Same arguments and return value, so `:wait()`
--- works as before. Sets GIT_OPTIONAL_LOCKS=0 (see the top of the file).
function M.system(cmd, opts, on_exit)
  opts = vim.deepcopy(opts or {})
  opts.env = vim.tbl_extend("keep", opts.env or {}, { GIT_OPTIONAL_LOCKS = "0" })
  local label = M.label(cmd)
  local t0 = uv.hrtime()
  running = running + 1
  peak = math.max(peak, running)
  -- Runs in a fast (libuv) context: plain Lua only, no API calls.
  local ok, obj = pcall(vim.system, cmd, opts, function(res)
    record(label, t0, res)
    if on_exit then
      on_exit(res)
    end
  end)
  if not ok then
    running = running - 1
    spawn_fails = spawn_fails + 1
    error(obj, 0)
  end
  return obj
end

--- Runs fn(...) and records its time on the main thread under `name`.
--- Returns what fn returns; errors pass through (and still count).
function M.measure(name, fn, ...)
  local t0 = uv.hrtime()
  local res = vim.F.pack_len(pcall(fn, ...))
  local ns = uv.hrtime() - t0
  local s = lua[name]
  if not s then
    s = { n = 0, ns = 0, max = 0 }
    lua[name] = s
  end
  s.n = s.n + 1
  s.ns = s.ns + ns
  s.max = math.max(s.max, ns)
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2, res.n)
end

--- Counts an event without timing it (e.g. a poll tick).
function M.count(name)
  local s = lua[name]
  if not s then
    s = { n = 0, ns = 0, max = 0 }
    lua[name] = s
  end
  s.n = s.n + 1
end

--- Everything recorded so far, as plain data (for tests and scripts).
function M.snapshot()
  local elapsed = (uv.hrtime() - started) / 1e9
  local child = children_cpu()
  return {
    elapsed = elapsed,
    cpu_self = self_cpu() - cpu_start.self,
    cpu_children = child and cpu_start.children and (child - cpu_start.children) or nil,
    running = running,
    peak = peak,
    lock_fails = lock_fails,
    spawn_fails = spawn_fails,
    procs = vim.deepcopy(procs),
    lua = vim.deepcopy(lua),
  }
end

local function ms(ns)
  return ns / 1e6
end

local function pct(cpu, elapsed)
  return elapsed > 0 and string.format("%5.1f%%", 100 * cpu / elapsed) or "  -  "
end

local function duration(s)
  if s < 60 then
    return string.format("%ds", s)
  end
  return string.format("%dm%02ds", math.floor(s / 60), math.floor(s % 60))
end

--- The report :AtlasStats shows, as lines.
function M.report()
  local s = M.snapshot()
  local per_min = 60 / math.max(s.elapsed, 1e-3)
  local total_procs = 0
  for _, p in pairs(s.procs) do
    total_procs = total_procs + p.n
  end

  local out = {
    "atlas stats  (last " .. duration(s.elapsed) .. "; r refresh, R reset, q close)",
    "",
    "CPU, as % of one core:",
    "  Neovim itself       " .. pct(s.cpu_self, s.elapsed) .. "   (Lua below, rendering, libuv)",
    "  exited children     "
      .. (s.cpu_children and pct(s.cpu_children, s.elapsed) or "  n/a ")
      .. "   (git, claude-status and its jq calls, gh...; includes non-atlas children)",
    "",
    string.format(
      "Processes started: %d (%.0f/min), %d running now, at most %d at once",
      total_procs,
      total_procs * per_min,
      s.running,
      s.peak
    ),
  }
  if s.lock_fails > 0 then
    out[#out + 1] = string.format("  %d git call(s) failed on a lock (.git/index.lock)", s.lock_fails)
  end
  if s.spawn_fails > 0 then
    out[#out + 1] = string.format("  %d could not be started", s.spawn_fails)
  end

  local plist = {}
  for label, p in pairs(s.procs) do
    plist[#plist + 1] = vim.tbl_extend("force", { label = label }, p)
  end
  table.sort(plist, function(a, b)
    return a.ns > b.ns
  end)
  if #plist > 0 then
    out[#out + 1] = ""
    out[#out + 1] = string.format("  %-28s %7s %7s %8s %8s %6s", "command", "runs", "/min", "avg ms", "max ms", "failed")
    for _, p in ipairs(plist) do
      out[#out + 1] = string.format(
        "  %-28s %7d %7.0f %8.1f %8.1f %6s",
        p.label:sub(1, 28),
        p.n,
        p.n * per_min,
        ms(p.ns) / p.n,
        ms(p.max),
        p.fail > 0 and (p.fail .. (p.lock > 0 and (" (" .. p.lock .. " lock)") or "")) or ""
      )
    end
  end

  local llist = {}
  for name, l in pairs(s.lua) do
    llist[#llist + 1] = vim.tbl_extend("force", { name = name }, l)
  end
  table.sort(llist, function(a, b)
    return a.ns > b.ns
  end)
  if #llist > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Lua on Neovim's main thread (blocks typing while it runs):"
    out[#out + 1] = string.format("  %-28s %7s %7s %8s %8s %8s", "what", "calls", "/min", "total s", "avg ms", "max ms")
    for _, l in ipairs(llist) do
      out[#out + 1] = string.format(
        "  %-28s %7d %7.0f %8.2f %8.2f %8.1f",
        l.name:sub(1, 28),
        l.n,
        l.n * per_min,
        l.ns / 1e9,
        l.n > 0 and ms(l.ns) / l.n or 0,
        ms(l.max)
      )
    end
  end
  return out
end

-- :AtlasStats: the report in a scratch window, refreshed every 2s
-- while it's showing.
local stats_buf, stats_timer

local function draw()
  if not (stats_buf and vim.api.nvim_buf_is_valid(stats_buf)) then
    return
  end
  vim.bo[stats_buf].modifiable = true
  vim.api.nvim_buf_set_lines(stats_buf, 0, -1, false, M.report())
  vim.bo[stats_buf].modifiable = false
end

local function stop_timer()
  if stats_timer and not stats_timer:is_closing() then
    stats_timer:stop()
    stats_timer:close()
  end
  stats_timer = nil
end

function M.open()
  if not (stats_buf and vim.api.nvim_buf_is_valid(stats_buf)) then
    stats_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[stats_buf].bufhidden = "wipe"
    vim.bo[stats_buf].filetype = "AtlasStats"
    local function map(lhs, fn)
      vim.keymap.set("n", lhs, fn, { buffer = stats_buf, nowait = true })
    end
    map("q", "<cmd>close<cr>")
    map("r", draw)
    map("R", function()
      M.reset()
      draw()
    end)
    vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, { buffer = stats_buf, callback = stop_timer })
  end
  local win = vim.fn.bufwinid(stats_buf)
  if win == -1 then
    vim.cmd("botright 30split")
    vim.api.nvim_win_set_buf(0, stats_buf)
  else
    vim.api.nvim_set_current_win(win)
  end
  draw()
  stop_timer()
  stats_timer = uv.new_timer()
  stats_timer:start(2000, 2000, vim.schedule_wrap(draw))
end

return M
