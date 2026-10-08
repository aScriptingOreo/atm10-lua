-- Shared helper. Usage: local cfg = dofile("/lib/cn.lua")  -- table of this computer's cookienet config
-- @name cn_lib
-- @desc shared config helper (auto-installed as a dependency)
local f = fs.open("/.cookienet/installed.json", "r")
if not f then return {} end
local s = textutils.unserialiseJSON(f.readAll()) or {}
f.close()
return s.config or {}
