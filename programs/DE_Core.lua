-- Draconic energy core readout. A computer touching one of the core's energy pylons (or wired to it), with a
-- wireless or ender modem: broadcasts the stored energy and the flow over rednet. Butler shows it in its
-- REACTOR tab. Read-only, the pylon has nothing to control.
-- @desc Draconic energy core readout: stored energy and flow, broadcast for Butler's REACTOR tab
local PROTO = "de_core"
local pylon = peripheral.find("draconic_rf_storage") or error("no energy pylon: put this computer against one, or a wired modem on it", 0)
local modem = false
peripheral.find("modem", function(name) rednet.open(name) modem = true end)
if not modem then error("no modem: put a wireless or ender modem on this computer", 0) end

-- The plain getters are Java longs and a tier 8 core holds more than that, so read the scientific form:
-- { coefficient, exponent }, both -1 for "no limit".
local function number(n)
  if type(n) ~= "table" or n.exponent == -1 then return nil end
  return n.coefficient * 10 ^ n.exponent
end
assert(number({ coefficient = 2.5, exponent = 12 }) == 2.5e12 and number({ coefficient = -1, exponent = -1 }) == nil)

local function fmt(n)
  local u, i = { "", "K", "M", "G", "T", "P", "E" }, 1
  while math.abs(n) >= 1000 and i < #u do n, i = n / 1000, i + 1 end
  return ("%.2f"):format(n) .. u[i]
end

while true do
  local r = {}
  -- queued together so they share a tick; a pylon that lost its core just leaves the values out
  parallel.waitForAll(
    function() r.stored = number(select(2, pcall(pylon.getEnergyStoredInNotation))) end,
    function() r.max = number(select(2, pcall(pylon.getMaxEnergyStoredInNotation))) end,
    function() local ok, v = pcall(pylon.getInputPerTick) r.input = ok and v or nil end,
    function() local ok, v = pcall(pylon.getOutputPerTick) r.output = ok and v or nil end)
  rednet.broadcast(r, PROTO)
  term.clear()
  term.setCursorPos(1, 1)
  print("DE core readout, broadcasting on " .. PROTO)
  print("stored " .. (r.stored and fmt(r.stored) or "?") .. " / " .. (r.max and fmt(r.max) or "no limit") .. " RF")
  print("in " .. fmt(r.input or 0) .. "  out " .. fmt(r.output or 0) .. " RF/t")
  sleep(1)
end
