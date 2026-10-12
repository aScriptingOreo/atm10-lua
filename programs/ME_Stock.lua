-- ME Bridge next to the computer: autocraft anything in ME_Stock.json that drops below its keep count.
-- @desc Keep ME items stocked: autocraft when below a count (list in ME_Stock.json)
-- @deps cn_lib
-- @files programs/ME_Stock.json
-- @config Poll|Seconds between checks|10
local cfg = dofile("/lib/cn.lua")
-- also the craft cooldown: a request needs a moment to land on a CPU before isCrafting sees it
local POLL = tonumber(cfg.Poll) or 10
local LIST = "/programs/ME_Stock.json"
-- { "item:id": keep }  or  { "item:id": { "keep": N, "batch": M } }
-- keep = min count in ME. batch = max per craft request (AE2 refuses the whole job if it can't
-- afford all of it, so cap big targets). Needs a pattern for the item.

local bridge = peripheral.find("me_bridge") or error("no me_bridge", 0)

local function load()
  local f = fs.open(LIST, "r") or error("missing " .. LIST, 0)
  local t = textutils.unserialiseJSON(f.readAll())
  f.close()
  return t or error("bad json in " .. LIST, 0)
end

local function need(have, keep, batch)
  return math.min(math.max(keep - have, 0), batch or math.huge)
end
assert(need(10, 64) == 54 and need(64, 64) == 0 and need(0, 1000, 256) == 256)

local function check(name, r)
  local keep, batch = r, nil
  if type(r) == "table" then keep, batch = r.keep or 0, r.batch end
  local ok, info = pcall(bridge.getItem, { name = name })
  if not ok then return print(name .. ": " .. tostring(info)) end -- offline / bad id
  local have = (info or {}).count or 0
  local n = need(have, keep, batch)
  if n == 0 then return end
  local _, busy = pcall(bridge.isCrafting, { name = name })
  if busy == true then return end
  local called, job, err = pcall(bridge.craftItem, { name = name, count = n })
  if not called then job, err = nil, job end
  print(("%s %d/%d +%d%s"):format(name, have, keep, n, job and "" or (" FAILED " .. tostring(err))))
end

print("stocking from " .. LIST)
while true do
  -- targeted getItem per entry, never getItems() (full network dump every pass stalls the server).
  -- All entries queued at once so they share ticks (same trick as RS_Trash).
  local jobs = {}
  for name, r in pairs(load()) do -- reload each pass: edit the json live, no restart
    jobs[#jobs + 1] = function() check(name, r) end
  end
  parallel.waitForAll(table.unpack(jobs))
  sleep(POLL)
end
