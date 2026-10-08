-- Computer B: next to an RS Bridge. While the gate is open, keep pellets stocked and push them out.
-- @desc RS Bridge pellet feeder, listens for reactor_sensor
-- @deps cn_lib
-- @config ReactorName|Reactor name (same on sensor + RS computer)
-- @config ExportDir|Bridge side facing the fuel port|down
-- @config Pellet|Pellet item id|oritech:uranium_pellet
-- @config Batch|Pellets per export / craft|8
-- @config Stock|Craft when RS holds fewer than|64
local cfg = dofile("/lib/cn.lua")
local PELLET = cfg.Pellet or "oritech:uranium_pellet"
local EXPORT_DIR = cfg.ExportDir or "down" -- bridge side facing the reactor fuel port
-- AP 0.8 target: "@<direction>" = side of the bridge, anything else = peripheral name on the network
local TARGET = EXPORT_DIR:match("^@") and EXPORT_DIR
  or (({ up = 1, down = 1, north = 1, south = 1, east = 1, west = 1, front = 1, back = 1, left = 1, right = 1, top = 1, bottom = 1 })[EXPORT_DIR] and "@" .. EXPORT_DIR)
  or EXPORT_DIR
local STOCK = tonumber(cfg.Stock) or 64 -- craft when RS holds fewer than this
local BATCH = tonumber(cfg.Batch) or 8  -- pellets per craft / export call
local COOLDOWN = 60      -- seconds between craft requests (isCrafting alone let them pile up)
local TIMEOUT = 30       -- no sensor message this long -> gate closed
local PROTO = "reactor:" .. (cfg.ReactorName or error("cookienet config ReactorName=<name>", 0))

local bridge = peripheral.find("rs_bridge") or error("no rs_bridge", 0)
rednet.open(peripheral.getName(peripheral.find("modem")))

print("listening on " .. PROTO)
local open, last, nextCraft = false, 0, 0
local function setOpen(v)
  if v ~= open then print("gate " .. (v and "open" or "closed")) end
  open = v
end

local function tick()
  if os.clock() - last > TIMEOUT then setOpen(false) end
  if not open then return end
  local item = { name = PELLET }
  local info = bridge.getItem(item) or {}
  local have = info.count or 0 -- AP 0.8 field is `count`
  if have < STOCK and os.clock() >= nextCraft then
    local busy = bridge.isCrafting(item)
    print("have " .. have .. ", crafting " .. BATCH .. " (isCrafting=" .. tostring(busy) .. ")")
    if not busy then bridge.craftItem({ name = PELLET, count = BATCH }) end
    nextCraft = os.clock() + COOLDOWN
  end
  if have > 0 then
    -- AP 0.8: exportItem(target, filter). Returns count or nil, err
    local n, err = bridge.exportItem(TARGET, { name = PELLET, count = BATCH })
    print("exported " .. tostring(n) .. (err and (" (" .. tostring(err) .. ")") or ""))
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
