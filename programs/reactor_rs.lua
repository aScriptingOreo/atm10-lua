-- Computer B: next to an RS Bridge. While the gate is open, keep pellets stocked and push them out.
-- @desc RS Bridge pellet feeder, listens for reactor_sensor
-- @deps cn_lib
-- @config ReactorName|Reactor name (same on sensor + RS computer)
-- @config ExportDir|Bridge side facing the fuel port|down
-- @config Pellet|Pellet item id|oritech:uranium_pellet
local cfg = dofile("/lib/cn.lua")
local PELLET = cfg.Pellet or "oritech:uranium_pellet"
local EXPORT_DIR = cfg.ExportDir or "down" -- bridge side facing the reactor fuel port
local STOCK = 64         -- craft when RS holds fewer than this
local BATCH = 64         -- pellets per craft / export call
local TIMEOUT = 30       -- no sensor message this long -> gate closed
local PROTO = "reactor:" .. (cfg.ReactorName or error("cookienet config ReactorName=<name>", 0))

local bridge = peripheral.find("rs_bridge") or error("no rs_bridge", 0)
rednet.open(peripheral.getName(peripheral.find("modem")))

print("listening on " .. PROTO)
local open, last = false, 0
local function setOpen(v)
  if v ~= open then print("gate " .. (v and "open" or "closed")) end
  open = v
end

local function tick()
  if os.clock() - last > TIMEOUT then setOpen(false) end
  if not open then return end
  local item = { name = PELLET }
  local have = (bridge.getItem(item) or {}).amount or 0
  if have < STOCK and not bridge.isItemCrafting(item) then
    print("crafting " .. BATCH)
    bridge.craftItem({ name = PELLET, count = BATCH })
  end
  if have > 0 then
    print("exported " .. tostring(bridge.exportItem({ name = PELLET, count = BATCH }, EXPORT_DIR)))
  end
end

local t = os.startTimer(5)
while true do
  local e, a, b, c = os.pullEvent()
  if e == "rednet_message" and c == PROTO and type(b) == "table" then
    last = os.clock()
    setOpen(b.open)
  elseif e == "timer" and a == t then
    local ok, err = pcall(tick) -- bridge errors (bad item id, RS offline) shouldn't kill the loop
    if not ok then print("error: " .. tostring(err)) end
    t = os.startTimer(5)
  end
end
