-- Pull latest files listed in manifest.txt. First install: wget run <raw url>/update.lua
local base = "https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/"

local function get(path)
  -- ?t= dodges stale CDN cache
  local r, err = http.get(base .. path .. "?t=" .. os.epoch("utc"))
  if not r then error("fetch " .. path .. ": " .. tostring(err), 0) end
  local s = r.readAll()
  r.close()
  return s
end

local paths, data = {}, {}
for line in get("manifest.txt"):gmatch("[^\r\n]+") do paths[#paths + 1] = line end
-- fetch all first so a failed download never leaves a half-updated machine
for _, p in ipairs(paths) do data[p] = get(p) end
for _, p in ipairs(paths) do
  local f = fs.open(p, "w")
  f.write(data[p])
  f.close()
end
print("updated " .. #paths .. " files")

-- `update <program>`: make this computer auto-update then run programs/<program>.lua on boot
if arg and arg[1] then
  local f = fs.open("startup.lua", "w")
  f.write('shell.run("update")\nshell.run("programs/' .. arg[1] .. '.lua")\n')
  f.close()
  print("startup set: " .. arg[1])
end