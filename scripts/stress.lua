-- Driver for scripts/stress.sh, run as `nvim --headless --clean -l`.
-- Opens the sidebar (with "All sessions" unfolded) on the fixture the
-- shell script built, lets it poll for ATLAS_STRESS_SECONDS, then
-- prints the :AtlasStats report and how long Neovim stalled.

vim.opt.rtp:prepend(vim.env.ATLAS_STRESS_PLUGIN)
local seconds = tonumber(vim.env.ATLAS_STRESS_SECONDS) or 60

-- Collect notifications instead of printing them as they come.
local notes = {}
vim.notify = function(msg, level)
  notes[#notes + 1] = { msg = tostring(msg), level = level or vim.log.levels.INFO }
end

require("atlas").setup({ bin_dir = vim.env.ATLAS_STRESS_BIN_DIR })
local has_perf, perf = pcall(require, "atlas.perf")
require("atlas.sections").set_expanded("all", true)
if has_perf then
  perf.reset()
end
vim.cmd("AtlasToggle")

-- Stalls: a 20ms timer that notes how late it fires. A late tick means
-- the main thread was busy, i.e. typing would have lagged that long.
local interval = 20
local stalls = { max = 0, over_50 = 0, over_200 = 0 }
local last = vim.uv.hrtime()
local probe = vim.uv.new_timer()
probe:start(
  interval,
  interval,
  vim.schedule_wrap(function()
    local now = vim.uv.hrtime()
    local late = (now - last) / 1e6 - interval
    last = now
    stalls.max = math.max(stalls.max, late)
    if late > 50 then
      stalls.over_50 = stalls.over_50 + 1
    end
    if late > 200 then
      stalls.over_200 = stalls.over_200 + 1
    end
  end)
)

vim.wait(seconds * 1000, function()
  return false
end, 50)
probe:stop()
probe:close()

local out = {}
if has_perf then
  vim.list_extend(out, perf.report())
else
  local r = vim.uv.getrusage()
  out[#out + 1] = "(no atlas.perf in this checkout: only the outside totals below)"
  out[#out + 1] = string.format("Neovim itself: %.1fs CPU", r.utime.sec + r.utime.usec / 1e6 + r.stime.sec + r.stime.usec / 1e6)
end
out[#out + 1] = ""
out[#out + 1] = string.format(
  "Main-thread stalls: worst %.0f ms, %d over 50 ms, %d over 200 ms",
  stalls.max,
  stalls.over_50,
  stalls.over_200
)
local errors = vim.tbl_filter(function(n)
  return n.level >= vim.log.levels.WARN
end, notes)
if #errors > 0 then
  out[#out + 1] = string.format("Warnings/errors shown to the user: %d, e.g.", #errors)
  for i = 1, math.min(3, #errors) do
    out[#out + 1] = "  " .. errors[i].msg:gsub("\n", " "):sub(1, 150)
  end
end
-- The sidebar's text, as a sanity check that it rendered the fixture.
local sidebar_lines = 0
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.bo[b].filetype == "AtlasSidebar" then
    sidebar_lines = vim.api.nvim_buf_line_count(b)
  end
end
out[#out + 1] = "Sidebar rows rendered: " .. sidebar_lines
io.stdout:write(table.concat(out, "\n") .. "\n")
