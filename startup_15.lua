local VERSION='2026.10.20-r15'
assert(settings.get('fleet.role')=='ADMIN' or not settings.get('fleet.role') and os.getComputerID()==15,'ADMIN role required')
local native=term.current()
local w,h=native.getSize()
local hidden=window.create(native,1,1,w,h,false)
local tasks={}
local testing
local focus='console'
local function readFile(path)
  local f=assert(fs.open(path,'r'),'Missing '..path);local d=f.readAll();f.close();return d
end
local function writeFile(path,data)
  local f=assert(fs.open(path,'w'),'Cannot write '..path);local ok,why=pcall(f.write,data);f.close();assert(ok,why)
end
local function sum(data)
  local a,b=1,0;for i=1,#data do a=(a+data:byte(i))%65521;b=(b+a)%65521 end
  return string.format('%08x',b*65536+a)
end
local journal='.fleet-self-update'
local function allowed(name)return name=='fleet_view.lua' or name=='deploy.lua' or name=='startup.lua' end
local function temp(name,kind)return type(name)=='string' and name:match('^%.fleet%-self%-'..kind..'%-[%w%-]+%-.+%.lua$')~=nil end
local function loadJournal()
  if not fs.exists(journal) and fs.exists(journal..'.new') then
    local probe=textutils.unserialize(readFile(journal..'.new'));assert(type(probe)=='table' and type(probe.files)=='table','MANUAL RECOVERY REQUIRED: invalid self journal.new')
    fs.move(journal..'.new',journal)
  end
  if not fs.exists(journal) then return nil end
  local j=textutils.unserialize(readFile(journal));assert(type(j)=='table' and type(j.files)=='table','MANUAL RECOVERY REQUIRED: invalid self journal')
  local seen={}
  for _,f in ipairs(j.files)do
    assert(allowed(f.name) and not seen[f.name] and temp(f.backup,'backup'),'Invalid self rollback path');seen[f.name]=true
    assert(not f.stage or temp(f.stage,'stage'),'Invalid self stage path')
    assert(type(f.oldChecksum)=='string' and type(f.checksum)=='string','Invalid self checksums')
  end
  return j
end
local function saveJournal(j)
  writeFile(journal..'.new',textutils.serialize(j))
  if fs.exists(journal)then fs.delete(journal)end
  fs.move(journal..'.new',journal)
end
local function cleanup(j)
  for _,f in ipairs(j and j.files or {})do
    if f.backup and fs.exists(f.backup)then fs.delete(f.backup)end
    if f.stage and fs.exists(f.stage)then fs.delete(f.stage)end
  end
  if fs.exists(journal)then fs.delete(journal)end
  if fs.exists(journal..'.new')then fs.delete(journal..'.new')end
end
local function orphanSweep()
  local j=loadJournal();local keep={}
  for _,f in ipairs(j and j.files or {})do keep[f.backup]=true;if f.stage then keep[f.stage]=true end end
  local count=0
  for _,n in ipairs(fs.list(''))do
    if not keep[n] and (temp(n,'backup') or temp(n,'stage')) and not fs.isDir(n)then fs.delete(n);count=count+1 end
  end
  if j and fs.exists(journal..'.new')then fs.delete(journal..'.new')end
  return count
end
local function restoreSelf()
  local j=loadJournal();if not j then return end
  if j.schema==2 and j.state=='PREPARING' then
    for _,f in ipairs(j.files)do assert(fs.exists(f.name) and sum(readFile(f.name))==f.oldChecksum,'Original changed during backup: '..f.name)end
  else
    for _,f in ipairs(j.files)do assert(fs.exists(f.backup) and sum(readFile(f.backup))==f.oldChecksum,'Self backup unavailable: '..f.name)end
    for _,f in ipairs(j.files)do writeFile(f.name,readFile(f.backup));assert(sum(readFile(f.name))==f.oldChecksum,'Self restore verification failed: '..f.name)end
  end
  cleanup(j)
end
local prior=loadJournal()
if prior then
  local confirmed=prior.state=='CONFIRMED'
  if confirmed then for _,f in ipairs(prior.files)do if not fs.exists(f.name) or sum(readFile(f.name))~=f.checksum then confirmed=false end end end
  if confirmed then cleanup(prior)else restoreSelf()end
end
orphanSweep()
local rootSource=readFile('startup.lua')
local selfPlan
local api={busy=false,abort=false,version=VERSION,ready=true,selfFormat=2}
local commandOwner
function api.serviceAvailable()
  for _,t in ipairs(tasks) do if t.name=='console' and not t.candidate and not t.dead then return true end end
  return false
end
function api.requestUpdate()
  if api.busy or commandOwner or not api.serviceAvailable() then return false end
  api.busy=true;api.abort=false;os.queueEvent('fleet_update_all');return true
end
function api.emergencyStop() api.abort=true;os.queueEvent('fleet_deploy_emergency') end
function api.enterCommand() if commandOwner then return false end;commandOwner=true;return true end
function api.leaveCommand() commandOwner=nil end
local function task(name,path,screen,source,candidate)
  local t={name=name,terminal=screen,path=path,source=source or readFile(path),candidate=candidate}
  local env=setmetatable({FLEET15=api,FLEET15_CANDIDATE=candidate==true,FLEET15_HEALTH=function(version)t.health=version;t.healthTime=os.clock()end},{__index=_ENV});env._G=env
  local fn,err=load(t.source,'@'..path,'t',env);assert(fn,err)
  t.env=env;t.co=coroutine.create(fn);tasks[#tasks+1]=t;return t
end
local function resume(t,event)
  local previous=term.current();term.redirect(t.terminal)
  local ok,filter=coroutine.resume(t.co,table.unpack(event or {}))
  t.terminal=term.current();term.redirect(previous);t.filter=filter;t.started=true
  if not ok then t.error=tostring(filter);t.dead=true;print(t.name..' stopped: '..t.error)
  elseif coroutine.status(t.co)=='dead' then t.dead=true end
end
local function current(name)
  for _,t in ipairs(tasks) do if t.name==name and not t.candidate and not t.dead then return t end end
end
function api.recoverSelf(proposed)
  local j=loadJournal()
  if j then
    for _,t in ipairs(tasks)do if t.candidate then t.dead=true end end
    restoreSelf();testing=nil;api.selfResult=nil;api.selfError=nil
  end
  selfPlan=nil;orphanSweep();return proposed
end
local function planSelf(data)
  local source={['fleet_view.lua']=assert(data['fleet_view.lua']),['deploy.lua']=assert(data['deploy.lua']),['startup.lua']=assert(data['startup_15.lua'])}
  local known={['fleet_view.lua']=assert(current('view'),'Current view unavailable').source,['deploy.lua']=assert(current('console'),'Current console unavailable').source,['startup.lua']=rootSource}
  local j={schema=2,state='PREPARING',token=tostring(os.epoch('utc'))..'-'..math.random(1,1000000),files={}}
  local backupBytes,growth=0,0
  for _,name in ipairs({'fleet_view.lua','deploy.lua','startup.lua'})do
    local d=source[name];assert(type(d)=='string' and #d>0 and #d<=1048576,'Invalid self file '..name)
    local fn,err=load(d,'@'..name,'t',{});assert(fn,err)
    assert(fs.exists(name) and readFile(name)==known[name],'Running/disk self file mismatch: '..name)
    if d~=known[name]then
      j.files[#j.files+1]={name=name,backup='.fleet-self-backup-'..j.token..'-'..name,size=#d,checksum=sum(d),oldChecksum=sum(known[name])}
      backupBytes=backupBytes+#known[name];growth=growth+math.max(0,#d-#known[name])
    end
  end
  local need=#j.files>0 and backupBytes+growth+2*#textutils.serialize(j)+8192 or 0
  local free=assert(fs.getFreeSpace,'15 storage preflight unavailable')('')
  assert(free=='unlimited' or type(free)=='number' and free>=need,'15 Out of space: need '..need..' bytes, free '..tostring(free)..', short '..(type(free)=='number' and math.max(0,need-free) or need)..' bytes; files untouched')
  return {journal=j,source=source,known=known,required=need,free=free}
end
function api.preflightSelf(data)
  orphanSweep();assert(not loadJournal(),'Unresolved self transaction')
  local plan=planSelf(data);return {required=plan.required,free=plan.free,changed=#plan.journal.files}
end
function api.prepareSelf(data)
  assert(not loadJournal(),'Self-update transaction pending')
  selfPlan=planSelf(data);api.selfResult=nil;api.selfError=nil;return true
end
function api.testSelf()
  assert(selfPlan,'Self plan required');os.queueEvent('fleet15_self_test')
  local started=os.clock()
  while api.selfResult==nil and os.clock()-started<8 do sleep(.05)end
  return api.selfResult==true,api.selfError or 'Self-update handshake timeout'
end
function api.applySelf()
  assert(selfPlan and api.selfResult==true,'Candidate self test required')
  local plan=selfPlan;local j=plan.journal
  if #j.files==0 then return true end
  -- Recheck capacity immediately before writing; remote transfer/report may have consumed space.
  local free=fs.getFreeSpace('');assert(free=='unlimited' or free>=plan.required,'15 Out of space before self apply; files untouched')
  local ok,why=pcall(function()
    saveJournal(j)
    for _,f in ipairs(j.files)do
      writeFile(f.backup,plan.known[f.name]);assert(sum(readFile(f.backup))==f.oldChecksum,'Self backup verification failed: '..f.name)
    end
    j.state='APPLYING';saveJournal(j)
    for _,f in ipairs(j.files)do
      writeFile(f.name,plan.source[f.name]);assert(sum(readFile(f.name))==f.checksum,'Self applied verification failed: '..f.name)
    end
    j.state='APPLIED';saveJournal(j)
  end)
  if not ok then
    local restored,err=pcall(function()
      if j.state=='PREPARING' then
        for _,f in ipairs(j.files)do assert(sum(readFile(f.name))==f.oldChecksum,'Original changed before apply')end
        cleanup(j)
      else restoreSelf()end
    end)
    error(tostring(why)..(restored and ' / self RESTORED' or ' / MANUAL RECOVERY REQUIRED: '..tostring(err)),0)
  end
  return true
end
function api.confirmSelf()
  assert(selfPlan and api.selfResult==true,'Healthy self candidate required')
  local j=loadJournal()
  if j then
    for _,f in ipairs(j.files)do assert(sum(readFile(f.name))==f.checksum,'Self disk changed: '..f.name)end
    j.state='CONFIRMED';saveJournal(j)
  end
  return true
end
function api.rollbackSelf()
  for _,t in ipairs(tasks)do if t.candidate then t.dead=true end end
  if loadJournal()then restoreSelf()end
  selfPlan=nil;orphanSweep();api.selfResult=false;api.busy=false;api.selfPending=false;testing=nil
end
function api.commitSelf()
  assert(selfPlan and api.selfResult==true,'Healthy candidate required')
  local j=loadJournal();assert(not j or j.state=='CONFIRMED','Self update not confirmed')
  api.selfPending=true;os.queueEvent('fleet15_self_commit')
end
task('view','fleet_view.lua',hidden)
task('console','deploy.lua',native)
for _,t in ipairs(tasks) do resume(t,{}) end
print('F12: keyboard focus console / view; monitor touch remains available')
local timer=os.startTimer(.1)
while true do
  local event=table.pack(os.pullEventRaw())
  if event[1]=='fleet15_self_test' then
    local ok,err=pcall(function()
      local sources=assert(selfPlan,'Self plan missing').source
      local v=task('view','fleet_view.lua',hidden,sources['fleet_view.lua'],true)
      local c=task('console','deploy.lua',native,sources['deploy.lua'],true)
      testing={view=v,console=c,deadline=os.clock()+5};resume(v,{});resume(c,{})
    end)
    if not ok then api.selfError=tostring(err);api.selfResult=false end
  elseif event[1]=='fleet15_self_commit' then
    local j=loadJournal()
    for _,t in ipairs(tasks) do if t.candidate then t.candidate=nil;t.env.FLEET15_CANDIDATE=false else t.dead=true end end
    for _,t in ipairs(tasks)do if not t.dead and t.name=='view' and t.env.FLEET_VIEW_BLACKOUT then t.env.FLEET_VIEW_BLACKOUT() end end
    os.queueEvent('fleet15_boot')
    rootSource=readFile('startup.lua')
    cleanup(j);selfPlan=nil;orphanSweep();api.busy=false;api.abort=false;api.selfPending=false;commandOwner=nil;testing=nil
  elseif event[1]=='key' and event[2]==keys.f12 then focus=focus=='console' and 'view' or 'console'
  else
    local keyboard=event[1]=='key' or event[1]=='key_up' or event[1]=='char' or event[1]=='paste' or event[1]=='terminate'
    for _,t in ipairs(tasks) do
      if not t.dead and not (t.candidate and (event[1]=='monitor_touch' or event[1]=='fleet_update_all')) and (not keyboard or (t.name==focus and not t.candidate)) and (not t.filter or t.filter==event[1] or event[1]=='terminate') then resume(t,event) end
    end
  end
  if testing and api.selfResult==nil then
    local a,b=testing.view,testing.console
    if a.dead or b.dead or os.clock()>testing.deadline then
      api.selfError=a.error or b.error or 'Candidate exited / missing ready heartbeat';api.selfResult=false
      a.dead=true;b.dead=true;pcall(restoreSelf)
    elseif a.health and b.health and os.clock()-math.max(a.healthTime,b.healthTime)>=.5 then api.selfResult=true end
  end
  if event[1]=='timer' and event[2]==timer then timer=os.startTimer(.1) end
  local alive=false;for _,t in ipairs(tasks) do if not t.dead then alive=true end end
  if not api.busy and not api.selfPending and not testing and not current('console') then break end
  if not alive then break end
end
term.redirect(native)
