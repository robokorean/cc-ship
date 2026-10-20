local args={...}
local function newRoles()
  local roles={[10]='CORE',[11]='SENSOR_UI',[12]='LEFT_MAIN',[13]='RIGHT_MAIN',[14]='VECTOR',[15]='ADMIN',[16]='FINE_LF',[17]='FINE_RF',[18]='FINE_LB',[19]='FINE_RB'}
  local slots={};for n,r in pairs(roles) do slots[r]=n end
  local actual=os.getComputerID()
  local configured=settings and settings.get and settings.get('fleet.role')
  local role=configured or roles[actual]
  assert(slots[role],'Set fleet.role to CORE/SENSOR_UI/LEFT_MAIN/RIGHT_MAIN/VECTOR/ADMIN/FINE_LF/FINE_RF/FINE_LB/FINE_RB')
  local r={actual=actual,slot=slots[role],role=role,roles=roles,slots=slots,peers={},dynamic=configured~=nil,channel=42617}
  local key=settings and settings.get and settings.get('fleet.admin_key','') or ''
  local function fresh(p)return os.clock()-p.seen<=4 end
  function r.conflict()
    for name,peers in pairs(r.peers) do local found={};for id,p in pairs(peers) do if fresh(p)then found[#found+1]=id end end
      if #found>1 then table.sort(found);return 'ROLE CONFLICT '..name..': '..table.concat(found,',') end
    end
  end
  function r.resolve(slot)
    local name=roles[slot];if not name then return nil end
    if slot==r.slot then return actual end
    local found
    for id,p in pairs(r.peers[name] or {}) do if fresh(p) then if found and found~=id then return nil end;found=id end end
    if found then return found end
    if not r.dynamic then
      for other,peers in pairs(r.peers)do if other~=name and peers[slot] and fresh(peers[slot]) then return nil end end
      return slot
    end
  end
  function r.logical(id)
    if id==actual then return r.slot end
    for slot in pairs(roles) do if r.resolve(slot)==id then return slot end end
  end
  function r.snapshot()
    local out={role=role,actual=actual,conflict=r.conflict(),map={}}
    for slot,name in pairs(roles) do out.map[name]=r.resolve(slot) end
    return out
  end
  local seen={}
  local function transmit(m,exclude)
    for _,side in ipairs(redstone.getSides()) do if side~=exclude and peripheral.hasType(side,'modem') then
      pcall(peripheral.call,side,'open',r.channel);pcall(peripheral.call,side,'transmit',r.channel,r.channel,m)
    end end
  end
  function r.accept(m)
    if type(m)~='table' or m.magic~='fleet_roles_v1' or m.key~=key or slots[m.role]==nil
      or type(m.id)~='number' or m.id%1~=0 or m.id<0 or type(m.time)~='number'
      or math.abs(os.epoch('utc')-m.time)>3000 then return false end
    r.peers[m.role]=r.peers[m.role] or {};r.peers[m.role][m.id]={seen=os.clock()}
    return true
  end
  function r.run()
    local function announce()while true do
      local m={magic='fleet_roles_v1',key=key,role=role,id=actual,time=os.epoch('utc'),ttl=3,token=tostring(actual)..':'..os.epoch('utc')}
      r.accept(m);pcall(transmit,m);sleep(1)
    end end
    local function receive()while true do
      local _,side,ch,_,m=os.pullEventRaw('modem_message')
      if ch==r.channel and r.accept(m) and type(m.token)=='string' and #m.token<100 and not seen[m.token] then
        seen[m.token]=os.clock()
        if (r.slot==10 or r.slot==11) and type(m.ttl)=='number' and m.ttl>0 and m.ttl<=3 then
          local copy={};for k,v in pairs(m)do copy[k]=v end;copy.ttl=m.ttl-1;pcall(transmit,copy,side)
        end
      end
      for token,t in pairs(seen)do if os.clock()-t>5 then seen[token]=nil end end
    end end
    parallel.waitForAll(announce,receive)
  end
  r.accept({magic='fleet_roles_v1',key=key,role=role,id=actual,time=os.epoch('utc')})
  return r
end
local function discoverFine(strict)
  local names,seen={},{}
  local filter=settings and settings.get and settings.get('fleet.fine_names')
  local allowed
  if type(filter)=='string' then allowed={};for n in filter:gmatch('[^, ]+') do allowed[n]=true end end
  for _,name in ipairs(peripheral.getNames()) do if peripheral.hasType(name,'ion_thruster') and (not allowed or allowed[name]) then
    assert(not seen[name],'Duplicate Fine peripheral '..name);seen[name]=true;names[#names+1]=name
  end end
  table.sort(names,function(a,b)local aa,bb=tonumber(a:match('(%d+)$')),tonumber(b:match('(%d+)$'));if aa and bb and aa~=bb then return aa<bb end;return a<b end)
  local minimum=tonumber(settings and settings.get and settings.get('fleet.fine_min',1)) or 1
  if strict~=false then assert(#names>=minimum and #names<=64,'Fine detected '..#names..'; required '..minimum..'..64') end
  return names
end
local ROLE=FLEET_ROLES or (args[1]~='test_api' and newRoles() or nil)
local ADMIN_VERSION='2026.10.19-r14'
local REQUEST=42615
local RESPONSE=42616
local MAGIC='fleet_admin_v1'
local TARGETS={10,11,12,13,14,16,17,18,19}
local function now() return os.epoch('utc') end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function uid() return tostring(now())..'-'..math.random(1,1000000000) end
local function checksum(data,yielding)
  local a,b=1,0
  for i=1,#data do
    a=(a+data:byte(i))%65521;b=(b+a)%65521
    if yielding and i%4096==0 then sleep(0) end
  end
  return string.format('%08x',b*65536+a)
end
local function readFile(path)
  local h,err=fs.open(path,'rb');if not h then error(err or ('Cannot read '..path),0) end
  local ok,data=pcall(h.readAll);h.close();if not ok then error(data,0) end
  return data
end
local function writeFile(path,data)
  local h,err=fs.open(path,'wb');if not h then error(err or ('Cannot write '..path),0) end
  local ok,why=pcall(h.write,data);h.close();if not ok then error(why,0) end
end
local function validName(name)
  return type(name)=='string' and #name<=80 and name:match('^[%w_%-]+%.[%w]+$')~=nil
end
local function role(id)
  return ({[10]='CONTROL',[11]='UI/RELAY',[12]='LEFT',[13]='RIGHT',[14]='ROTATION',
    [16]='LF FINE',[17]='RF FINE',[18]='LB FINE',[19]='RB FINE'})[id] or 'UNKNOWN'
end
local function isTarget(id)
  for _,v in ipairs(TARGETS) do if v==id then return true end end
  return false
end
local function network(id)
  local owned={}
  local key=settings.get('fleet.admin_key','')
  local function scan()
    local list={}
    for _,side in ipairs(redstone.getSides()) do
      if peripheral.hasType(side,'modem') then
        local ok,radio=pcall(peripheral.call,side,'isWireless')
        if ok then
          list[#list+1]={side=side,wireless=radio}
          for _,ch in ipairs({REQUEST,RESPONSE}) do
            local good,opened=pcall(peripheral.call,side,'isOpen',ch)
            if good and not opened and pcall(peripheral.call,side,'open',ch) then
              owned[side]=owned[side] or {};owned[side][ch]=true
            end
          end
        end
      end
    end
    return list
  end
  local function send(packet,channel,exclude)
    local wire={};for k,v in pairs(packet)do wire[k]=v end
    wire.from=ROLE.resolve(packet.from);wire.to=ROLE.resolve(packet.to)
    if not wire.from or not wire.to then ROLE.networkError='ROLE UNREGISTERED / CONFLICT: '..tostring(ROLE.roles[packet.to]);return 0 end
    ROLE.networkError=nil
    wire.route={};for _,slot in ipairs(packet.route)do local actual=ROLE.resolve(slot);if not actual then return 0 end;wire.route[#wire.route+1]=actual end
    local sent=0
    for _,m in ipairs(scan()) do
      if m.side~=exclude then
        if pcall(peripheral.call,m.side,'transmit',channel,channel,wire) then sent=sent+1 end
      end
    end
    return sent
  end
  local function envelope(to,rid,op,body)
    return {magic=MAGIC,from=id,to=to,rid=rid,op=op,body=body or {},time=now(),
      route={id},ttl=3,packet=uid(),key=key}
  end
  local function valid(m)
    local valid=type(m)=='table' and m.magic==MAGIC and m.key==key and finite(m.from) and finite(m.to)
      and type(m.rid)=='string' and #m.rid<=120 and type(m.op)=='string' and #m.op<=30
      and type(m.body)=='table' and type(m.route)=='table' and #m.route<=4
      and finite(m.ttl) and m.ttl>=0 and m.ttl<=3 and finite(m.time)
      and math.abs(now()-m.time)<=10000 and type(m.packet)=='string' and #m.packet<=120
    if not valid then return false end
    local from,to=ROLE.logical(m.from),ROLE.logical(m.to);if not from or not to then return false end
    local route={};for _,actual in ipairs(m.route)do local slot=ROLE.logical(actual);if not slot then return false end;route[#route+1]=slot end
    m.from=from;m.to=to;m.route=route;return true
  end
  local function close()
    for side,chs in pairs(owned) do for ch in pairs(chs) do pcall(peripheral.call,side,'close',ch) end end
  end
  return {scan=scan,send=send,envelope=envelope,valid=valid,close=close}
end

local function replaceFile(stage,name,expected,cancelled)
  local data=readFile(stage)
  assert(checksum(data,true)==expected,'Staged checksum changed')
  assert(not cancelled or not cancelled(),'Transfer cancelled')
  local backup=name..'.bak.'..uid()
  local old=fs.exists(name)
  if old then fs.copy(name,backup) end
  assert(not cancelled or not cancelled(),'Transfer cancelled')
  local journal={name=name,stage=stage,backup=old and backup or nil,checksum=expected,hadOld=old}
  local written,writeError=pcall(writeFile,'.fleet-admin-commit',textutils.serialize(journal))
  if not written then pcall(fs.delete,'.fleet-admin-commit');error(writeError,0) end
  local ok,err=pcall(function()
    if fs.exists(name) then fs.delete(name) end
    fs.move(stage,name)
    assert(checksum(readFile(name),true)==expected,'Applied file verification failed')
  end)
  if not ok then
    local restored,why=pcall(function()
      if fs.exists(name) then fs.delete(name) end
      if old then fs.copy(backup,name) end
    end)
    if restored then pcall(fs.delete,'.fleet-admin-commit') end
    error(tostring(err)..(restored and ' / previous file restored' or ' / RECOVERY REQUIRED: '..tostring(why)),0)
  end
  pcall(fs.delete,'.fleet-admin-commit')
  return backup
end
local function recover()
  if not fs.exists('.fleet-admin-commit') then return end
  local j=textutils.unserialize(readFile('.fleet-admin-commit'))
  assert(type(j)=='table' and validName(j.name),'Invalid recovery journal')
  local complete=fs.exists(j.name) and checksum(readFile(j.name),true)==j.checksum
  if not complete then
    if j.hadOld~=false then assert(j.backup and fs.exists(j.backup),'Recovery backup missing: '..j.name) end
    if fs.exists(j.name) then fs.delete(j.name) end
    if j.backup then fs.copy(j.backup,j.name) end
  end
  if j.stage and fs.exists(j.stage) then fs.delete(j.stage) end
  fs.delete('.fleet-admin-commit')
end
local TXPATH='.fleet-update'
local function loadUpdate()
  if not fs.exists(TXPATH) and fs.exists(TXPATH..'.new') then fs.move(TXPATH..'.new',TXPATH) end
  if not fs.exists(TXPATH) then return nil end
  local t=textutils.unserialize(readFile(TXPATH))
  assert(type(t)=='table' and t.name=='fleet.lua' and type(t.token)=='string' and type(t.checksum)=='string','Invalid update journal; preserve for recovery')
  return t
end
local function saveUpdate(t)
  writeFile(TXPATH..'.new',textutils.serialize(t))
  if fs.exists(TXPATH) then fs.delete(TXPATH) end
  fs.move(TXPATH..'.new',TXPATH)
end
local function restoreUpdate()
  local t=loadUpdate();if not t then return 'No pending update' end
  local files=t.files or {t}
  for _,f in ipairs(files) do
    assert(f.name=='fleet.lua' or f.name=='fleet_admin.lua' or f.name=='startup.lua','Invalid rollback filename')
    if f.changed~=false and f.hadOld then
      assert(f.backup and fs.exists(f.backup),'Update backup missing: '..f.name)
      assert(checksum(readFile(f.backup),true)==f.oldChecksum,'Update backup checksum mismatch: '..f.name)
    end
  end
  for _,f in ipairs(files) do
    if f.changed~=false then
      if f.hadOld then
        writeFile('.fleet-update-restore',readFile(f.backup))
        if fs.exists(f.name) then fs.delete(f.name) end
        fs.move('.fleet-update-restore',f.name)
        assert(checksum(readFile(f.name),true)==f.oldChecksum,'Restore verification failed: '..f.name)
      elseif fs.exists(f.name) then fs.delete(f.name) end
    end
  end
  fs.delete(TXPATH)
  if fs.exists(TXPATH..'.new') then fs.delete(TXPATH..'.new') end
  return 'Previous file restored; control remains stopped'
end
local function recoverUpdate()
  local t=loadUpdate()
  if t and t.state~='CONFIRMED' and t.state~='RESTARTING' then restoreUpdate() end
end

local function spaceRequired(manifest)
  local needed,largest=32768,0
  assert(type(manifest)=='table' and #manifest>=1 and #manifest<=3,'Invalid preflight manifest')
  local seen={}
  for _,f in ipairs(manifest)do
    assert((f.name=='fleet.lua' or f.name=='fleet_admin.lua' or f.name=='startup.lua') and not seen[f.name],'Invalid preflight filename');seen[f.name]=true
    assert(finite(f.size) and f.size>=0 and f.size<=1048576 and f.size%1==0,'Missing/invalid bundle size')
    local old=fs.exists(f.name) and #readFile(f.name) or 0
    needed=needed+f.size+2*old;largest=math.max(largest,f.size,old)
  end
  return needed+2*largest
end
local function preflightSpace(manifest)
  local need=spaceRequired(manifest)
  assert(fs.getFreeSpace,'Storage preflight unavailable')
  local free=fs.getFreeSpace('')
  assert(free=='unlimited' or finite(free),'Unknown free space')
  assert(free=='unlimited' or free>=need,'Out of space: need '..need..' bytes, free '..tostring(free)..', short '..(type(free)=='number' and math.max(0,need-free) or 0)..' bytes')
  return {required=need,free=free}
end
if args[1]=='test_api' then return {spaceRequired=spaceRequired,preflightSpace=preflightSpace,checksum=checksum,validName=validName,replaceFile=replaceFile,recover=recover,loadUpdate=loadUpdate,restoreUpdate=restoreUpdate,recoverUpdate=recoverUpdate} end
local id=ROLE.slot
assert(isTarget(id),'fleet_admin runs on 10-14 / 16-19')
local native=term.current()
local flight={state='STOPPED',error=nil,runtime=nil,co=nil,filter=nil,terminal=native,runVersion=nil}
local zeroTask
local zero={state="UNKNOWN",time=0}
local ZERO_TIMEOUT=id>=16 and 5 or 3
local adminTask
local controlJob
local boot=uid()
local responseCache,responseOrder={},{}
local function fileVersion(name)
  if not fs.exists(name) then return {exists=false} end
  local ok,data=pcall(readFile,name)
  if not ok then return {exists=true,error=tostring(data)} end
  return {exists=true,size=#data,checksum=checksum(data),version=data:match("\nlocal VERSION='([^']+)'") or data:match("^local VERSION='([^']+)'")
    or data:match("\nlocal ADMIN_VERSION='([^']+)'") or data:match("^local ADMIN_VERSION='([^']+)'")}
end
local runningAdmin=fileVersion('fleet_admin.lua')
local function active()
  if not flight.co then return false end
  local r=flight.runtime
  if not r or not finite(r.time) or now()-r.time>2000 then return nil end
  return r.active==true
end
local function safeZero()
  local errors={}
  if id==12 or id==13 or id==14 then
    for _,side in ipairs({'left','right','top','bottom'}) do
      local ok,err=pcall(redstone.setAnalogOutput,side,0)
      if not ok then errors[#errors+1]=tostring(err) end
    end
  elseif id>=16 then
    local names=discoverFine(false)
    if #names<1 then errors[#errors+1]='No Fine peripherals available for zero verification' end
    local tasks={}
    for _,name in ipairs(names) do
      local n=name
      tasks[#tasks+1]=function()
        local ok,err=pcall(peripheral.call,n,'setPowerNormalized',0)
        if not ok then errors[#errors+1]=n..': '..tostring(err) end
      end
    end
    parallel.waitForAll(table.unpack(tasks))
  elseif id==10 then
    for _,to in ipairs({12,13,14,16,17,18,19}) do
      local actual=ROLE.resolve(to);if actual then pcall(rednet.send,actual,{kind='STOP',time=now()},'fleet_v2') end
    end
  elseif id==11 then local actual=ROLE.resolve(10);if actual then pcall(rednet.send,actual,{kind='STOP',time=now()},'fleet_v2') end end
  return #errors==0,table.concat(errors,'; ')
end
local function beginZero()
  if zeroTask then return end
  zero={state='PENDING',time=now()}
  zeroTask={terminal=native,deadline=os.clock()+ZERO_TIMEOUT,started=false,co=coroutine.create(function()
    local ok,why=safeZero()
    zero={state=ok and 'OK' or 'FAILED',error=not ok and why or nil,time=now()}
  end)}
end
local function stoppedSafe() return not flight.co and zero.state=='OK' end
local function launch()
  if flight.co then return false,'Already running' end
  if zeroTask then return false,'Safety zero still pending' end
  if zero.state=='TIMEOUT' or zero.state=='FAILED' then return false,'Safety output unverified: '..tostring(zero.error) end
  if fs.exists('.fleet-admin-commit') then return false,'Unresolved file recovery journal' end
  local env=setmetatable({FLEET_RUN=uid(),FLEET_ROLES=ROLE},{__index=_ENV});env._G=env
  local tx=loadUpdate();env.FLEET_UPDATE_LOCK=tx~=nil and (tx.state~='CONFIRMED' or tx.secured and not tx.released)
  if tx and tx.secured and not tx.released then env.FLEET_MAINTENANCE={token=tx.token,secured=true,expires=os.clock()+30} end
  local fn,err=loadfile('fleet.lua',nil,env)
  if not fn then flight.state='FAILED';flight.error=tostring(err);return false,flight.error end
  flight.token=env.FLEET_RUN
  if tx and (tx.state=='APPLIED' or tx.state=='RESTARTING') then tx.state='APPLIED';tx.launched=flight.token;saveUpdate(tx) end
  flight.env=env
  zero={state='UNKNOWN',time=now()}
  flight.state='STARTING';flight.error=nil;flight.runtime=nil
  flight.runVersion=fileVersion('fleet.lua')
  flight.co=coroutine.create(fn);flight.filter=nil;flight.terminal=native
  os.queueEvent('fleet_supervisor_wake')
  return true
end
local function requestStop()
  if not flight.co then beginZero();return true end
  flight.state='STOPPING';flight.stopDeadline=os.clock()+1
  os.queueEvent('fleet_managed_stop',ROLE.actual)
  return true
end
local function snapshot()
  if flight.env and flight.env.FLEET_MAINTENANCE and flight.env.FLEET_UPDATE_LOCK then flight.env.FLEET_MAINTENANCE.expires=os.clock()+30 end
  return {id=id,actualId=ROLE.actual,role=ROLE.role,roles=ROLE.snapshot(),boot=boot,state=flight.state,running=flight.co~=nil,active=active(),
    zero=zero,error=flight.error,runtime=flight.runtime,adminError=flight.adminError,adminVersion=ADMIN_VERSION,
    runningCode=flight.runVersion,runningAdmin=runningAdmin,nodeVersion=FLEET_NODE_VERSION,bootError=fs.exists('fleet_boot_error.txt') and readFile('fleet_boot_error.txt') or nil,files={fleet=fileVersion('fleet.lua'),admin=fileVersion('fleet_admin.lua'),startup=fileVersion('startup.lua')},
    recovery=fs.exists('.fleet-admin-commit'),update=loadUpdate(),storage={free=fs.getFreeSpace and fs.getFreeSpace('')},capabilities={update=1,delete=1,bundle=1,boundedStop=1,maintenance=1,spacePreflight=1},time=now()}
end
local function service()
  local net=network(id)
  if fs.exists('.fleet-admin-commit') then pcall(recover) end
  local cache,cacheOrder=responseCache,responseOrder
  if fs.exists('.fleet-admin-reboot') then
    local ok,record=pcall(function()return textutils.unserialize(readFile('.fleet-admin-reboot'))end)
    if ok and type(record)=='table' and type(record.rid)=='string' and type(record.body)=='table' then cache[record.rid]=record.body end
  end
  local transfer,work=nil,nil
  local forwarded={}
  local quota,quotaTime=0,os.clock()
  local function respond(m,state,detail,extra)
    local body={state=state,detail=detail,info=extra}
    cache[m.rid]=body;cacheOrder[#cacheOrder+1]=m.rid
    while #cacheOrder>160 do local old=table.remove(cacheOrder,1);if old~=m.rid then cache[old]=nil end end
    net.send(net.envelope(15,m.rid,'RESULT',body),RESPONSE)
  end
  local function stopTransfer()
    if transfer then
      transfer.cancelled=true
      if not work then pcall(fs.delete,transfer.path);transfer=nil end
    end
  end
  local function process(m)
    local b=m.body
    if controlJob and os.clock()>controlJob.deadline then
      respond(controlJob.request,'FAILED','Lifecycle timeout expired',snapshot());controlJob=nil
    end
    if cache[m.rid] and cache[m.rid].state=='RECEIVED' and (m.op=='START' or m.op=='STOP' or m.op=='RESTART' or m.op=='REBOOT')
      and (not controlJob or controlJob.request.rid~=m.rid) then
      respond(m,'FAILED','Lifecycle interrupted; retry with a new request',snapshot());return
    end
    if cache[m.rid] then net.send(net.envelope(15,m.rid,'RESULT',cache[m.rid]),RESPONSE);return end
    if m.op=='STATUS' or m.op=='VERSION' then respond(m,'RECEIVED','Service responding',snapshot());return end
    if m.op=='UPDATE_PREFLIGHT' then
      assert(stoppedSafe() and b.grounded==true,'Verified STOP required for preflight')
      respond(m,'RECEIVED','Storage preflight OK',preflightSpace(b.files));return
    end
    if m.op=='UPDATE_RELEASE' then
      local e=flight.env
      assert(e and e.FLEET_MAINTENANCE and e.FLEET_MAINTENANCE.token==b.token,'Maintenance token mismatch')
      assert(active()==false and flight.runtime and not flight.runtime.error,'Inactive healthy runtime required')
      if id==10 then
        local r=flight.runtime;local h=r.maintenance
        if r.state~='READY / OFF' or not h or not h.zero or not h.readySince or os.clock()-h.readySince<1 or h.frames<4 then respond(m,'RECHECK','Heartbeat stabilization required before unlocking ARM',snapshot());return end
      end
      local t=loadUpdate();if t then assert(t.state=='CONFIRMED' and t.token==b.token,'Update not committed');t.released=true;saveUpdate(t) end
      e.FLEET_UPDATE_LOCK=false;e.FLEET_MAINTENANCE=nil
      respond(m,'RECEIVED','Maintenance complete; controller remains disarmed',snapshot());return
    end
    if m.op=='UPDATE_RECOVER' then
      assert(stoppedSafe() and b.grounded==true,'Verified STOP required for recovery')
      assert(not work and not transfer,'Transfer still settling; retry recovery')
      if controlJob then respond(controlJob.request,'FAILED','Recovery superseded stale lifecycle');controlJob=nil end
      local ok,why=pcall(function()
        recover()
        local t=loadUpdate()
        if t and t.state~='CONFIRMED' then restoreUpdate() end
      end)
      respond(m,ok and 'RECOVERED' or 'FAILED',ok and 'Previous transactions resolved' or ('MANUAL RECOVERY REQUIRED: '..tostring(why)),snapshot());return
    end
    if m.op=='UPDATE_PREPARE' then
      assert(stoppedSafe() and active()==false and b.grounded==true,'STOP, verified zero and landed confirmation required')
      assert(not controlJob and not transfer and not work,'Management busy')
      assert(not fs.exists('.fleet-admin-commit'),'Unresolved recovery journal')
      preflightSpace(b.files)
      local old=loadUpdate()
      if old and old.state=='CONFIRMED' then fs.delete(TXPATH);old=nil end
      assert(not old,'Pending update requires ROLLBACK before another UPDATE')
      assert(type(b.token)=='string' and b.token:match('^[%w%-]+$') and #b.token<=100,'Invalid update token')
      assert(type(b.checksum)=='string' and b.checksum:match('^%x%x%x%x%x%x%x%x$'),'Invalid update checksum')
      local t={token=b.token,name='fleet.lua',checksum=b.checksum,state='PREPARED',secured=true,files={}}
      local manifest=b.files or {{name='fleet.lua',checksum=b.checksum}}
      assert(type(manifest)=='table' and #manifest>=1 and #manifest<=3,'Invalid bundle manifest')
      local seen={}
      for _,entry in ipairs(manifest) do
        local name=entry.name
        assert((name=='fleet.lua' or name=='fleet_admin.lua' or name=='startup.lua') and not seen[name],'Invalid/duplicate bundle filename')
        seen[name]=true
        assert(type(entry.checksum)=='string' and entry.checksum:match('^%x%x%x%x%x%x%x%x$'),'Invalid bundle checksum')
        local old=fileVersion(name)
        local f={name=name,checksum=entry.checksum,hadOld=old.exists,oldChecksum=old.checksum,changed=old.checksum~=entry.checksum}
        if f.changed and f.hadOld then f.backup=name..'.bak.update-'..uid();fs.copy(name,f.backup) end
        t.files[#t.files+1]=f
      end
      assert(seen['fleet.lua'],'fleet.lua missing from manifest')
      saveUpdate(t);respond(m,'PREPARED','Rollback copy retained',snapshot());return
    end
    if m.op=='UPDATE_CHECK' or m.op=='UPDATE_COMMIT' then
      local t=assert(loadUpdate(),'No update transaction');assert(t.token==b.token,'Update token mismatch')
      local info=snapshot();local runtime=flight.runtime
      assert(flight.co and runtime and now()-runtime.time<=2000,'Fresh runtime heartbeat required')
      assert(not flight.error and not runtime.error and runtime.state~='FAULT','Runtime error: '..tostring(flight.error or runtime.error or runtime.state))
      assert(active()==false,'UPDATE requires inactive control')
      local function stable()
        if id~=10 then return true end
        local r=flight.runtime;local h=r and r.maintenance
        return r and r.state=='READY / OFF' and h and h.token==t.token and h.zero and h.frames>=4 and h.readySince and os.clock()-h.readySince>=1
      end
      if not stable() then respond(m,'RECHECK','Controller heartbeat stabilization pending',info);return end
      assert(info.runningCode and info.runningCode.checksum==t.checksum,'Running code checksum mismatch')
      assert(info.files.fleet.checksum==t.checksum,'On-disk checksum mismatch')
      for _,f in ipairs(t.files or {}) do assert(fileVersion(f.name).checksum==f.checksum,'Bundle disk mismatch: '..f.name) end
      for _,f in ipairs(t.files or {}) do if f.name=='fleet_admin.lua' then assert(runningAdmin.checksum==f.checksum,'Running admin mismatch') end end
      assert(flight.runtime and not flight.runtime.error and now()-flight.runtime.time<=2000,'Runtime changed during verification')
      if not stable() then respond(m,'RECHECK','Heartbeat changed during disk verification',snapshot());return end
      if m.op=='UPDATE_COMMIT' then t.state='CONFIRMED';saveUpdate(t);if fs.exists('fleet_hold.lua') then fs.delete('fleet_hold.lua') end;if fs.exists('fleet_boot_recovery.txt') then fs.delete('fleet_boot_recovery.txt') end;if fs.exists('fleet_boot_error.txt') then fs.delete('fleet_boot_error.txt') end end
      respond(m,m.op=='UPDATE_COMMIT' and 'COMMITTED' or 'VERIFIED','Running and disk versions verified',snapshot());return
    end
    if m.op=='UPDATE_ROLLBACK' then
      assert(b.grounded==true,'Landed confirmation required')
      local t=loadUpdate();assert(not t or t.token==b.token,'Update token mismatch')
      if controlJob then respond(controlJob.request,'FAILED','Preempted by rollback');controlJob=nil end
      stopTransfer();requestStop();controlJob={op='ROLLBACK',request=m,deadline=os.clock()+ZERO_TIMEOUT+4}
      respond(m,'RECEIVED','Stopping before restoring previous file');return
    end
    if m.op=='UPDATE_CLEAN' then
      local t=assert(loadUpdate(),'No confirmed update');assert(t.token==b.token and t.state=='CONFIRMED','Update not confirmed')
      local info=snapshot();assert(flight.co and flight.runtime and now()-flight.runtime.time<=2000 and not flight.error,'Runtime not healthy')
      assert(info.runningCode and info.runningCode.checksum==t.checksum and info.files.fleet.checksum==t.checksum,'Version changed; keep backups')
      assert(not transfer and not work and not controlJob and not fs.exists('.fleet-admin-commit'),'Cleanup blocked by active transaction')
      local deleted=0
      for _,name in ipairs(fs.list('')) do
        local owner=name:match('^([%w_%-]+%.[%w]+)%.bak%.')
        if (owner and validName(owner)) or name:match('^%.fleet%-upload%-') or name=='.fleet-admin-reboot' or name=='.fleet-update-restore' then
          if not fs.isDir(name) then fs.delete(name);deleted=deleted+1 end
        end
      end
      fs.delete(TXPATH);if fs.exists(TXPATH..'.new') then fs.delete(TXPATH..'.new') end
      respond(m,'CLEANED','Confirmed update; removed '..deleted..' backup/temp files',snapshot());return
    end
    if m.op=='DELETE' then
      assert(validName(b.name),'Only a plain local filename is allowed')
      local core=b.name=='fleet.lua' or b.name=='fleet_admin.lua' or b.name=='startup.lua'
      assert(not core or b.confirm==true,'Core file requires --confirm')
      assert(not core or (not flight.co and active()==false),'STOP before deleting a core file')
      assert(not controlJob and not transfer and not work and not loadUpdate(),'Transaction pending')
      if fs.exists(b.name) then assert(not fs.isDir(b.name),'Directory deletion is not allowed');fs.delete(b.name) end
      respond(m,'DELETED','Deleted '..b.name);return
    end
    if m.op=='STOP' then
      stopTransfer()
      if controlJob then respond(controlJob.request,'FAILED','Preempted by STOP');controlJob=nil end
      requestStop();controlJob={op='STOP',request=m,deadline=os.clock()+ZERO_TIMEOUT+3}
      respond(m,'RECEIVED','Cooperative stop requested');return
    end
    if m.op=='START' or m.op=='RESTART' or m.op=='REBOOT' then
      if controlJob then respond(m,'FAILED','Another lifecycle command is pending');return end
      if m.op~='START' and (b.grounded~=true or active()~=false) then
        respond(m,'FAILED','STOP first; --grounded and inactive control required');return
      end
      if m.op=='START' and flight.co then
        if flight.runtime and now()-flight.runtime.time<=2000 and not flight.error and not flight.runtime.error and flight.runtime.state~='FAULT' then respond(m,'RUNNING','Already running',snapshot())
        else controlJob={op='START',request=m,deadline=os.clock()+4,stage='STARTING'};respond(m,'RECEIVED','Waiting for existing runtime heartbeat') end
        return
      end
      if m.op=='REBOOT' then
        stopTransfer();requestStop();controlJob={op='REBOOT',request=m,deadline=os.clock()+ZERO_TIMEOUT+3}
      elseif m.op=='RESTART' then
        stopTransfer();requestStop();controlJob={op='RESTART',request=m,deadline=os.clock()+ZERO_TIMEOUT+7,stage='STOPPING'}
      else
        local ok,err=launch()
        if not ok then respond(m,'FAILED',err);return end
        controlJob={op='START',request=m,deadline=os.clock()+4,stage='STARTING'}
      end
      respond(m,'RECEIVED','Lifecycle command accepted');return
    end
    if m.op=='FILE_BEGIN' then
      if fs.exists('.fleet-admin-commit') then respond(m,'FAILED','Unresolved recovery journal');return end
      if transfer then respond(m,'FAILED','Transfer busy');return end
      local tx=loadUpdate()
      if tx then
        local matched=false
        for _,f in ipairs(tx.files or {tx}) do if f.name==b.name and f.checksum==b.checksum then matched=true end end
        assert(tx.token==b.update and matched,'Pending UPDATE owns this file')
      end
      if not validName(b.name) or not finite(b.size) or b.size<0 or b.size>1048576 or b.size%1~=0
        or type(b.checksum)~='string' or not b.checksum:match('^%x%x%x%x%x%x%x%x$')
        or type(b.transfer)~='string' or not b.transfer:match('^[%w%-]+$') or #b.transfer>100 then
        respond(m,'FAILED','Invalid file metadata');return
      end
      local path='.fleet-upload-'..b.transfer
      writeFile(path,'')
      transfer={name=b.name,size=b.size,checksum=b.checksum,path=path,token=b.transfer,
        bytes=0,index=0,seen=os.clock(),phase='RECEIVING'}
      respond(m,'RECEIVED','Metadata accepted');return
    end
    if m.op=='FILE_CHUNK' then
      local x=transfer
      if not x or x.token~=b.transfer or x.cancelled or x.phase~='RECEIVING' then respond(m,'FAILED','No matching transfer');return end
      if not finite(b.index) or b.index%1~=0 or type(b.data)~='string' or #b.data>4096 then respond(m,'FAILED','Invalid chunk');return end
      if b.index<=x.index then respond(m,'RECEIVED','Chunk already received',{index=x.index});return end
      if b.index~=x.index+1 or x.bytes+#b.data>x.size then respond(m,'FAILED','Chunk order/length mismatch');return end
      local h,err=fs.open(x.path,'ab');if not h then error(err or 'Cannot append stage') end
      local ok,why=pcall(h.write,b.data);h.close();if not ok then error(why) end
      x.index=b.index;x.bytes=x.bytes+#b.data;x.seen=os.clock()
      respond(m,'RECEIVED','Chunk stored',{index=x.index,bytes=x.bytes});return
    end
    if m.op=='FILE_END' then
      local x=transfer
      if not x or x.token~=b.transfer or x.cancelled or x.bytes~=x.size then respond(m,'FAILED','Incomplete file');return end
      x.phase='VERIFYING';work={request=m,transfer=x};respond(m,'RECEIVED','Complete file staged');return
    end
    respond(m,'FAILED','Unknown management command')
  end
  local function incoming()
    while true do
      local e,side,ch,reply,m=os.pullEventRaw()
      if e=='modem_message' and (ch==REQUEST or ch==RESPONSE) and net.valid(m) then
        local loop=false
        for _,v in ipairs(m.route) do if v==id then loop=true end end
        if not loop and m.to==id and ch==REQUEST and m.from==15 then
          local ok,err=pcall(process,m)
          if not ok then respond(m,'FAILED',tostring(err)) end
        elseif not loop and (id==10 or id==11) and m.ttl>0 and not forwarded[m.packet]
          and ((ch==REQUEST and m.from==15 and isTarget(m.to)) or (ch==RESPONSE and m.to==15 and isTarget(m.from))) then
          if os.clock()-quotaTime>=1 then quota=0;quotaTime=os.clock() end
          local priority=m.op=='STOP'
          if quota<40 or priority then
            quota=quota+1;forwarded[m.packet]=os.clock()
            local n={};for k,v in pairs(m) do n[k]=v end
            n.route={};for _,v in ipairs(m.route) do n.route[#n.route+1]=v end
            n.route[#n.route+1]=id;n.ttl=m.ttl-1
            net.send(n,ch,side)
          end
        end
      end
    end
  end
  local function worker()
    while true do
      if work then
        local w=work;local x=w.transfer
        local ok,err=pcall(function()
          assert(not x.cancelled,'Transfer cancelled')
          local data=readFile(x.path)
          assert(#data==x.size and checksum(data,true)==x.checksum,'Length/checksum mismatch')
          if x.name:match('%.lua$') then local fn,why=load(data,'@'..x.name,'t',{});assert(fn,why) end
          assert(not x.cancelled,'Transfer cancelled')
          respond(w.request,'VERIFIED','Length, checksum and Lua syntax verified')
          sleep(0)
          assert(not x.cancelled,'Transfer cancelled')
          x.phase='COMMITTING'
          local backup=replaceFile(x.path,x.name,x.checksum,function()return x.cancelled end)
          local tx=loadUpdate();if tx then tx.state='APPLIED';saveUpdate(tx) end
          respond(w.request,'APPLIED','File replaced; running code not restarted',{name=x.name,checksum=x.checksum,backup=backup})
        end)
        if not ok then respond(w.request,'FAILED',tostring(err));pcall(fs.delete,x.path) end
        if transfer==x then transfer=nil end;work=nil
      end
      sleep(0.05)
    end
  end
  local function maintenance()
    while true do
      net.scan()
      for packet,t in pairs(forwarded) do if os.clock()-t>15 then forwarded[packet]=nil end end
      if transfer and not work and os.clock()-transfer.seen>30 then stopTransfer() end
      local job=controlJob
      if job then
        if job.op=='ROLLBACK' and stoppedSafe() then
          local ok,why=pcall(restoreUpdate);respond(job.request,ok and 'ROLLED_BACK' or 'FAILED',tostring(why),snapshot());if controlJob==job then controlJob=nil end
        elseif job.op=='STOP' and stoppedSafe() then
          respond(job.request,'STOPPED','Output zero writes acknowledged; admin alive',snapshot());if controlJob==job then controlJob=nil end
        elseif job.op=='REBOOT' and stoppedSafe() then
          local info=snapshot()
          local body={state='REBOOTING',detail='Reboot accepted',info=info}
          writeFile('.fleet-admin-reboot',textutils.serialize({rid=job.request.rid,body=body}))
          local tx=loadUpdate();if tx and job.request.body.update==tx.token then tx.state='RESTARTING';saveUpdate(tx) end
          respond(job.request,'REBOOTING','Reboot accepted',info);if controlJob==job then controlJob=nil end;sleep(0.3);os.reboot()
        elseif job.op=='RESTART' and job.stage=='STOPPING' and stoppedSafe() then
          local ok,err=launch();job.stage='STARTING'
          if not ok then respond(job.request,'FAILED',err);if controlJob==job then controlJob=nil end end
        elseif (job.op=='START' or job.stage=='STARTING') and flight.co and flight.runtime and now()-flight.runtime.time<=2000 then
          local good=not flight.error and not flight.runtime.error and flight.runtime.state~='FAULT'
          if good then respond(job.request,'RUNNING','Fleet runtime heartbeat received',snapshot());if controlJob==job then controlJob=nil end
          elseif os.clock()>job.deadline then respond(job.request,'FAILED',tostring(flight.error or flight.runtime.error or flight.runtime.state),snapshot());if controlJob==job then controlJob=nil end end
        elseif (job.op=='START' or job.stage=='STARTING') and not flight.co then
          respond(job.request,'FAILED',flight.error or 'Fleet exited before runtime heartbeat',snapshot());if controlJob==job then controlJob=nil end
        elseif not flight.co and (zero.state=='TIMEOUT' or zero.state=='FAILED') then respond(job.request,'FAILED',zero.error or 'Safety output unverified',snapshot());if controlJob==job then controlJob=nil end
        elseif os.clock()>job.deadline then respond(job.request,'FAILED','Lifecycle timeout; retry allowed',snapshot());if controlJob==job then controlJob=nil end end
      end
      if not flight.co and flight.error and zero.state=='OK' then
        local tx=loadUpdate()
        if tx and tx.state=='APPLIED' and tx.launched and tx.launched==flight.token then
          local ok,why=pcall(restoreUpdate)
          if not ok then flight.adminError='Automatic rollback: '..tostring(why) end
        end
      end
      sleep(0.1)
    end
  end
  parallel.waitForAll(incoming,worker,maintenance,ROLE.run)
end
local function resumeTask(task,event)
  local previous=term.current();term.redirect(task.terminal or native)
  local ok,filter=coroutine.resume(task.co,table.unpack(event or {}))
  task.terminal=term.current();term.redirect(previous)
  task.filter=filter
  return ok,filter,coroutine.status(task.co)=='dead'
end
local recovered,recoveryError=pcall(function()recover();recoverUpdate()end)
if not recovered then flight.state='FAILED';flight.error='Recovery: '..tostring(recoveryError) end
local function startAdmin()
  adminTask={co=coroutine.create(service),terminal=native,filter=nil}
  local ok,err=resumeTask(adminTask,{})
  if not ok then adminTask=nil;flight.adminError=tostring(err) end
end
startAdmin()
local startupTx=loadUpdate()
if recovered and not fs.exists('fleet_hold.lua') and not (startupTx and startupTx.state~='CONFIRMED') and settings.get('fleet.autostart',true) then launch() end
local tick=os.startTimer(0.1)
while true do
  if flight.co and not flight.started then
    flight.started=true
    local ok,err,dead=resumeTask(flight,{})
    if not ok or dead then
      flight.co=nil;flight.started=nil;flight.state='FAILED';flight.error=tostring(err or 'Fleet exited at startup');beginZero()
    end
  end
  local event=table.pack(os.pullEventRaw())
  if event[1]=='fleet_runtime' and event[2]==ROLE.actual and flight.co and type(event[3])=='table' and event[3].run==flight.token then
    flight.runtime=event[3]
    if flight.state~='STOPPING' then flight.state='RUNNING' end
  elseif event[1]=='fleet_run_error' and event[2]==ROLE.actual and event[4]==flight.token then flight.error=tostring(event[3]) end
  if flight.co and (not flight.filter or flight.filter==event[1] or event[1]=='terminate') then
    local ok,err,dead=resumeTask(flight,event)
    if not ok or dead then
      local stopping=flight.state=='STOPPING'
      flight.co=nil;flight.started=nil
      flight.state=stopping and 'STOPPING' or 'FAILED'
      flight.error=not ok and tostring(err) or flight.error
      beginZero()
    end
  end
  if zeroTask then
    local z=zeroTask
    if os.clock()>z.deadline then
      zero={state='TIMEOUT',time=now(),error='SAFETY TIMEOUT: zero write ACK missing; retry STOP'};zeroTask=nil
    elseif not z.started or not z.filter or z.filter==event[1] then
      local first=not z.started;z.started=true
      local ok,err,dead=resumeTask(z,first and {} or event)
      if not ok then zero={state='FAILED',time=now(),error=tostring(err)} end
      if not ok or dead then zeroTask=nil end
    end
    if not zeroTask and not flight.co then
      flight.state=zero.state=='OK' and 'STOPPED' or 'FAILED'
      if zero.state~='OK' then flight.error=zero.error end
    end
  end
  if adminTask and event[1]~='terminate' and (not adminTask.filter or adminTask.filter==event[1]) then
    local ok,err,dead=resumeTask(adminTask,event)
    if not ok or dead then
      flight.adminError=tostring(err);adminTask=nil
      flight.adminError=tostring(err)..' / lifecycle resumes after service restart'
    end
  end
  if event[1]=='timer' and event[2]==tick then
    if not adminTask then startAdmin() end
    if flight.co and flight.state=='STOPPING' and os.clock()>flight.stopDeadline then
      flight.co=nil;flight.started=nil
      beginZero()
    end
    tick=os.startTimer(0.1)
  end
end
