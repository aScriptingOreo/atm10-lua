-- Shared helper. Usage: local cfg = dofile("/lib/cn.lua")  -- table of this computer's cookienet config
local f = fs.open("/.cookienet/installed.json", "r")
if not f then return {} end
local s = textutils.unserialiseJSON(f.readAll()) or {}
f.close()
return s.config or {}
