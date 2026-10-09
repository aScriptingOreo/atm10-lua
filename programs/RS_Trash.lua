-- RS Bridge next to the computer: export anything in RS_Trash.json above its keep count out ExportDir (into the trash).
-- @desc Trash RS items/tags above a keep count (list in RS_Trash.json)
-- @deps cn_lib
-- @files programs/RS_Trash.json
-- @config ExportDir|Bridge side facing the trash|down
local cfg = dofile("/lib/cn.lua")
local EXPORT_DIR = cfg.ExportDir or "down"
local LIST = "/programs/RS_Trash.json"
-- { "item:id": keep, "#tag:id": keep, "item:id": { "keep": N, "ignoreNBT": true } }
-- keep applies per item id (a tag entry = every item in the tag, each kept to N).
-- ignoreNBT: all NBT/component variants of an id share one count; otherwise each variant counts alone.
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

-- AP may hand tags back as a list of ids or a set keyed by id; accept both, with or without '#'
local function hasTag(it, tag)
  for k, v in pairs(it.tags or {}) do
    if v == tag or k == tag or v == "#" .. tag or k == "#" .. tag then return true end
  end
end

-- first list entry that matches this stack: exact id wins over tags
local function rule(list, it)
  local r = list[it.name]
  if not r then
    for key, v in pairs(list) do
      if key:sub(1, 1) == "#" and hasTag(it, key:sub(2)) then r = v break end
    end
  end
  if type(r) == "number" then return { keep = r } end
  return r
end

local function export(filter, n)
  filter.count = n
  local _, got, err = pcall(bridge.exportItem, TARGET, filter)
  print(("%s -%s%s"):format(filter.name, tostring(got), err and (" (" .. tostring(err) .. ")") or ""))
end

print("trashing -> " .. TARGET)
while true do
  local list = load() -- reload each pass: edit the json live, no restart
  local ok, items = pcall(bridge.getItems) -- AP 0.8 name (was listItems)
  if not ok then print("error: " .. tostring(items)) items = {} end
  local merged = {} -- ignoreNBT totals by id
  for _, it in ipairs(items) do
    local r = rule(list, it)
    if r and r.ignoreNBT then
      merged[it.name] = merged[it.name] or { keep = r.keep or 0, count = 0 }
      merged[it.name].count = merged[it.name].count + (it.count or 0)
    elseif r and (it.count or 0) > (r.keep or 0) then
      -- ponytail: fingerprint pins the exact variant; without one AP matches any variant of the id
      export({ name = it.name, fingerprint = it.fingerprint }, it.count - (r.keep or 0))
    end
  end
  for name, m in pairs(merged) do
    if m.count > m.keep then export({ name = name }, m.count - m.keep) end -- name-only filter = any NBT
  end
  sleep(POLL)
end
