-- Computer A: next to the reactor redstone port (Energy mode). Broadcasts gate state over rednet.
-- @desc Oritech reactor redstone port -> rednet gate broadcast
-- @deps cn_lib
-- @config ReactorName|Reactor name (same on sensor + RS computer)
-- @config InSide|Side touching redstone port comparator|back
-- @config OpenBelow|Gate opens (fuel allowed) when signal is below this, 1 = only when empty|1
local cfg = dofile("/lib/cn.lua")
local IN_SIDE = cfg.InSide or "back" -- side touching the port's comparator output
local OPEN_BELOW = tonumber(cfg.OpenBelow) or 1
local PROTO = "reactor:" .. (cfg.ReactorName or error("cookienet config ReactorName=<name>", 0))
local POLL = 0.25      -- seconds (5 ticks): how often the signal is sampled
local HEARTBEAT = 10   -- seconds; resend even if unchanged, receiver fails closed after silence

rednet.open(peripheral.getName(peripheral.find("modem")))

local lastSig, lastSent = nil, 0
while true do
  local sig = redstone.getAnalogInput(IN_SIDE)
  if sig ~= lastSig or os.clock() - lastSent >= HEARTBEAT then
    rednet.broadcast({ open = sig < OPEN_BELOW, signal = sig }, PROTO)
    if sig ~= lastSig then print(("signal=%d gate=%s"):format(sig, sig < OPEN_BELOW and "open" or "closed")) end
    lastSig, lastSent = sig, os.clock()
  end
  sleep(POLL)
end
