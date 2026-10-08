-- Bootstrap: wget run https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/install.lua
local r = http.get("https://raw.githubusercontent.com/aScriptingOreo/atm10-lua/main/cookienet.lua?t=" .. os.epoch("utc"))
if not r then error("could not fetch cookienet.lua (http enabled?)", 0) end
local f = fs.open("/cookienet.lua", "w")
f.write(r.readAll())
f.close()
r.close()
shell.run("/cookienet.lua", "get", "cookienet") -- register itself so update --all keeps it fresh
print("installed. try: cookienet list")
