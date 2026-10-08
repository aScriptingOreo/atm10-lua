-- Computer A: next to the reactor redstone port (Energy mode). Broadcasts gate state over rednet.
local IN_SIDE = "back" -- side touching the port's comparator output
local PROTO = "reactor"
local HEARTBEAT = 10   -- seconds; receiver fails closed if it hears nothing for longer

rednet.open(peripheral.getName(peripheral.find("modem")))
local function send()
  local sig = redstone.getAnalogInput(IN_SIDE)
  rednet.broadcast({ open = sig > 0, signal = sig }, PROTO)
  print(("signal=%d gate=%s"):format(sig, sig > 0 and "open" or "closed"))
end

while true do
  send()
  local t = os.startTimer(HEARTBEAT)
  repeat
    local e, id = os.pullEvent()
    if e == "redstone" then break end
  until e == "timer" and id == t
end
