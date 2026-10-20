local VERSION='2026.10.19-r13'
local id=os.getComputerID()
local valid={[10]=true,[11]=true,[12]=true,[13]=true,[14]=true,[16]=true,[17]=true,[18]=true,[19]=true}
local configured=settings.get('fleet.role')
local roles={CORE=true,SENSOR_UI=true,LEFT_MAIN=true,RIGHT_MAIN=true,VECTOR=true,FINE_LF=true,FINE_RF=true,FINE_LB=true,FINE_RB=true}
assert(configured and roles[configured] or not configured and valid[id],'Set fleet.role for this node')
local function readFile(name)local h=assert(fs.open(name,'r'));local d=h.readAll();h.close();return d end
local function writeFile(name,d)local h=assert(fs.open(name,'w'));h.write(d);h.close()end
local function sum(d)
  local a,b=1,0;for i=1,#d do a=(a+d:byte(i))%65521;b=(b+a)%65521 end
  return string.format('%08x',b*65536+a)
end
local function recoverFailedAdmin()
  local path=fs.exists('.fleet-update') and '.fleet-update' or fs.exists('fleet_boot_recovery.txt') and 'fleet_boot_recovery.txt'
  if not path then return end
  local j=textutils.unserialize(readFile(path));assert(type(j)=='table','Invalid boot recovery journal')
  if j.state=='CONFIRMED' then return end
  local entries=j.files or {j}
  for _,f in ipairs(entries)do
    assert(f.name=='fleet.lua' or f.name=='fleet_admin.lua' or f.name=='startup.lua','Invalid recovery path')
    if f.changed~=false and f.hadOld then assert(f.backup and fs.exists(f.backup),'Missing boot rollback backup');if f.oldChecksum then assert(sum(readFile(f.backup))==f.oldChecksum,'Boot backup checksum mismatch')end end
  end
  for _,f in ipairs(entries)do
    if f.changed~=false then
      if f.hadOld then writeFile(f.name,readFile(f.backup))elseif fs.exists(f.name)then fs.delete(f.name)end
    end
  end
  fs.delete(path)
  if fs.exists('.fleet-update.new') then fs.delete('.fleet-update.new')end
end
while true do
  local env=setmetatable({FLEET_NODE_VERSION=VERSION},{__index=_ENV});env._G=env
  local fn,why=loadfile('fleet_admin.lua',nil,env)
  local ok,err=false,why
  if fn then ok,err=pcall(fn)end
  if not ok then
    pcall(writeFile,'fleet_boot_error.txt',tostring(err))
    local restored,problem=pcall(recoverFailedAdmin)
    print(restored and 'Admin failed; rollback checked, restarting' or 'MANUAL RECOVERY REQUIRED: '..tostring(problem))
  else print('Admin supervisor exited; restarting')end
  sleep(1)
end
