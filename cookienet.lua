-- cookienet: tiny package manager. Registry = packages.json in the GitHub repo.
local BASE = "https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/"
local STATE = "/.cookienet/installed.json" -- { pkgs = { name = {files, main} }, boot = name }
local USAGE = [[cookienet <cmd>
  list              packages available
  get <pkg>... [--boot]  install (--boot: run on startup)
  rm <pkg>...       uninstall
  update [pkg...]   re-pull installed (all if none)
  boot <pkg|off>    set/clear startup program]]

local function fetch(path)
  -- ?t= dodges stale CDN cache
  local r, err = http.get(BASE .. path .. "?t=" .. os.epoch("utc"))
  if not r then error("fetch " .. path .. ": " .. tostring(err), 0) end
  local s = r.readAll()
  r.close()
  return s
end

local function write(path, s)
  local f = fs.open(path, "w")
  f.write(s)
  f.close()
end

local function loadState()
  if fs.exists(STATE) then
    local f = fs.open(STATE, "r")
    local s = textutils.unserialiseJSON(f.readAll())
    f.close()
    if s then s.pkgs = s.pkgs or {}; return s end
  end
  return { pkgs = {} }
end

local function registry()
  return textutils.unserialiseJSON(fetch("packages.json")) or error("bad packages.json", 0)
end

local function install(name, reg, st)
  local p = reg[name] or error("no such package: " .. name, 0)
  local data = {}
  -- fetch everything first so a failed download never leaves a half-updated machine
  for _, f in ipairs(p.files) do data[f] = fetch(f) end
  local keep = {}
  for _, f in ipairs(p.files) do keep[f] = true end
  for _, f in ipairs((st.pkgs[name] or {}).files or {}) do
    if not keep[f] then fs.delete("/" .. f) end
  end
  for f, s in pairs(data) do write("/" .. f, s) end
  st.pkgs[name] = { files = p.files, main = p.main }
  print("installed " .. name)
end

local function setBoot(name, st)
  if name == "off" then
    fs.delete("/startup.lua")
    st.boot = nil
    return print("boot cleared")
  end
  local p = st.pkgs[name]
  if not (p and p.main) then error(name .. " not installed or has no main", 0) end
  -- update first (failure is non-fatal: shell.run just returns false), then run the program
  write("/startup.lua", 'shell.run("/cookienet.lua", "update")\nshell.run("/' .. p.main .. '")\n')
  st.boot = name
  print("boot: " .. name)
end

local cmd, rest, boot = (...), {}, false
for _, a in ipairs({ select(2, ...) }) do
  if a == "--boot" then boot = true elseif a ~= "--all" then rest[#rest + 1] = a end
end

local st = loadState()
if cmd == "list" then
  for name, p in pairs(registry()) do
    print(("%s%s - %s"):format(st.pkgs[name] and "* " or "  ", name, p.desc or ""))
  end
elseif cmd == "get" and #rest > 0 then
  local reg = registry()
  for _, n in ipairs(rest) do install(n, reg, st) end
  if boot then setBoot(rest[1], st) end
elseif cmd == "update" then
  local reg, names = registry(), rest
  if #names == 0 then
    for n in pairs(st.pkgs) do names[#names + 1] = n end
  end
  for _, n in ipairs(names) do install(n, reg, st) end
elseif cmd == "rm" and #rest > 0 then
  for _, n in ipairs(rest) do
    local p = st.pkgs[n] or error("not installed: " .. n, 0)
    for _, f in ipairs(p.files) do fs.delete("/" .. f) end
    st.pkgs[n] = nil
    if st.boot == n then setBoot("off", st) end
    print("removed " .. n)
  end
elseif cmd == "boot" and rest[1] then
  setBoot(rest[1], st)
else
  return print(USAGE)
end
write(STATE, textutils.serialiseJSON(st))
