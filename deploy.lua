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
local DEPLOY_VERBOSE=false
local ADMIN_VERSION='2026.10.20-r16'
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

local function parseTargets(text)
  if text=='all' or text=='ALL' then local n={};for _,id in ipairs(TARGETS) do n[#n+1]=id end;return n end
  local result,seen={},{}
  for piece in tostring(text or ''):gmatch('[^,]+') do
    local named=ROLE and ROLE.slots[piece:upper()]
    if named and isTarget(named) then if not seen[named] then result[#result+1]=named;seen[named]=true end
    else
    local a,b=piece:match('^(%d+)%-(%d+)$')
    if not a then a=piece:match('^(%d+)$');b=a end
    assert(a and b,'Targets: all / 16-19 / 10,11,16')
    a,b=tonumber(a),tonumber(b);assert(a<=b and b-a<=20,'Invalid ID range')
    for actual=a,b do local id=ROLE and ROLE.dynamic and ROLE.logical(actual) or isTarget(actual) and actual or ROLE and ROLE.logical(actual)
      assert(id and isTarget(id),'Unsupported/unregistered target '..actual);if not seen[id] then result[#result+1]=id;seen[id]=true end end
    end
  end
  assert(#result>0,'Select at least one target');return result
end
local function parseCommand(words)
  local op=(words[1] or ''):upper()
  local allowed={STATUS=true,VERSION=true,FILE=true,START=true,STOP=true,RESTART=true,REBOOT=true,UPDATE=true,DELETE=true}
  assert(allowed[op],'Command: UPDATE STATUS VERSION FILE START STOP RESTART REBOOT DELETE')
  local path,target,name
  if op=='FILE' then
    path=words[2];target=words[3];name=words[4] and words[4]:sub(1,2)~='--' and words[4] or path and fs.getName(path)
    assert(path and validName(name),'FILE <local-file> <targets> [remote-name]')
  elseif op=='DELETE' then name=words[2];target=words[3];assert(validName(name),'DELETE <filename> <targets> [--confirm]')
  else target=words[2] end
  local grounded=false;for _,v in ipairs(words) do if v=='--grounded' then grounded=true end end
  if op=='RESTART' or op=='REBOOT' then assert(grounded,'Use --grounded after landing/stopping; STOP is always available') end
  local clean,confirm=false,false
  for _,v in ipairs(words) do if v=='--clean' then clean=true elseif v=='--confirm' then confirm=true end end
  if op=='UPDATE' then path='fleet.lua';name='fleet.lua' end
  return {op=op,targets=parseTargets(target),path=path,name=name,grounded=grounded,clean=clean,confirm=confirm}
end
local GITHUB_REPO='robokorean/cc-ship'
local GITHUB_MANIFEST='https://raw.githubusercontent.com/'..GITHUB_REPO..'/main/manifest.lua'
local BUNDLE_FILES={'fleet.lua','fleet_admin.lua','fleet_view.lua','deploy.lua','startup_15.lua','startup_node.lua','startup_gps.lua'}
local function sourceVersion(d)
  return d:match("^local VERSION='([^']+)'") or d:match("\nlocal VERSION='([^']+)'") or d:match("^local ADMIN_VERSION='([^']+)'") or d:match("\nlocal ADMIN_VERSION='([^']+)'") or 'unversioned'
end
local HTTP_ABANDONED={}
local function httpRead(url,limit)
  url=url..'?fleet='..uid()
  assert(http and http.request,'CC HTTP unavailable; enable HTTP for GitHub UPDATE')
  local accepted,why=http.request({url=url,binary=true})
  assert(accepted,'GitHub HTTP request rejected: '..tostring(why))
  local timer=os.startTimer(20)
  local handle
  while true do
    local e,a,b,c=os.pullEvent()
    if e=='http_success' and a==url then handle=b;break end
    if e=='http_failure' and a==url then if c then pcall(c.close)end;os.cancelTimer(timer);error('GitHub HTTP failed: '..tostring(b),0)end
    if e=='timer' and a==timer then HTTP_ABANDONED[url]=true;error('GitHub HTTP timeout; installed files untouched',0)end
  end
  os.cancelTimer(timer)
  local ok,result=pcall(function()
    assert(handle.getResponseCode()==200,'GitHub HTTP status '..tostring(handle.getResponseCode()))
    local parts,total={},0
    while true do
      local d=handle.read(math.min(4096,limit-total+1))
      if not d then break end
      assert(type(d)=='string','Invalid GitHub binary response')
      if #d==0 then break end
      total=total+#d;assert(total<=limit,'GitHub response exceeds size limit');parts[#parts+1]=d
    end
    assert(total>0,'Empty GitHub response');return table.concat(parts)
  end)
  pcall(handle.close);assert(ok,result);return result
end
local function fetchBundle()
  local raw=httpRead(GITHUB_MANIFEST,16384)
  local m=textutils.unserialize(raw:gsub('^%s*return%s+',''))
  assert(type(m)=='table' and m.schema==1 and m.repo==GITHUB_REPO and type(m.version)=='string' and #m.version>0 and #m.version<=80,'Invalid GitHub manifest')
  assert(type(m.ref)=='string' and #m.ref==40 and m.ref:match('^%x+$'),'Manifest requires a fixed 40-character commit SHA')
  assert(type(m.files)=='table','Manifest files missing')
  local data,sums,total={},{},0
  local allowed={};for _,name in ipairs(BUNDLE_FILES)do allowed[name]=true end
  for name in pairs(m.files)do assert(allowed[name],'Unknown manifest file: '..tostring(name))end
  for _,name in ipairs(BUNDLE_FILES)do
    local f=m.files[name]
    if name~='startup_gps.lua' then assert(type(f)=='table','Manifest missing '..name)end
    if f then
      assert(type(f)=='table' and finite(f.size) and f.size%1==0 and f.size>0 and f.size<=1048576,'Invalid manifest size: '..name)
      assert(type(f.checksum)=='string' and f.checksum:match('^%x%x%x%x%x%x%x%x$') and type(f.version)=='string','Invalid manifest checksum/version: '..name)
      total=total+f.size;assert(total<=4194304,'Bundle RAM limit exceeded')
      local d=httpRead('https://raw.githubusercontent.com/'..GITHUB_REPO..'/'..m.ref..'/'..name,f.size)
      assert(#d==f.size and checksum(d,true)==f.checksum:lower(),'GitHub length/checksum mismatch: '..name)
      local fn,err=load(d,'@'..name,'t',{});assert(fn,err)
      assert(sourceVersion(d)==f.version,'GitHub version mismatch: '..name)
      data[name]=d;sums[name]=f.checksum:lower()
    end
  end
  return data,sums,{repo=GITHUB_REPO,ref=m.ref,version=m.version}
end
if args[1]=='test_api' then return {httpRead=httpRead,fetchBundle=fetchBundle,sourceVersion=sourceVersion,checksum=checksum,parseTargets=parseTargets,parseCommand=parseCommand} end
assert(ROLE.slot==15,'deploy requires ADMIN role')
local net=network(15)
local waiting={}
local reachable={}
local lastSend=0
local client=uid()
local outcomes={}
local activeCommand
local updateStage="READY"
local updateFinished=false
local updateSuccess
local commandRunning=false
local lastReportDetail
local bundleSource
local function saveReport(detail)
  if detail then lastReportDetail=detail end
  detail=lastReportDetail
  return pcall(writeFile,'fleet_deploy_last.txt',textutils.serialize({version=ADMIN_VERSION,source=bundleSource,command=activeCommand,time=now(),targets=outcomes,detail=detail,stage=updateStage,busy=commandRunning,finished=updateFinished,success=updateSuccess}))
end
local function log(id,state,detail)
  if DEPLOY_VERBOSE or activeCommand~='UPDATE' or state=='FAILED' or state=='OFFLINE' or state=='UNREACHABLE' or state=='TIMEOUT' then print(string.format('%s %s %-12s %s',tostring(ROLE.resolve(id) or id),ROLE.roles[id] or '',state,tostring(detail or ''))) end
  outcomes[id]=outcomes[id] or {};local o=outcomes[id]
  o.actualId=ROLE.resolve(id);o.role=ROLE.roles[id];o.state=state;o.detail=detail;o.time=now();o.history=o.history or {};o.history[#o.history+1]=state;o.events=o.events or {};o.events[#o.events+1]={state=state,detail=detail,time=now()};while #o.events>16 do table.remove(o.events,1) end
  while #o.history>32 do table.remove(o.history,1) end
  saveReport()
end
local function sendRequest(packet,priority)
  if not priority then
    lastSend=math.max(lastSend,os.clock())+0.1
    local remaining=lastSend-os.clock()
    if remaining>0 then sleep(remaining) end
  end
  packet.time=now();packet.packet=uid();packet.route={15};packet.ttl=3
  return net.send(packet,REQUEST)
end
local function terminal(op,state)
  if state=='FAILED' or state=='RECHECK' then return true end
  local finishes={UPDATE_PREPARE='PREPARED',UPDATE_CHECK='VERIFIED',UPDATE_COMMIT='COMMITTED',UPDATE_CLEAN='CLEANED',UPDATE_ROLLBACK='ROLLED_BACK',UPDATE_RECOVER='RECOVERED',DELETE='DELETED'}
  if finishes[op] then return state==finishes[op] end
  if op=='UPDATE_PREFLIGHT' or op=='UPDATE_RELEASE' or op=='STATUS' or op=='VERSION' or op=='FILE_BEGIN' or op=='FILE_CHUNK' then return state=='RECEIVED' end
  if op=='FILE_END' then return state=='APPLIED' end
  if op=='STOP' then return state=='STOPPED' end
  if op=='REBOOT' then return state=='REBOOTING' end
  return state=='RUNNING'
end
local function call(id,op,body,quiet)
  local rid=client..'-'..uid()
  local packet=net.envelope(id,rid,op,body)
  local slot={id=id,op=op,received=false};waiting[rid]=slot
  if not quiet then log(id,'SENT',op) end
  local sent=sendRequest(packet,op=='STOP')
  if sent==0 then waiting[rid]=nil;log(id,'UNREACHABLE',ROLE.networkError or 'No attached management modem');return nil end
  local started=os.clock();local retry=started
  local timeout=(op=='FILE_END' or op=='UPDATE_CLEAN') and 120 or (op=='STOP' or op=='RESTART' or op=='REBOOT' or op=='UPDATE_ROLLBACK') and 14 or 6
  while os.clock()-started<timeout do
    if FLEET15 and FLEET15.abort and op~='STOP' and op~='UPDATE_ROLLBACK' and op~='STATUS' and op~='UPDATE_RECOVER' then waiting[rid]=nil;log(id,'FAILED','Emergency STOP aborted update');return nil end
    if slot.response and terminal(op,slot.response.state) then
      waiting[rid]=nil
      if slot.response.state=='FAILED' then log(id,'FAILED',slot.response.detail);return nil,slot.response end
      return slot.response
    end
    if os.clock()-retry>=1 then sendRequest(packet,op=='STOP');retry=os.clock() end
    sleep(0.05)
  end
  waiting[rid]=nil
  local known=slot.received or (reachable[id] and os.clock()-reachable[id]<20)
  log(id,known and 'TIMEOUT' or 'OFFLINE',known and 'NETWORK TIMEOUT: known node, response delayed; no file failure inferred' or 'No service response / UNREACHABLE route')
  return nil
end
local function receiver()
  while true do
    local e,side,ch,reply,m=os.pullEventRaw()
    if (e=='http_success' or e=='http_failure') and HTTP_ABANDONED[side] then
      local h=e=='http_success' and ch or reply;if h then pcall(h.close)end;HTTP_ABANDONED[side]=nil
    end
    if e=='modem_message' and ch==RESPONSE and net.valid(m) and m.to==15 and m.op=='RESULT' then
      local slot=waiting[m.rid]
      if slot and m.from==slot.id and type(m.body.state)=='string' then
        reachable[slot.id]=os.clock()
        slot.received=true
        local changed=not slot.response or slot.response.state~=m.body.state
        slot.response=m.body
        if changed and slot.op~='FILE_CHUNK' then
          local route={};for _,id in ipairs(m.route) do route[#route+1]=tostring(id) end
          log(slot.id,m.body.state,(m.body.detail or '')..' [reply '..table.concat(route,'>')..'>15]')
        end
      end
    end
  end
end
local function updateFleet(command)
  local function checked(id,op,body)
    local deadline=os.clock()+8
    repeat
      local r=call(id,op,body)
      if not r or r.state~='RECHECK' then return r end
      local i=r.info;local rt=i and i.runtime
      if not i or i.active~=false or i.error or not rt or rt.error or not rt.maintenance then log(id,'FAILED','Unsafe maintenance recheck');return nil end
      sleep(.25)
    until os.clock()>=deadline
    log(id,'FAILED','Maintenance heartbeat recheck timeout');return nil
  end
  local stage='STOPPING'
  local function phase(p) if not DEPLOY_VERBOSE then print(p..'...') end;stage=p;updateStage=p;saveReport() end
  print('UPDATE START')
  local function many(fn)
    local tasks={};for _,id in ipairs(command.targets) do local n=id;tasks[#tasks+1]=function()fn(n)end end
    parallel.waitForAll(table.unpack(tasks))
  end
  for _,id in ipairs(TARGETS) do local found=false;for _,n in ipairs(command.targets) do found=found or n==id end;assert(found,'UPDATE requires all flight nodes') end
  if not command.grounded then write('SHIP MUST BE LANDED / SECURED. Type LANDED: ');assert(read()=='LANDED','Cancelled') end
  local token=uid();local before={};local prepared={};local bootstrapJobs={};local failed=false;local data={};local sums={}
  local function stopAll()
    local ok=call(10,'STOP',{})~=nil
    many(function(id)if id~=10 and not call(id,'STOP',{}) then ok=false end end)
    return ok
  end
  assert(FLEET15 and FLEET15.selfFormat==2 and FLEET15.preflightSelf,'Install/start r15 startup.lua on ADMIN before GitHub UPDATE')
  phase('GITHUB')
  local fetched,proposed,downloadSums,origin=pcall(fetchBundle)
  if not fetched then return false,'GitHub bundle: '..tostring(proposed)..'; installed files untouched' end
  bundleSource=origin;sums=downloadSums
  phase('STOPPING')
  many(function(id)local r=call(id,'STATUS',{});if r then before[id]=r.info else failed=true end end)
  if failed then stopAll();return false,'Communication preflight failed; no files applied' end
  if not stopAll() then return false,'STOP failed; files untouched, output confirmation required' end
  many(function(id)
    local r=call(id,'STATUS',{},true);local i=r and r.info
    if not i or i.running or i.active~=false or (i.capabilities and i.capabilities.boundedStop and (not i.zero or i.zero.state~='OK')) then
      log(id,'FAILED','Safety zero / stopped state not confirmed');failed=true
    else before[id]=i end
  end)
  if failed then return false,'STOP verification failed; no file changes' end
  local function needsBootstrap(i)
    return not i or not i.capabilities or i.capabilities.bundle~=1 or i.capabilities.spacePreflight~=2
      or not i.storage or i.storage.free==nil
  end
  phase('PREFLIGHT')
  local preflightOK,preflightError=pcall(function()
    assert(fs.exists('startup.lua'),'startup.lua missing; install startup_15.lua as startup.lua')
    FLEET15.recoverSelf(proposed)
    FLEET15.preflightSelf(proposed)
    for _,id in ipairs(command.targets)do
      local i=before[id]
      if needsBootstrap(i) then
        log(id,'BOOTSTRAP','Manager/storage status requires r16 bootstrap before final preflight')
      else
        local manifest={{name='fleet.lua',size=#proposed['fleet.lua'],checksum=sums['fleet.lua']},{name='fleet_admin.lua',size=#proposed['fleet_admin.lua'],checksum=sums['fleet_admin.lua']},{name='startup.lua',size=#proposed['startup_node.lua'],checksum=sums['startup_node.lua']}}
        local r=call(id,'UPDATE_PREFLIGHT',{files=manifest,grounded=true})
        assert(r,'ID '..tostring(ROLE.resolve(id) or id)..' storage preflight failed')
      end
    end
  end)
  if not preflightOK then return false,'Preflight: '..tostring(preflightError)..'; files untouched; SHIP STOPPED' end
  phase('RECOVERING')
  many(function(id)
    local i=before[id]
    local r
    if i.capabilities and i.capabilities.bundle==1 then r=call(id,'UPDATE_RECOVER',{grounded=true})
    elseif i.update then r=call(id,'UPDATE_ROLLBACK',{token=i.update.token,grounded=true})
    elseif i.recovery then log(id,'FAILED','MANUAL RECOVERY REQUIRED: old service has unresolved file journal');failed=true;return
    else r={state='RECOVERED'} end
    if not r then failed=true end
  end)
  if failed then return false,'Automatic journal recovery failed; inspect listed ID / error' end
  phase('VERIFY')
  local readOK,readError=pcall(function()
    for _,name in ipairs({'fleet.lua','fleet_admin.lua','fleet_view.lua','deploy.lua','startup_15.lua','startup_node.lua'}) do
      data[name]=assert(proposed[name],'Missing bundle file: '..name);assert(#data[name]<=1048576,'File too large: '..name)
    end
    if proposed['startup_gps.lua'] then data['startup_gps.lua']=proposed['startup_gps.lua'] end
    FLEET15.prepareSelf(data)
    for name,d in pairs(data) do local fn,err=load(d,'@'..name,'t',{});assert(fn,err);sums[name]=checksum(d,true) end
  end)
  if not readOK then if FLEET15 and FLEET15.rollbackSelf then pcall(FLEET15.rollbackSelf) end;return false,'Bundle validation: '..tostring(readError) end
  local function transfer(id,name,d,sum,tx)
    local transferId=uid()..'-'..id
    if not call(id,'FILE_BEGIN',{name=name,size=#d,checksum=sum,transfer=transferId,update=tx}) then return false end
    for offset=1,#d,4096 do
      if not call(id,'FILE_CHUNK',{transfer=transferId,index=math.floor((offset-1)/4096)+1,data=d:sub(offset,offset+4095)},true) then return false end
    end
    local applied=call(id,'FILE_END',{transfer=transferId});return applied~=nil,applied and applied.info
  end
  local function booted(id,oldBoot,expected)
    for _=1,6 do
      sleep(.5)
      local r=call(id,'STATUS',{},true);local i=r and r.info
      if i and i.boot~=oldBoot and i.capabilities and i.capabilities.bundle==1 then
        if expected and (not i.runningAdmin or i.runningAdmin.checksum~=expected) then log(id,'FAILED','New management runtime checksum mismatch: '..tostring(i.bootError or 'previous manager restored'));return false end
        if i.capabilities.spacePreflight~=2 or not i.storage or not (i.storage.free=='unlimited' or finite(i.storage.free)) then log(id,'FAILED','New manager did not report real storage.free / spacePreflight=2');return false end
        before[id]=i;return true
      end
    end
    log(id,'FAILED','MANUAL RECOVERY REQUIRED: new manager boot not verified');return false
  end
  local function rollback(reason)
    local errors={}
    for id,o in pairs(outcomes) do if o.state=='FAILED' or o.state=='OFFLINE' or o.state=='TIMEOUT' then errors[id]=o.detail end end
    stopAll()
    phase('RECOVERING')
    many(function(id)
      if prepared[id] then
        local r=call(id,'UPDATE_ROLLBACK',{token=token,grounded=true})
        outcomes[id].rollback=r and 'RESTORED' or 'MANUAL RECOVERY REQUIRED'
      elseif bootstrapJobs[id] then
        local job=bootstrapJobs[id];local status=call(id,'STATUS',{},true);local info=status and status.info
        if info and info.capabilities and info.capabilities.bootstrap==1 then
          local r=call(id,'UPDATE_ROLLBACK',{token=token,grounded=true})
          outcomes[id].rollback=r and 'RESTORED' or 'MANUAL RECOVERY REQUIRED'
        else
          local restored=info and not info.running and info.active==false
          for _,key in ipairs({'admin','startup'})do
            local old=job.before.files and job.before.files[key];local disk=info and info.files and info.files[key]
            restored=restored and old and disk and old.exists==disk.exists and old.checksum==disk.checksum
          end
          outcomes[id].rollback=restored and 'RESTORED' or 'MANUAL RECOVERY REQUIRED'
          if not restored then log(id,'FAILED','MANUAL RECOVERY REQUIRED: bootstrap interrupted before new service available; originals/backups retained')end
        end
      end
      if errors[id] then log(id,'FAILED',errors[id]..' / '..(outcomes[id].rollback or 'STOPPED')) end
    end)
    local restored,total=0,0
    for id in pairs(outcomes)do if prepared[id] or bootstrapJobs[id]then total=total+1;if outcomes[id].rollback=='RESTORED'then restored=restored+1 else print('MANUAL RECOVERY REQUIRED: '..tostring(ROLE.resolve(id) or id))end end end
    if FLEET15 and FLEET15.rollbackSelf then local ok,why=pcall(FLEET15.rollbackSelf);if not ok then print('MANUAL RECOVERY REQUIRED: 15 '..tostring(why)) end end
    print('ROLLBACK... '..restored..'/'..total..' RESTORED')
    return false,reason..'; SHIP REMAINS STOPPED'
  end
  phase('BOOTSTRAP')
  for _,id in ipairs(command.targets) do
    local i=before[id]
    if needsBootstrap(i) then
      local cookie={kind='fleet_bootstrap_v1',token=token,state='RESTARTING',files={}}
      bootstrapJobs[id]={before=i}
      if not transfer(id,'fleet_hold.lua','return true',checksum('return true'))then return rollback('Bootstrap hold marker failed')end
      local function saveCookie()
        local body=textutils.serialize(cookie)
        return transfer(id,'fleet_boot_recovery.txt',body,checksum(body))
      end
      local journalOK,priorJournal=saveCookie()
      if not journalOK then return rollback('Bootstrap journal creation failed')end
      if priorJournal and priorJournal.backup then
        cookie.parents={{path=priorJournal.backup,optional=true}}
        if not saveCookie()then return rollback('Bootstrap parent journal preservation failed')end
      end
      for _,entry in ipairs({{name='startup.lua',source='startup_node.lua',key='startup'},{name='fleet_admin.lua',source='fleet_admin.lua',key='admin'}})do
        local old=i.files and i.files[entry.key]
        if not old or old.checksum~=sums[entry.source]then
          local ok,result=transfer(id,entry.name,data[entry.source],sums[entry.source])
          if not ok then return rollback('Bootstrap '..entry.name..' failed')end
          local hadOld=old and old.exists==true or false
          if hadOld and not (result and result.backup and old.checksum)then return rollback('Bootstrap original backup not acknowledged')end
          cookie.files[#cookie.files+1]={name=entry.name,hadOld=hadOld,backup=result and result.backup,oldChecksum=old and old.checksum}
          if not saveCookie()then return rollback('Bootstrap rollback journal update failed')end
        end
      end
      if not call(id,'REBOOT',{grounded=true}) or not booted(id,i.boot,sums['fleet_admin.lua'])then return rollback('Bootstrap manager reboot verification failed')end
      local stopped=call(id,'STOP',{})
      if not stopped or not stopped.info or stopped.info.active~=false or not stopped.info.zero or stopped.info.zero.state~='OK'then return rollback('Bootstrap manager could not confirm output zero')end
      before[id]=stopped.info
    end
  end
  local manifest={{name='fleet.lua',checksum=sums['fleet.lua'],size=#data['fleet.lua']},{name='fleet_admin.lua',checksum=sums['fleet_admin.lua'],size=#data['fleet_admin.lua']},{name='startup.lua',checksum=sums['startup_node.lua'],size=#data['startup_node.lua']}}
  phase('PREFLIGHT')
  many(function(id)
    if not call(id,'UPDATE_PREFLIGHT',{files=manifest,grounded=true}) then failed=true end
  end)
  if failed then return rollback('Storage preflight failed after verified manager bootstrap; fleet code not applied')end
  phase('BACKUP')
  many(function(id)
    prepared[id]=true
    local r=call(id,'UPDATE_PREPARE',{token=token,checksum=sums['fleet.lua'],files=manifest,grounded=true})
    if not r then failed=true else before[id]=r.info end
  end)
  if failed then return rollback('Backup preparation failed') end
  phase('TRANSFER')
  many(function(id)
    local info=before[id];local files=info.files or {}
    for _,f in ipairs(manifest) do
      local key=f.name=='fleet.lua' and 'fleet' or f.name=='fleet_admin.lua' and 'admin' or 'startup'
      if not files[key] or files[key].checksum~=f.checksum then
        local source=f.name=='startup.lua' and 'startup_node.lua' or f.name
        if not transfer(id,f.name,data[source],f.checksum,token) then failed=true;return end
      else log(id,'UNCHANGED',f.name..' checksum matches') end
    end
  end)
  if failed then return rollback('Bundle receive / verify / apply failed') end
  phase('VERIFY')
  for _,id in ipairs(command.targets) do
    local info=before[id]
    if not info.runningAdmin or info.runningAdmin.checksum~=sums['fleet_admin.lua'] then
      if not call(id,'REBOOT',{grounded=true,update=token}) or not booted(id,info.boot,sums['fleet_admin.lua']) then return rollback('Management self-update failed') end
    end
  end
  phase('STARTING')
  for _,id in ipairs({12,13,14,16,17,18,19,10,11}) do if not call(id,'START',{}) then return rollback('Fleet startup failed') end end
  local function stableCore()
    local deadline=os.clock()+8
    repeat
      local r=call(10,'STATUS',{},true);local i=r and r.info;local rt=i and i.runtime
      if not i or i.error or rt and rt.error or i.active~=false then log(10,'FAILED',tostring(i and (i.error or rt and rt.error) or 'No CORE response'));return false end
      local h=rt and rt.maintenance
      if rt and rt.state=='READY / OFF' and h and h.token==token and h.zero and h.frames>=4 and h.readySince and os.clock()-h.readySince>=1 then return true end
      sleep(.25)
    until os.clock()>=deadline
    log(10,'FAILED','CORE heartbeat stabilization timeout');return false
  end
  phase('CHECKING')
  if not stableCore() then return rollback('CORE did not stabilize') end
  many(function(id)
    local r
    for _=1,4 do
      r=call(id,'VERSION',{},true)
      if r and r.info and r.info.runtime and r.info.runtime.state~='CHECKING' then break end
      sleep(.5)
    end
    if not r or not checked(id,'UPDATE_CHECK',{token=token}) then failed=true end
  end)
  if failed then return rollback('Running version / heartbeat verification failed') end
  phase('COMMIT')
  for index,id in ipairs({12,13,14,16,17,18,19,11}) do
    if not checked(id,'UPDATE_COMMIT',{token=token}) then return rollback('Commit failed; backups retained') end
    if not DEPLOY_VERBOSE then print('COMMIT... '..index..'/9') end
  end
  if not stableCore() then return rollback('CORE heartbeat recheck failed; backups retained') end
  if not checked(10,'UPDATE_COMMIT',{token=token}) then return rollback('CORE commit failed; backups retained') end
  if not DEPLOY_VERBOSE then print('COMMIT... 9/9') end
  phase('FINAL VERIFY')
  for _,id in ipairs({12,13,14,16,17,18,19,11,10})do
    if id==10 and not stableCore() then return rollback('Final CORE heartbeat recheck failed') end
    if not checked(id,'UPDATE_CHECK',{token=token}) then return rollback('Final runtime/disk verification failed; backups retained') end
  end
  phase('SELF UPDATE')
  local selfOK,selfError=pcall(function()
    local ok,why=FLEET15.testSelf();assert(ok,why)
    FLEET15.applySelf();FLEET15.confirmSelf()
  end)
  if not selfOK then log(15,'FAILED',tostring(selfError));return rollback('15 self-update failed: '..tostring(selfError)) end
  phase('CLEANUP')
  if command.clean then many(function(id)if not call(id,'UPDATE_CLEAN',{token=token}) then failed=true end end) end
  if failed then stopAll() end
  for _,id in ipairs(command.targets) do
    if outcomes[id].state~='FAILED' and outcomes[id].state~='TIMEOUT' and outcomes[id].state~='OFFLINE' then log(id,failed and 'STOPPED' or 'RUNNING',failed and 'Cleanup incomplete; control stopped' or 'Bundle verified') end
  end
  if failed then if FLEET15 and FLEET15.rollbackSelf then pcall(FLEET15.rollbackSelf) end;return false,'Cleanup incomplete; SHIP REMAINS STOPPED' end
  if not stableCore() then stopAll();return false,'Post-cleanup heartbeat stabilization failed; SHIP STOPPED' end
  for _,id in ipairs({12,13,14,16,17,18,19,11,10})do if not checked(id,'UPDATE_RELEASE',{token=token}) then stopAll();return false,'Maintenance release failed; SHIP STOPPED' end end
  for _,id in ipairs(command.targets)do log(id,'RUNNING','Bundle verified; maintenance released') end
  if FLEET15 and FLEET15.commitSelf then FLEET15.commitSelf() end
  return true,'UPDATE COMPLETE: 9 / 9 RUNNING'
end

local function runCommand(command)
  outcomes={};activeCommand=command.op
  if command.op=='UPDATE' then
    updateFinished=false;updateSuccess=nil;bundleSource=nil
    local protected,ok,detail=pcall(updateFleet,command)
    if not protected then detail=tostring(ok);ok=false;if FLEET15 and FLEET15.rollbackSelf then pcall(FLEET15.rollbackSelf) end end
    updateFinished=true;updateSuccess=ok;updateStage=ok and 'UPDATE COMPLETE' or 'UPDATE FAILED';saveReport(detail)
    print((ok and 'UPDATE SUCCESS: ' or 'UPDATE FAILED: ')..detail)
    for _,id in ipairs(command.targets) do local o=outcomes[id];print(tostring(id)..' '..(o and o.state or 'NOT RUN')..(o and o.rollback and (' / '..o.rollback) or '')) end
    return
  end
  local data,sum,transfer
  if command.op=='FILE' then
    data=readFile(command.path);assert(#data<=1048576,'Max file size: 1 MiB')
    if command.name:match('%.lua$') then local fn,err=load(data,'@'..command.name,'t',{});assert(fn,err) end
    sum=checksum(data,true);transfer=uid()
  end
  local function target(id)
    if command.op=='FILE' then
      local token=transfer..'-'..id
      if not call(id,'FILE_BEGIN',{name=command.name,size=#data,checksum=sum,transfer=token}) then return end
      for offset=1,#data,4096 do
        if not call(id,'FILE_CHUNK',{transfer=token,index=math.floor((offset-1)/4096)+1,data=data:sub(offset,offset+4095)},true) then return end
      end
      call(id,'FILE_END',{transfer=token});return
    end
    local result=call(id,command.op,{grounded=command.grounded,name=command.name,confirm=command.confirm})
    if result and (command.op=='STATUS' or command.op=='VERSION') then
      local info=result.info or {}
      local running=info.runningCode or {};local files=info.files or {};local disk=files.fleet or {}
      print(string.format('%02d %s / %s / admin %s / run %s / disk %s',id,info.role or '?',info.state or '?',
        info.adminVersion or '?',running.version or running.checksum or '?',disk.version or disk.checksum or '?'))
      local runtime=info.runtime or {}
      print(string.format('%02d control=%s active=%s',id,runtime.state or 'UNKNOWN',tostring(info.active)))
      if info.error or runtime.error then print(tostring(info.error or runtime.error)) end
      outcomes[id].info=info
    elseif result and command.op=='REBOOT' then
      local before=result.info and result.info.boot
      sleep(1.5)
      local verified=false
      for _=1,3 do
        local r=call(id,'STATUS',{},true)
        if r and r.info and r.info.boot~=before then
          log(id,r.info.running and 'RUNNING' or 'STOPPED','New boot confirmed: '..tostring(r.info.state));verified=true;break
        end
        sleep(1)
      end
      if not verified then log(id,'TIMEOUT','REBOOT accepted; new boot not confirmed') end
    end
  end
  if command.op=='RESTART' or command.op=='REBOOT' then
    for _,id in ipairs(command.targets) do target(id) end
  else
    local tasks={}
    for _,id in ipairs(command.targets) do local targetId=id;tasks[#tasks+1]=function()target(targetId)end end
    parallel.waitForAll(table.unpack(tasks))
  end
  local report={version=ADMIN_VERSION,command=command.op,time=now(),targets=outcomes}
  local ok,err=pcall(writeFile,'fleet_deploy_last.txt',textutils.serialize(report))
  if not ok then print('Could not save last report: '..tostring(err)) end
  print('--- TARGET RESULTS ---')
  for _,id in ipairs(command.targets) do
    local o=outcomes[id];print(string.format('%02d %s',id,o and o.state or 'FAILED'))
  end
end
local function console()
  if ROLE.dynamic then sleep(2.5) end
  net.scan()
  print('FLEET DEPLOY '..ADMIN_VERSION)
  print('UPDATE all --clean | STATUS all | FILE fleet.lua all')
  print('START all | STOP all | RESTART all --grounded')
  print('VERSION all | DELETE old_fleet.lua 16-19 | EXIT')
  local function invoke(words)
    if commandRunning then print('BUSY: update in progress; monitor STOP remains available');return end
    if FLEET15 and FLEET15.enterCommand and not FLEET15.enterCommand() then return end
    commandRunning=true
    local ok,err=pcall(function()runCommand(parseCommand(words))end)
    commandRunning=false
    if FLEET15 then if not FLEET15.selfPending then FLEET15.busy=false end;if FLEET15.leaveCommand then FLEET15.leaveCommand() end end
    saveReport()
    if not ok then print('FAILED: '..tostring(err)) end
  end
  if #args>0 then invoke(args);return end
  while true do
    write('deploy> ')
    local line=read()
    if line and line:upper():match('^%s*EXIT%s*$') then return end
    local words={};for word in tostring(line):gmatch('%S+') do words[#words+1]=word end
    if #words>0 then invoke(words) end
  end
end
local function uiRequests()
  while true do
    os.pullEvent('fleet_update_all')
    if not commandRunning and (not FLEET15 or not FLEET15.enterCommand or FLEET15.enterCommand()) then
      commandRunning=true
      if FLEET15 then FLEET15.busy=true;FLEET15.abort=false end
      local ok,err=pcall(runCommand,parseCommand({'UPDATE','all','--clean','--grounded'}))
      commandRunning=false
      if FLEET15 then if not FLEET15.selfPending then FLEET15.busy=false end;if FLEET15.leaveCommand then FLEET15.leaveCommand() end end
      saveReport()
      if not ok then updateStage='UPDATE FAILED';updateFinished=true;updateSuccess=false;saveReport(tostring(err)) end
    end
  end
end
local function emergency()
  while true do
    os.pullEvent('fleet_deploy_emergency')
    for _,id in ipairs(TARGETS) do sendRequest(net.envelope(id,client..'-stop-'..uid(),'STOP',{}),true) end
  end
end
if FLEET15_HEALTH then FLEET15_HEALTH(ADMIN_VERSION) end
local ok,err=pcall(function()parallel.waitForAny(receiver,console,uiRequests,emergency,ROLE.run)end)
net.close()
if not ok then print('Deploy stopped: '..tostring(err)) end

