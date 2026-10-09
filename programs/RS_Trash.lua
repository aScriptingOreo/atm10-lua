-- RS Bridge next to the computer: export anything in RS_Trash.json above its keep count out ExportDir (into the trash).
-- @desc Trash RS items above a keep count, or whole tags (list in RS_Trash.json)
-- @deps cn_lib
-- @files programs/RS_Trash.json
-- @config ExportDir|Bridge side facing the trash|down
local cfg = dofile("/lib/cn.lua")
local EXPORT_DIR = cfg.ExportDir or "down"
local LIST = "/programs/RS_Trash.json"
-- { "item:id": keep, "#tag:id": 0 }  (object form { "keep": N } also accepted)
-- keep = max count left in RS. Any NBT variant matches. "#tag" entries trash everything in the tag.
local POLL = 5 -- seconds
-- AP 0.8 target: "@<direction>" = side of the bridge, anything else = peripheral name on the network
local DIRS = { up = 1, down = 1, north = 1, south = 1, east = 1, west = 1, front = 1, back = 1, left = 1, right = 1, top = 1, bottom = 1 }
local TARGET = DIRS[EXPORT_DIR] and "@" .. EXPORT_DIR or EXPORT_DIR

local bridge = peripheral.find("rs_bridge") or error("no rs_bridge", 0)

local function load()
  local f = fs.open(LIST, "r") or error("missing " .. LIST, 0)
  local t = textutils.unserialiseJSON(f.readAll())
  f.close()
  return t or error("bad json in " .. LIST, 0)
end

local PER_PASS = 64 -- max items trashed per entry per pass

-- ONE item per call: AP ignores max stack size on export, and the trash can crashes the
-- server saving an oversized stack (576 spell books in one slot = crash loop). Never raise this.
local function export(filter, n)
  filter.count = 1
  local total = 0
  for _ = 1, math.min(n, PER_PASS) do
    local _, got, err = pcall(bridge.exportItem, TARGET, filter)
    if err or not got or got < 1 then
      if err then print(("%s: %s"):format(filter.name or filter.tag, tostring(err))) end
      break
    end
    total = total + got
  end
  if total > 0 then print(("%s -%d"):format(filter.name or filter.tag, total)) end
end

print("trashing -> " .. TARGET)
while true do
  -- ponytail: never getItems() -- dumping a big RS network every pass stalled/crashed the server.
  -- Only targeted lookups now: exact ids by count, tags trash everything matching (keep ignored).
  for key, r in pairs(load()) do -- reload each pass: edit the json live, no restart
    local keep = type(r) == "table" and (r.keep or 0) or r
    if key:sub(1, 1) == "#" then
      export({ tag = key:sub(2) }, PER_PASS)
    else
      local ok, info = pcall(bridge.getItem, { name = key })
      local extra = ok and ((info or {}).count or 0) - keep or 0
      -- name-only filter matches any NBT; keep 0 = always try, so every variant drains
      if keep == 0 then extra = PER_PASS end
      if extra > 0 then export({ name = key }, extra) end
    end
  end
  sleep(POLL)
end
