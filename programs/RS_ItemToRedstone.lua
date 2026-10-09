-- RS Bridge next to the computer: redstone on OutSide while Item count in RS is <= Threshold.
-- @desc Redstone out while an RS item is at/below a count
-- @deps cn_lib
-- @config Item|Item id to watch|minecraft:soul_sand
-- @config Threshold|Signal on when count is at or below|16384
-- @config OutSide|Redstone output side|back
local cfg = dofile("/lib/cn.lua")
local ITEM = cfg.Item or "minecraft:soul_sand"
local THRESHOLD = tonumber(cfg.Threshold) or 16384
local OUT_SIDE = cfg.OutSide or "back"
local POLL = 1 -- seconds

local bridge = peripheral.find("rs_bridge") or error("no rs_bridge", 0)
print(("watching %s <= %d -> %s"):format(ITEM, THRESHOLD, OUT_SIDE))

local last
while true do
  -- pcall: RS offline / chunk reload shouldn't kill the loop; keep last output on error
  local ok, info = pcall(bridge.getItem, { name = ITEM })
  if ok then
    local have = (info or {}).count or 0 -- AP 0.8 field is `count`; missing item = 0
    local on = have <= THRESHOLD
    redstone.setOutput(OUT_SIDE, on)
    if on ~= last then print(("%s=%d signal=%s"):format(ITEM, have, on and "on" or "off")) end
    last = on
  else
    print("error: " .. tostring(info))
  end
  sleep(POLL)
end
