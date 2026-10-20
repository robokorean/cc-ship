local a={...}
local X=tonumber(a[1]) or settings.get('fleet.gps_x')
local Y=tonumber(a[2]) or settings.get('fleet.gps_y')
local Z=tonumber(a[3]) or settings.get('fleet.gps_z')
local function valid(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
assert(valid(X) and valid(Y) and valid(Z),'Set fleet.gps_x / fleet.gps_y / fleet.gps_z to this fixed host location, then settings.save()')
while true do
  local ok,why=pcall(shell.run,'gps','host',tostring(X),tostring(Y),tostring(Z))
  print(ok and 'GPS host exited; restarting' or 'GPS host failed: '..tostring(why))
  sleep(1)
end
