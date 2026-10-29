local args={...}
local BOOT_EFFECT=true
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
local VERSION='2026.10.29-r21'
local PAGE_COUNT=17
local PAGE_NAMES={'PROPULSION','ANGLES','SENSORS','VECTOR STATUS','NODES','CRUISE / NAV','STATUS / PILOT','ADMIN','HOVER','MANUAL','TEST','WEAPONS','FACILITY','RADAR','LOG / ALERT','CONSOLES','ENGINEERING'}
local CHANNEL=42110
local UI_CHANNEL=42111
local ACK_CHANNEL=42112
local TIMEOUT=2000
local HISTORY_MS=60000
local GPSCFG={gpsTimeout=5,gpsLocateTimeout=2.5,pollSeconds=0.5,failureWarning=3}
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function newModel()
  return {forms={hoverY='',heading='0',speed='0',testY='',testHeading='90',testSpeed='3',duration='20'},form='hoverY',testKind='THRUST',history={},packet=nil,session=nil,lastSeq=-1,angle=nil,lastAngleTime=nil,legacy=false,gps={ok=false},bootStart=nil,target={x='',y='',z=''},axis='x',commandText='No command',confirm=nil}
end
local function accept(model,m,now)
  if type(m)~='table' or m.protocol~='ship_status_v1' or m.source~=10 or m.relay~=11 then return false end
  local t=m.telemetry
  if type(t)~='table' then model.legacy=true;return false end
  if t.version~=1 or type(t.session)~='string' or not finite(t.seq) or not finite(t.time)
    or now-t.time>TIMEOUT or t.time-now>100 or type(t.state)~='string'
    or type(t.zones)~='table' or type(t.inputs)~='table' then return false end
  for _,name in ipairs({'left','right','front','back'}) do
    local v=t.inputs[name]
    if not finite(v) or v<0 or v>15 then return false end
  end
  for _,name in ipairs({'LF','RF','LB','RB'}) do
    local z=t.zones[name]
    if z~=nil then
      if type(z)~='table' then return false end
      for _,key in ipairs({'sub','main','fine'}) do
        local v=z[key]
        if not finite(v) or v<0 or v>(key=='fine' and 64 or 15) then return false end
      end
      if z.fineLevels~=nil then
        if type(z.fineLevels)~='table' or (#z.fineLevels<1 and z.phase~='OFF') or #z.fineLevels>64 then return false end
        for i=1,#z.fineLevels do local v=z.fineLevels[i];if not finite(v) or v<0 or v>1 then return false end end
      end
    end
  end
  if t.diagnosticLines~=nil then
    if type(t.diagnosticLines)~='table' or #t.diagnosticLines>80 then return false end
    for _,line in ipairs(t.diagnosticLines) do
      if type(line)~='string' or #line>200 then return false end
    end
  end
  if t.nodes~=nil then
    if type(t.nodes)~='table' then return false end
    for id,n in pairs(t.nodes) do
      if not finite(id) or id<10 or id>19 or type(n)~='table' or not finite(n.time)
        or type(n.ok)~='boolean' then return false end
      for _,key in ipairs({'state','error','version'}) do
        if n[key]~=nil and (type(n[key])~='string' or #n[key]>500) then return false end
      end
      if n.applied~=nil then
        if type(n.applied)~='table' then return false end
        for _,v in pairs(n.applied) do if not finite(v) or v<0 or v>15 then return false end end
      end
    end
  end
  if t.sensor~=nil then
    if type(t.sensor)~='table' or (t.sensor.time~=nil and not finite(t.sensor.time)) then return false end
  end
  if t.rotation~=nil then
    local r=t.rotation
    if type(r)~='table' or not finite(r.left) or not finite(r.right)
      or math.abs(r.left)>90 or math.abs(r.right)>90 or type(r.outputs)~='table' then return false end
    for _,side in ipairs({'left','right','top','bottom'}) do
      local v=r.outputs[side];if not finite(v) or v<0 or v>15 or v%1~=0 then return false end
    end
  end
  if t.nav~=nil then
    if type(t.nav)~='table' or type(t.nav.state)~='string' then return false end
    if t.nav.target then
      if type(t.nav.target)~='table' then return false end
      for _,axis in ipairs({'x','y','z'}) do if not finite(t.nav.target[axis]) then return false end end
    end
    if t.nav.metrics then
      if type(t.nav.metrics)~='table' then return false end
      for _,key in ipairs({'horizontal','dy'}) do if not finite(t.nav.metrics[key]) then return false end end
    end
  end
  if t.thrust~=nil then
    if type(t.thrust)~='table' then return false end
    for _,key in ipairs({'total','targetTotal','paired','unpaired'}) do
      if not finite(t.thrust[key]) or t.thrust[key]<-0.000001 then return false end
    end
  end
  if t.recovery~=nil then
    if type(t.recovery)~='table' or type(t.recovery.active)~='boolean' then return false end
    for _,key in ipairs({'stable','rateR','rateP'}) do if not finite(t.recovery[key]) then return false end end
  end
  if model.session~=t.session then
    model.session=t.session;model.lastSeq=-1;model.history={};model.angle=nil;model.lastAngleTime=nil
  end
  if t.seq<=model.lastSeq then return false end
  model.packet=t;model.lastSeq=t.seq;model.legacy=false
  local a=t.angles
  if type(a)=='table' and finite(a.roll) and finite(a.pitch) and finite(a.time)
    and math.abs(a.roll)<=180 and math.abs(a.pitch)<=180 and now-a.time<=TIMEOUT and a.time-now<=100
    and (not model.lastAngleTime or a.time>model.lastAngleTime) then
    model.angle={roll=a.roll,pitch=a.pitch,time=a.time}
    model.lastAngleTime=a.time
    model.history[#model.history+1]=model.angle
  end
  while #model.history>240 or (#model.history>0 and now-model.history[1].time>HISTORY_MS) do
    table.remove(model.history,1)
  end
  return true
end
local function nodeState(n,now)
  if type(n)~='table' or not finite(n.time) then return 'OFFLINE',nil end
  local age=(now-n.time)/1000
  if age< -0.1 or age>1 then return 'STALE',age end
  return n.ok and 'ONLINE' or 'FAULT',age
end
local function gpsState(g,now)
  if type(g)~='table' or not finite(g.time) then return 'NO FIX',nil end
  local age=(now-g.time)/1000
  if age< -0.1 or age>GPSCFG.gpsTimeout then return 'LOST',age end
  return (g.ok==false or g.degraded) and 'DEGRADED' or 'FIX',age
end
local function gpsSample(g,ok,x,y,z,now)
  if ok and finite(x) and finite(y) and finite(z) then
    return {ok=true,x=x,y=y,z=z,time=now,sampleTime=now,failures=0,degraded=false}
  end
  g=g or {};g.sampleTime=now;g.failures=(g.failures or 0)+1;g.degraded=true
  g.error=not ok and tostring(x) or 'NO FIX';g.warning=g.failures>=GPSCFG.failureWarning
  return g
end
local function direction(dx,dz)
  if not finite(dx) or not finite(dz) or dx*dx+dz*dz<1e-12 then return 'HERE',0,0 end
  local atan2=math.atan2 or function(y,x)return math.atan(y,x)end
  local sector=math.floor(atan2(dz,dx)/(math.pi/4)+0.5)%8
  local names={'X+','X+Z+','Z+','X-Z+','X-','X-Z-','Z-','X+Z-'}
  local xs={1,1,0,-1,-1,-1,0,1};local zs={0,1,1,1,0,-1,-1,-1}
  return names[sector+1],xs[sector+1],zs[sector+1]
end
local function navDisplay(t,g,now)
  local nav=t and t.nav or {};local m=nav.actual or nav.metrics or {};local r=t and t.rotation or {}
  local live=t and now-t.time<=TIMEOUT
  local gs=gpsState(g,now)
  if nav.active and nav.gps and gs=='FIX' then gs=nav.gps end
  local left,right=r.left or 0,r.right or 0
  local cmd='HOLD'
  if left*right<0 then cmd=left*(nav.yawSign or 1)>0 and 'TURN RIGHT' or 'TURN LEFT'
  elseif left+right<0 then cmd='BRAKE / BACK'
  elseif left+right>0 then cmd='FORWARD'
  elseif nav.stage=='ALTITUDE' or nav.stage=='FINAL' then cmd='ALTITUDE' end
  if not live then cmd='STALE' end
  local actual='NO VELOCITY FIX';local ax,az=0,0
  if not live then actual='STALE'
  elseif gs~='FIX' then actual='GPS '..gs
  elseif finite(m.sampleTime) and now-m.sampleTime>=-100 and now-m.sampleTime<=GPSCFG.gpsTimeout*1000 and finite(m.horizontalSpeed) then
    if m.horizontalSpeed<0.1 then actual='STOPPED'
    else local d;d,ax,az=direction(m.vx,m.vz);actual=string.format('%s %.2f b/s',d,m.horizontalSpeed) end
  end
  local y=nav.yaw
  local yawValid=live and type(y)=='table' and y.valid==true and finite(y.yaw) and finite(y.time) and now-y.time<=2000 and now-y.time>=-100 and now-(y.oldest or y.time)<=2000
  local targetX,targetZ,targetDistance=m.dx,m.dz,m.horizontal
  local origin=y and (y.targetOrigin or y.center)
  if yawValid and nav.target and origin and finite(origin.x) and finite(origin.z) then
    targetX=nav.target.x-origin.x;targetZ=nav.target.z-origin.z
    targetDistance=math.sqrt(targetX*targetX+targetZ*targetZ)
  end
  local td,tx,tz=direction(targetX,targetZ)
  local trusted=live and gs=='FIX' and nav.courseTrusted==true and finite(nav.course)
    and finite(nav.courseTime) and now/1000-nav.courseTime<=5
  local actualCourse=live and gs=='FIX' and finite(m.sampleTime) and now-m.sampleTime>=-100 and now-m.sampleTime<=2000 and m.courseValid and finite(m.course) and m.course or nil
  local bearing=yawValid and y.targetYaw or nil
  if not finite(bearing) and finite(targetX) and finite(targetZ) and targetX*targetX+targetZ*targetZ>0.0001 then
    local atan2=math.atan2 or function(z,x)return math.atan(z,x)end;bearing=math.deg(atan2(targetZ,targetX))
  end
  return {cmd=cmd,actual=actual,target=finite(targetDistance) and string.format('%s %.1f b',td,targetDistance) or '?',
    course=finite(actualCourse) and string.format('ACT %.1f deg',actualCourse) or trusted and string.format('EST %.1f deg',nav.course) or (nav.active and 'SEARCHING' or '?'),
    error=trusted and finite(nav.courseError) and string.format('%+.1f deg',nav.courseError) or '?',
    hint=not nav.active and 'Navigation inactive' or nav.rechecking and 'RECHECKING COURSE...' or nav.stage=='PROBE' and 'Finding course...' or trusted and 'GPS COURSE ESTIMATE' or 'Course unknown',
    yawValid=yawValid,yaw=yawValid and y.yaw or nil,targetYaw=bearing,
    bowReason=y and y.reason,bowSamples=y and y.samples,bowSign=y and y.bowSign,bowSignSource=y and y.bowSignSource,
    bowX=yawValid and math.cos(math.rad(y.yaw)) or 0,bowZ=yawValid and math.sin(math.rad(y.yaw)) or 0,
    warnings=nav.directionDiagnostics and nav.directionDiagnostics.warnings or {},actualCourse=actualCourse,
    yawError=yawValid and y.error or nil,yawRate=yawValid and y.rateValid and y.rate or nil,yawFixes=y and y.fixes or 0,yawRequired=y and y.required or 2,
    baseline=y and y.horizontalBaseline or y and y.baseline,distance3d=y and y.distance3d,distanceError=y and y.distanceError,deltaY=y and y.deltaY,
    recoveryFixes=y and y.recoveryFixes,recoveryRequired=y and y.recoveryRequired,rawYaw=y and y.rawYaw,offset=y and y.offset,
    velocity=nav.velocity or {},limits=nav.limits or {},
    turn=nav.turnDirection or 'NONE',boost=nav.boostApplied or nav.turnBoost or 0,
    probeAngle=nav.probeInfo and nav.probeInfo.angle or nav.probeAngle,
    probeMove=nav.probeInfo and nav.probeInfo.move,probeFixes=nav.probeInfo and nav.probeInfo.fixes,
    probeLast=nav.probeInfo and (not nav.active or nav.probeInfo.result~='ACTIVE' or gs~='FIX'),
    retry=nav.probeFailCount or 0,gps=gs,ax=ax,az=az,tx=tx,tz=tz,left=left,right=right}
end
local function crossPosition(roll,pitch,cx,cy,rx,ry)
  return cx+math.floor(clamp(-roll/30,-1,1)*rx+0.5),
    cy+math.floor(clamp(pitch/30,-1,1)*ry+0.5)
end
local function controlLive(model,now)
  local t=model.packet
  return t and now-t.time<=1000 and (nodeState(t.nodes and t.nodes[10],now)=='ONLINE' or nodeState(t.nodes and t.nodes[10],now)=='FAULT')
    and nodeState(t.nodes and t.nodes[11],now)=='ONLINE'
end
local function editTarget(model,key)
  local axis=model.axis or 'x';local v=model.target[axis] or ''
  if key=='CLEAR' then v=''
  elseif key=='BACKSPACE' then v=v:sub(1,-2)
  elseif key=='-' then v=v:sub(1,1)=='-' and v:sub(2) or '-'..v
  elseif type(key)=='string' and key:match('^%d$') and #v<9 then v=v..key end
  model.target[axis]=v
end
local function targetValue(model)
  local out={}
  for _,axis in ipairs({'x','y','z'}) do
    out[axis]=tonumber(model.target[axis])
    if not finite(out[axis]) or math.abs(out[axis])>30000000 then return nil end
  end
  return out
end
local function monitorOrder(names,sizes,preferred)
  local copy={};for _,n in ipairs(names) do copy[#copy+1]=n end
  table.sort(copy,function(a,b)
    if a==preferred then return true end;if b==preferred then return false end
    local aa,bb=sizes[a] or 0,sizes[b] or 0
    if aa~=bb then return aa>bb end;return a<b
  end)
  return copy
end
local function draw(screen,model,now,page,radio,offset,navMode)
  local w,h=screen.getSize()
  local buttons={}
  local color=screen.isColor()
  local chars,fg,bg={},{},{}
  for y=1,h do
    chars[y]={};fg[y]={};bg[y]={}
    for x=1,w do chars[y][x]=' ';fg[y][x]='0';bg[y][x]='f' end
  end
  local function ink(c,background)
    if color then return c end
    if background then return c=='f' and 'f' or ((c=='7' or c=='8') and '7' or '0') end
    return c=='f' and 'f' or '0'
  end
  local function put(x,y,text,c,b)
    x=math.floor(x);y=math.floor(y)
    if y<1 or y>h then return end
    text=tostring(text)
    for i=1,#text do
      local xx=x+i-1
      if xx>=1 and xx<=w then
        chars[y][xx]=text:sub(i,i);fg[y][xx]=ink(c or '0',false);bg[y][xx]=ink(b or 'f',true)
        if not color and bg[y][xx]=='0' then fg[y][xx]='f' end
      end
    end
  end
  local function rect(x,y,width,height,c)
    for yy=y,y+height-1 do put(x,yy,string.rep(' ',math.max(0,width)),'0',c) end
  end
  local function center(y,text,c,b) put(math.floor((w-#text)/2)+1,y,text,c,b) end
  if page==0 and now-(model.bootStart or now)<400 then
    for y=1,h do screen.setCursorPos(1,y);screen.blit(string.rep(' ',w),string.rep('0',w),string.rep('f',w)) end
    return {}
  end
  local t=model.packet
  local live=t and now-t.time<=TIMEOUT
  local acol=live and '5' or 'e'
  local link=not radio and 'NO MODEM' or (not t and 'WAITING' or (live and 'LIVE' or 'SIGNAL LOST'))
  rect(1,1,w,1,'b');put(2,1,'FLEET / '..(page==0 and 'BOOT' or PAGE_NAMES[page] or 'CONSOLE'),'0','b')
  put(math.max(1,w-#link),1,link,acol,'b')
  if w<30 or h<22 then
    center(4,'MONITOR TOO SMALL','4')
    center(6,'Need 30 x 22 text cells')
    center(8,'Enlarge monitor / scale 0.5')
  else
    put(2,2,t and ((t.recovery and t.recovery.active) and 'RECOVERY' or t.state) or 'Waiting for computer 11...',live and '0' or '8')
    if not live and t then put(2,3,'OLD DATA - outputs below are NOT live','e')
    elseif model.legacy then put(2,3,'Update fleet.lua on 10 and 11','4')
    elseif t then
      local i=t.inputs
      if t.relayAge~=nil and (not finite(t.relayAge) or t.relayAge>0.5) then
        put(2,3,'RELAY COMPARISON: STALE / UNKNOWN','4')
      else
        put(2,3,string.format('RELAY  L:%2d R:%2d F:%2d B:%2d',i.left,i.right,i.front,i.back),'8')
      end
    end
    local function button(x,y,width,label,action,enabled,height)
      local c=(action=='STOP' or action=='ADMIN_STOP') and 'e' or enabled and 'b' or '7'
      height=height or 1
      rect(x,y,width,height,c);put(x+1,y,label:sub(1,width-2),'0',c)
      buttons[#buttons+1]={x=x,y=y,w=width,h=height,action=action,enabled=enabled}
    end
    local function rowButtons(y,items)
      local bw=math.floor((w-2)/#items)
      for i,item in ipairs(items) do
        button(2+(i-1)*bw,y,bw-1,item[1],item[2],item[3]~=false)
      end
    end
    local can=controlLive(model,now) and not model.adminBusy
    if page==16 then
      put(2,4,'SELECT THIS MONITOR CONSOLE','b')
      for i,name in ipairs(PAGE_NAMES) do
        local x=i%2==1 and 2 or math.floor(w/2)+1;local y=5+math.floor((i-1)/2)
        button(x,y,math.floor((w-2)/2),name,'PAGE_'..i,true)
      end
    elseif page==9 or page==10 or page==11 then
      local forms=model.forms or {};local form=model.form or 'hoverY'
      local fields=page==9 and {{'HOVER Y','hoverY'}} or page==10 and {{'HEADING','heading'},{'SIGNED SPEED','speed'}} or {{'TEST Y','testY'},{'HEADING','testHeading'},{'START SPEED','testSpeed'},{'DURATION','duration'}}
      for i,item in ipairs(fields) do button(2,3+i,w-2,item[1]..' ['..tostring(forms[item[2]] or '')..']'..(form==item[2] and ' <' or ''),'FORM_'..item[2],true) end
      if page==11 then rowButtons(8,{{'THRUST','KIND_THRUST',true},{'BRAKE','KIND_BRAKE',true},{'HOVER','KIND_HOVER',true},{'YAW','KIND_YAW',true}}) end
      for row,keys in ipairs({{'1','2','3'},{'4','5','6'},{'7','8','9'},{'-','0','.'}}) do
        local items={};for _,key in ipairs(keys)do items[#items+1]={key,'FEDIT_'..key,true}end;rowButtons(8+row,items)
      end
      rowButtons(13,{{'BACK','FEDIT_BACK',true},{'CLEAR','FEDIT_CLEAR',true},{'COPY Y','FORM_COPY',gpsState(model.gps,now)=='FIX'}})
      local action=page==9 and 'HOVER_START' or page==10 and 'DRIVE' or 'TEST_START'
      rowButtons(15,{{model.confirm==action and 'CONFIRM' or page==9 and 'HOVER' or page==10 and 'DRIVE' or 'RUN '..(model.testKind or 'THRUST'),action,can},{'STOP MOTION','STOP',true}})
      rowButtons(16,{{'CRUISE','PAGE_6',true},{'ABORT TEST','TEST_ABORT',true},{'CONSOLES','PAGE_16',true}})
      put(2,17,model.commandText or '', '4')
      local nav=t and t.nav or {};local test=nav.test
      put(2,18,nav.state or 'MODE IDLE','5')
      if test then
        put(2,19,string.format('%s %.1fs Vmax %.2f D %.1f',test.kind or '?',test.elapsed or 0,test.maxSpeed or 0,test.distance or 0),'8')
        put(2,20,'a '..tostring(test.deceleration or test.acceleration or '?')..' hover '..tostring(test.hoverEstimate or '?')..' yaw '..tostring(test.maxYawRate or '?'),'8')
      else put(2,19,nav.reason or 'Heading is absolute BODY YAW','8');put(2,20,'ARM maintained by STOP MOTION','8') end
    elseif page>=12 and page<=15 then
      put(2,5,PAGE_NAMES[page],'b')
      if page==15 then
        local logs=t and t.blackbox
        put(2,6,logs and ('BLACKBOX 11 '..(logs.enabled and 'ON' or 'OFF')..' Q '..(logs.queued or 0)..' DROP '..(logs.dropped or 0)) or 'BLACKBOX: NO REPORT','b')
        put(2,7,logs and logs.error and ('LOG WARNING: '..logs.error) or t and t.error or 'No controller fault reported','4')
        put(2,8,'11: fleet_blackbox.log / _event.log','8')
        put(2,9,t and t.roles and t.roles.conflict or 'Role registry: no conflict reported','8')
        put(2,11,model.adminReport and tostring(model.adminReport.detail) or '15: fleet_admin_audit.log / fleet_deploy_last.txt','8')
        put(2,15,logs and logs.lastEvent and (logs.lastEvent.category..' '..logs.lastEvent.code) or 'No blackbox event','8')
        put(2,13,t and t.nav and t.nav.test and (t.nav.test.logError and 'TEST LOG WRITE FAILED: '..t.nav.test.logError or tostring(t.nav.test.reason)) or 'Test results: fleet_test_last.txt on CORE','8')
      else
        put(2,8,'NOT CONFIGURED / API UNVERIFIED','4')
        put(2,10,'No automatic hardware output','8')
        put(2,12,page==14 and 'Radar contact API must be inspected' or page==12 and 'Turret hardware/API not registered' or 'Doors / gear / facilities: extension','8')
      end
      rowButtons(18,{{'CONSOLES','PAGE_16',true},{'STOP','STOP',true}})
    elseif page==17 then
      put(2,5,'LEGACY VECTOR ENGINEERING','4')
      rowButtons(8,{{'BACK','VECTOR_BACK',can},{'VEC 0','VECTOR_ZERO',can},{'FWD','VECTOR_FWD',can}})
      rowButtons(10,{{'L-','LEFT_DOWN',can},{'L+','LEFT_UP',can},{'R-','RIGHT_DOWN',can},{'R+','RIGHT_UP',can}})
      rowButtons(13,{{'MANUAL DRIVE','PAGE_10',true},{'STOP','STOP',true}})
    elseif page==8 then
      local report=model.adminReport
      local busy=model.adminBusy==true
      local finished=not busy and report and report.finished
      put(2,4,finished and (report.success and 'UPDATE COMPLETE' or 'UPDATE FAILED') or 'FLEET UPDATE',finished and (report.success and '5' or 'e') or 'b')
      button(2,5,w-2,busy and 'UPDATE RUNNING' or 'UPDATE ALL','UPDATE_ALL',model.adminManaged==true and not busy,2)
      put(2,8,'SHIP MUST BE LANDED / SECURED','4')
      put(2,9,'STATUS: '..(busy and (report and report.stage or 'STOPPING') or finished and (report.success and '9 / 9 RUNNING' or 'SHIP REMAINS STOPPED') or 'READY'),busy and '4' or '0')
      for row,id in ipairs({10,11,12,13,14,16,17,18,19}) do
        local item=report and report.targets and (report.targets[id] or report.targets[tostring(id)])
        put(2,9+row,tostring(id)..(item and item.actualId and ' ['..item.actualId..']' or '')..' '..(item and item.state or '--'),item and item.state=='FAILED' and 'e' or '8')
      end
      button(2,19,w-2,'MASTER STOP','ADMIN_STOP',true,2)
      if not model.adminManaged then put(2,h-1,'Run startup_15 as startup.lua','4')
      elseif finished and not report.success then put(2,h-1,tostring(report.detail or ''):sub(1,w-2),'e') end
    elseif page==7 then
      local gs=gpsState(model.gps,now)
      rect(1,3,w,1,'f')
      put(2,3,'GPS '..gs..' / CONTROL '..(can and 'LIVE' or 'STALE'),can and '5' or '4')
      local a=model.angle
      local good=live and a and now-a.time<=500 and t.sensor and t.sensor.ok
      put(2,4,good and string.format('R:%+.2f P:%+.2f deg',a.roll,a.pitch) or 'SENSOR NO DATA / STALE',good and '5' or '4')
      local cx=math.floor(w/2);local cy=8;local rx=math.max(3,math.min(12,cx-8))
      put(cx-2,5,'FRONT','8');put(cx-1,11,'BACK','8')
      put(cx-rx-5,cy,'LEFT','8');put(cx+rx+2,cy,'RIGHT','8')
      rect(cx-rx,cy,rx*2+1,1,'7');for yy=6,10 do put(cx,yy,'|','8') end;put(cx,cy,'+','0')
      if good then local x,y=crossPosition(a.roll,a.pitch,cx,cy,rx,2);put(x,y,'O','5') end
      local r=t and t.rotation
      put(2,12,string.format('M:%s L:%s R:%s / HIGH marker',t and (t.mainCommand or t.main) or '?',r and r.left or '?',r and r.right or '?'),'8')
      local armLabel=model.confirm=='ARM' and 'CONFIRM ARM' or 'ARM'
      local mid=math.floor(w/3)
      button(2,13,mid-2,armLabel,'ARM',can,2)
      button(mid+1,13,w-mid-1,'STOP','STOP',true,2)
      rowButtons(15,{{'MAIN -','MAIN_DOWN',can},{'MAIN +','MAIN_UP',can},{'RECHECK','RECHECK',can}})
      rowButtons(16,{{'BACK','VECTOR_BACK',can},{'VEC 0','VECTOR_ZERO',can},{'FWD','VECTOR_FWD',can}})
      rowButtons(17,{{'L-','LEFT_DOWN',can},{'L+','LEFT_UP',can},{'R-','RIGHT_DOWN',can},{'R+','RIGHT_UP',can}})
      rowButtons(18,{{'NAV','PAGE_NAV',true},{'HOV','PAGE_9',true},{'MAN','PAGE_10',true},{'TEST','PAGE_11',true}})
      put(2,19,model.commandText or '','4')
      put(2,20,t and t.nav and t.nav.state or 'NAV IDLE','8')
    elseif page==6 then
      local gs,age=gpsState(model.gps,now);local g=model.gps
      put(2,4,'GPS '..gs..(age and string.format(' age %.1fs',age) or ''),gs=='FIX' and '5' or '4')
      if age then put(2,5,string.format('XYZ %.1f %.1f %.1f',g.x,g.y,g.z),'8') end
      local nav=t and t.nav
      local d=navDisplay(t,g,now)
      local detail=navMode=='STATUS' or (navMode~='EDIT' and nav and nav.active)
      if detail then
        rect(1,5,w,h-6,'f')
        put(2,5,(nav and nav.state or 'NAV IDLE')..' / ARM '..(t and t.armed and 'ON' or 'OFF'),'5')
        put(2,6,'CMD: '..d.cmd,'b')
        put(2,7,'ACTUAL: '..d.actual,'5')
        put(2,8,'TARGET: '..d.target,'4')
        put(2,9,string.format('VECTOR CMD: L %+g / R %+g',d.left,d.right),'b')
        put(2,10,'COURSE: '..d.course,'0')
        if d.yawValid then
          put(2,11,string.format('BOW 12/13: %.1f / FIX %d/%d',d.yaw,d.yawFixes,d.yawRequired),'5')
          put(2,12,'TARGET: '..(finite(d.targetYaw) and string.format('%.1f deg',d.targetYaw) or '?'),'0')
          put(2,13,'YAW ERROR: '..(finite(d.yawError) and string.format('%+.1f deg',d.yawError) or '?'),'0')
          put(2,14,'YAW RATE: '..(finite(d.yawRate) and string.format('%+.1f deg/s',d.yawRate) or '? FIRST FRAME'),'0')
          put(2,15,string.format('TURN:%s BOOST:%.2f',d.turn,d.boost),'4')
        else
          put(2,11,'BOW ? / '..tostring(d.bowReason or 'GPS DEGRADED'),'4')
          put(2,12,'TARGET '..(finite(d.targetYaw) and string.format('%.1f',d.targetYaw) or '?')..' / CRS ERR '..d.error,'8')
          if nav and nav.courseContinuing then
            put(2,13,'COURSE DRIVE / EXTRA ACCEL HELD','5')
            put(2,14,'CRS ERROR '..d.error..' / AGE '..(finite(nav.courseAge) and string.format('%.1fs',nav.courseAge) or '?'),'8')
            put(2,15,'BOW RECOVERY '..tostring(d.recoveryFixes or 0)..'/'..tostring(d.recoveryRequired or 3)..' / GPS '..d.gps,'4')
          else
            put(2,13,'PROBE ANGLE: '..(finite(d.probeAngle) and string.format('%g deg',d.probeAngle) or '?'),'4')
            put(2,14,'MOVE:'..(finite(d.probeMove) and string.format('%.2fb',d.probeMove) or '?')..' FIXES:'..(finite(d.probeFixes) and tostring(d.probeFixes) or '?')..(d.probeLast and ' LAST' or ''),'8')
            put(2,15,'RETRY: '..d.retry..' / GPS: '..d.gps,'4')
          end
        end
        put(2,16,#d.warnings>0 and table.concat(d.warnings,' / ') or nav and nav.reason or '', #d.warnings>0 and 'e' or '8')
        if nav and nav.landing then
          put(2,17,string.format('M %.2f VY %s -> %s',t and (t.mainDemand or t.mainCommand or t.main) or 0,
            finite(nav.verticalSpeed) and string.format('%.2f',nav.verticalSpeed) or '?',finite(nav.targetVy) and string.format('%.2f',nav.targetVy) or '?'),'8')
        else put(2,17,string.format('M%s Y%s LOCK:%s F>%s',t and (t.mainCommand or t.main) or '?',tostring(nav and nav.altitudeTarget or '?'),nav and nav.directionLock and 'ON' or 'OFF',nav and finite(nav.targetForward) and string.format('%.1f',nav.targetForward) or '?'),'8') end
        rowButtons(18,{{'EDIT XYZ','NAV_EDIT',true},{'CANCEL','NAV_CANCEL',true},{'STOP','STOP',true}})
        put(2,19,model.commandText or '', '4')
        local vel=d.velocity
        if h>=30 then
          put(2,27,'DIRECTION LOCK '..(nav and nav.directionLock and 'ON' or 'OFF')..' / '..(nav and nav.lateralState or '?'),'5')
          put(2,28,string.format('Decel %.3f b/s2 %s / Y goal %s',nav and nav.deceleration or 0,nav and nav.brakeConfidence or 'CONFIG',tostring(nav and nav.altitudeTarget or '?')),'8')
        end
        if finite(vel.forward) or finite(vel.lateral) or finite(vel.vertical) then
          put(2,20,string.format('VEL F:%s L:%s V:%s',finite(vel.forward) and string.format('%.1f',vel.forward) or '?',finite(vel.lateral) and string.format('%.1f',vel.lateral) or '?',finite(vel.vertical) and string.format('%.1f',vel.vertical) or '?'),'5')
        else put(2,20,'GPS '..d.gps..' / ARM '..(t and t.armed and 'ON' or 'OFF'),'8') end
        if w>=60 and h>=27 then
          put(2,21,string.format('12/13 3D %s H %s dY %s RAW %s',finite(d.distance3d) and string.format('%.2f',d.distance3d) or '?',finite(d.baseline) and string.format('%.2f',d.baseline) or '?',finite(d.deltaY) and string.format('%+.2f',d.deltaY) or '?',finite(d.rawYaw) and string.format('%.1f',d.rawYaw) or '?'),'8')
          put(2,22,d.yawValid and ('CRS ERR '..d.error..' / '..d.hint) or ((finite(d.recoveryFixes) and finite(d.recoveryRequired)) and ('BOW HOLD '..d.recoveryFixes..'/'..d.recoveryRequired..' / '..d.hint) or d.hint),'4')
          local cx=math.floor(w/2);local cy=23
          put(cx,cy,'O','0');put(cx+12,cy,'X+','8');put(cx-2,cy+2,'Z+','8')
          put(cx+d.tx*8,cy+d.tz,'T','4');put(cx+d.ax*6,cy+d.az,'A','5')
          if d.yawValid then put(cx+d.bowX*4,cy+d.bowZ,'B','b')else put(cx-4,cy,'B?','4')end
          put(2,26,string.format('B=BOW A=COURSE T=TARGET | BRAKE %.1fb %s',nav and nav.brakingDistance or 0,nav and nav.velocityState or 'GPS motion'),'8')
        end
      else
      for i,axis in ipairs({'x','y','z'}) do
        button(2,5+i,w-2,(model.axis==axis and '> ' or '  ')..axis:upper()..' ['..(model.target[axis] or '')..']','AXIS_'..axis,true)
      end
      put(2,9,nav and nav.state or 'NAV IDLE','5')
      if nav and nav.metrics then
        local m=nav.metrics
        put(2,10,string.format('Dist %.1f dY %.1f V %s',m.horizontal or 0,m.dy or 0,finite(m.speed) and string.format('%.1f',m.speed) or '?'),'8')
      else put(2,10,'Course is NOT measured yaw','8') end
      for row,values in ipairs({{'1','2','3'},{'4','5','6'},{'7','8','9'},{'-','0','<'}}) do
        local items={};for _,v in ipairs(values) do items[#items+1]={v,v=='<' and 'EDIT_BACKSPACE' or 'EDIT_'..v,true} end
        rowButtons(10+row,items)
      end
      rowButtons(15,{{'CLEAR','EDIT_CLEAR',true},{'COPY GPS','COPY_GPS',gs=='FIX'},{'CANCEL','NAV_CANCEL',true}})
      rowButtons(16,{{model.confirm=='NAV_START' and 'CONFIRM GOTO' or 'GOTO','NAV_START',can and gs=='FIX'},{'STOP','STOP',true}})
      put(2,17,model.commandText or '','4')
      button(2,18,w-2,'NAV STATUS / MOVEMENT','NAV_STATUS',true)
      put(2,19,'CMD '..d.cmd..' / '..d.actual,'8')
      put(2,20,'COURSE '..d.course..' ERR '..d.error,'4')
      if h>=26 and nav and nav.metrics then
        local m=nav.metrics
        put(2,22,string.format('Total dist %.1f / heading error %s',m.distance or 0,d.error),'8')
        put(2,23,'TARGET '..d.target..' / BOW '..(d.yawValid and string.format('%.1f',d.yaw) or '?'),'8')
      end
      end
    elseif page==0 then
      local elapsed=math.max(0,(now-(model.bootStart or now))/1000)
      local sens=t and t.sensor
      local sensorLive=live and sens and sens.ok and finite(sens.time) and now-sens.time<=500
      local allNodes=live
      for _,id in ipairs({10,11,12,13,14,16,17,18,19}) do
        if nodeState(t and t.nodes and t.nodes[id],now)~='ONLINE' then allNodes=false end
      end
      local gs=gpsState(model.gps,now)
      local nav=t and t.nav or {};local vel=nav.velocity or {};local y=nav.yaw or {}
      local fine=0;for id=16,19 do local node=t and t.nodes and t.nodes[id];fine=fine+(node and nodeState(node,now)=='ONLINE' and node.fineCount or 0)end
      local checks={{'Wireless',radio and 'OK' or 'OFFLINE'},{'Node link',allNodes and 'OK' or 'WAITING'},
        {'Body sensor',sensorLive and 'OK' or 'NO DATA'},{'GPS',gs},{'YAW',y.valid and 'FIX' or 'DEGRADED'},
        {'Velocity 1/2/3',finite(vel.lateral) and finite(vel.forward) and finite(vel.vertical) and 'OK' or 'NO DATA'},
        {'Fine available',tostring(fine)},{'Roles',t and t.roles and t.roles.conflict or 'NO CONFLICT REPORTED'},
        {'Control data',live and 'LIVE' or 'WAITING'}}
      center(5,'FLEET CONTROL','b');center(6,VERSION,'8')
      local count=math.min(#checks,math.floor(math.max(0,elapsed-0.4)/0.45))
      for i=1,count do put(3,7+i,checks[i][1]..': '..checks[i][2],(checks[i][2]=='OK' or checks[i][2]=='FIX' or checks[i][2]=='LIVE') and '5' or '4') end
      if elapsed>=4.5 then local flight=radio and allNodes and sensorLive and live;local navReady=gs=='FIX' and y.valid and finite(vel.lateral) and finite(vel.forward) and finite(vel.vertical) and fine>0
        put(3,18,flight and (navReady and 'SYSTEM READY' or 'FLIGHT READY / NAV DEGRADED') or 'SYSTEM CHECK / DEGRADED','4') end
      rect(3,19,w-4,1,'7');rect(3,19,math.floor((w-4)*count/#checks),1,'b')
    elseif page==4 then
      local a=model.angle
      local sensor=t and t.sensor
      local angleLive=live and a and now-a.time<=500 and sensor and sensor.ok
      local cx=math.floor(w/2);local cy=10
      local rx=math.max(4,math.min(12,math.floor(w/2)-8));local ry=3
      put(cx-2,5,'FRONT','8');put(cx-1,15,'BACK','8')
      put(cx-rx-5,cy,'LEFT','8');put(cx+rx+2,cy,'RIGHT','8')
      rect(cx-rx,cy,rx*2+1,1,'7')
      for y=cy-ry,cy+ry do put(cx,y,'|','8') end
      put(cx,cy,'+','0')
      if angleLive then
        local x,y=crossPosition(a.roll,a.pitch,cx,cy,rx,ry)
        put(x,y,'O','5')
        put(2,4,string.format('R:%+.2f P:%+.2f deg',a.roll,a.pitch),'5')
      else put(2,4,'SENSOR: NO DATA / STALE','4') end
      put(2,16,'Marker = HIGH side; display +/-30 deg','8')
      local rot=t and t.rotation
      if rot then
        local function direction(v) return v>0 and 'FWD' or v<0 and 'BACK' or 'DOWN' end
        put(2,17,string.format('CMD L:%+d %s R:%+d %s',rot.left,direction(rot.left),rot.right,direction(rot.right)),live and '0' or '8')
        put(2,18,string.format('RS L:%d/%d R:%d/%d (F/B)',rot.outputs.left,rot.outputs.right,rot.outputs.top,rot.outputs.bottom),'8')
      else put(2,17,'ROTATION: NO DATA','4') end
      local gs,age=gpsState(model.gps,now)
      local g=model.gps
      put(2,19,'GPS '..gs..(age and string.format(' / AGE %.1fs',age) or ''),gs=='FIX' and '5' or '4')
      if age then put(2,20,string.format('X %.1f Y %.1f Z %.1f',g.x,g.y,g.z),gs=='FIX' and '0' or '8') end
      if h>=25 then
        local demand=t and t.attitudeDemand or {};local pd=demand.pd or {}
        local function value(v)return finite(v) and string.format('%+.3f',v) or '?'end
        put(2,21,'PD R/P '..value(pd.roll)..' / '..value(pd.pitch)..' DZ '..tostring(t and t.deadzone or '?'),'8')
        local ad=t and t.attitudeDiagnostics or {};local axes=ad.axes or {}
        put(2,24,tostring((axes.pitch or {}).state or 'DEMAND NO DATA')..' HUNT '..tostring(ad.hunting or false),'8')
        local n=t and t.nodes and t.nodes[14];local ns,na=nodeState(n,now)
        put(2,22,'14 ROTATION '..ns..(na and string.format(' %.2fs',na) or ''),'8')
        if n and n.applied then
          put(2,23,string.format('Reported RS L:%s/%s R:%s/%s',tostring(n.applied.left or '?'),tostring(n.applied.right or '?'),tostring(n.applied.top or '?'),tostring(n.applied.bottom or '?')),'8')
        end
      end
    elseif page==5 then
      local roles={[10]='CONTROL',[11]='UI/RELAY',[12]='LEFT',[13]='RIGHT',[14]='ROTATION',
        [15]='DISPLAY',[16]='LF FINE',[17]='RF FINE',[18]='LB FINE',[19]='RB FINE'}
      local lines={}
      for id=10,19 do
        local n=id==15 and {time=now,ok=true,state='LOCAL DISPLAY',version=VERSION,actualId=ROLE and ROLE.actual or 15,role='ADMIN'} or t and t.nodes and t.nodes[id]
        local ns,age=nodeState(n,now)
        lines[#lines+1]=string.format('%d %-8s %s %s',id,roles[id],ns,age and string.format('%.2fs',age) or '--')
        lines[#lines+1]=' '..(n and n.state or 'NO RESPONSE')..' / '..(n and n.version or '?')
        if n and n.error then lines[#lines+1]=' '..n.error end
        if n and n.actualId then lines[#lines+1]=' Actual ID '..n.actualId..' '..tostring(n.role)..' Fine '..tostring(n.fineCount or '-') end
        if n and n.localSensors then for role,record in pairs(n.localSensors)do lines[#lines+1]=' LOCAL '..role..' '..(record.ok and 'OK' or 'ERROR')..' / NOT BODY' end end
        if n and n.gps then
          local gs=gpsState(n.gps,now);local g=n.gps
          lines[#lines+1]=' GPS '..gs..(finite(g.x) and string.format(' %.1f %.1f %.1f',g.x,g.y,g.z) or '')
          if g.error then lines[#lines+1]=' '..tostring(g.error) end
        end
      end
      model.nodeLineCount=#lines
      offset=clamp(offset or 0,0,math.max(0,#lines-(h-6)))
      for i=1,h-6 do if lines[i+offset] then put(2,i+3,lines[i+offset]:sub(1,w-2),'0') end end
      put(2,h-2,'UP/DOWN: scroll / ages use source timestamps','8')
    elseif page==1 then
      local cw=math.floor((w-11)/2)
      local lx,rx=2,w-cw
      local topY=5
      local bottomY=math.max(11,h-9)
      local middle=math.floor(w/2)+1
      rect(middle-1,6,3,1,'7');rect(middle-2,7,5,bottomY-3,'7')
      rect(middle-1,bottomY+4,3,1,'7')
      put(middle,5,'^','b');put(middle,8,'F','0','7')
      put(middle,bottomY+2,'B','0','7')
      local function bar(x,y,width,label,value,col)
        put(x,y,label,'8')
        local bw=math.max(1,width-6)
        rect(x+2,y,bw,1,'7')
        if finite(value) then
          local fill=math.floor(bw*clamp(value/15,0,1)+0.5)
          rect(x+2,y,fill,1,live and col or '8')
          put(x+width-3,y,string.format('%2d',value),live and '0' or '8')
        else put(x+width-3,y,'--','8') end
      end
      local function card(x,y,zone,label)
        local z=t and t.zones[zone]
        rect(x,y,cw,1,'7');put(x+1,y,label:sub(1,cw-1),'0','7')
        bar(x,y+1,cw,'M',z and z.main,'b')
        bar(x,y+2,cw,'S',z and z.sub,'1')
        put(x,y+3,'F','8')
        local count=z and z.fineLevels and #z.fineLevels or 5
        local bins=math.max(1,math.min(count,math.max(1,cw-2)))
        local width=math.max(1,math.floor((cw-2)/bins))
        for i=1,bins do
          local value=z and (z.fineLevels and z.fineLevels[i] or clamp(z.fine-i+1,0,1))
          if z and z.fineLevels and bins<count then
            local first=math.floor((i-1)*count/bins)+1;local last=math.floor(i*count/bins);value=0
            for n=first,last do value=value+(z.fineLevels[n] or 0)/(last-first+1) end
          end
          local xx=x+2+(i-1)*width
          rect(xx,y+3,math.max(1,width-1),1,'7')
          if value and value>0 then
            local filled=math.max(1,math.floor(math.max(1,width-1)*value+0.5))
            rect(xx,y+3,filled,1,live and '5' or '8')
          end
          if count==5 then put(xx,y+4,tostring(i),'8') end
        end
        if count~=5 then put(x,y+4,'Fine detected '..count,'8') end
        put(x,y+5,(z and ((z.phase or 'NO PHASE')..(z.mainSuppressed and ' [BLOCK]' or '')) or 'NO OUTPUT DATA'):sub(1,cw),z and z.assist and '4' or '8')
      end
      card(lx,topY,'LF','LEFT FRONT / 16')
      card(rx,topY,'RF','RIGHT FRONT / 17')
      card(lx,bottomY,'LB','LEFT REAR / 18')
      card(rx,bottomY,'RB','RIGHT REAR / 19')
      local v=t and t.thrust
      put(2,h-2,v and string.format('EST Tcmd %.2f / goal %.2f (NOT measured)',v.total,v.targetTotal) or 'Commanded output; not measured thrust','8')
    elseif page==3 then
      local lines=t and t.diagnosticLines
      if type(lines)~='table' then lines={'Update fleet.lua on computers 10 and 11'} end
      offset=clamp(offset or 0,0,math.max(0,#lines-(h-6)))
      for i=1,h-6 do
        local line=lines[i+offset]
        if type(line)=='string' then put(2,i+3,line:sub(1,w-2),live and '0' or '8') end
      end
      put(2,h-2,'UP/DOWN: scroll  '..(offset+1)..' / '..#lines,'8')
    else
      local angleLive=live and model.angle and now-model.angle.time<=TIMEOUT and (not t.sensor or t.sensor.ok)
      local angleStatus=angleLive and 'ANGLE LIVE' or (model.angle and 'ANGLE STALE' or 'ANGLE NO DATA')
      put(2,4,angleStatus,angleLive and '5' or '4')
      if not model.angle then
        center(7,'Angle input is not connected','8')
        center(9,'Graphs start when angle data arrives','8')
      else
        local ph=math.max(3,math.floor((h-9)/2))
        local function plot(y,label,key,col)
          local xmin,xmax=7,w-2
          local ymin,ymax=y+1,y+ph-1
          local range=10
          for _,sample in ipairs(model.history) do
            if now-sample.time<=HISTORY_MS then range=math.max(range,math.ceil(math.abs(sample[key])/10)*10) end
          end
          local value=angleLive and string.format('%.2f deg',model.angle[key]) or 'STALE'
          put(2,y,label..'  '..value,col)
          local mid=math.floor((ymin+ymax)/2)
          rect(xmin,mid,xmax-xmin+1,1,'7')
          put(2,ymin,'+'..range,'8');put(2,ymax,'-'..range,'8')
          for _,sample in ipairs(model.history) do
            local age=now-sample.time
            if age>=0 and age<=HISTORY_MS then
              local x=xmax-math.floor(age/HISTORY_MS*(xmax-xmin))
              local yy=math.floor(ymin+(range-sample[key])/(2*range)*(ymax-ymin)+0.5)
              put(x,yy,'*',angleLive and col or '8')
            end
          end
        end
        plot(5,'ROLL','roll','b')
        plot(6+ph,'PITCH','pitch','1')
        put(2,h-2,'History: last 60s; gaps = no samples','8')
      end
    end
    if t and type(t.error)=='string' then put(2,h-1,t.error:sub(1,w-2),'e')
    elseif not model.adminBusy and model.adminReport and model.adminReport.finished and model.adminReport.success==false then put(2,h-1,('UPDATE FAILED / ROLLBACK: '..tostring(model.adminReport.detail or '?')):sub(1,w-2),'e') end
  end
  rect(1,h,w,1,'7')
  put(2,h,'CONSOLES / NEXT: TAP FOOTER | TAB | Q','0','7')
  if model.monitorStatus then put(math.max(1,w-#model.monitorStatus),h,model.monitorStatus,'0','7') end
  buttons[#buttons+1]={x=1,y=h,w=w,h=1,action='PAGE_NEXT',enabled=true}
  buttons[#buttons+1]={x=1,y=1,w=math.max(1,w-10),h=1,action='PAGE_16',enabled=true}
  for y=1,h do
    screen.setCursorPos(1,y)
    screen.blit(table.concat(chars[y]),table.concat(fg[y]),table.concat(bg[y]))
  end
  return buttons
end
if args[1]=='test_api' then return {newModel=newModel,accept=accept,draw=draw,nodeState=nodeState,gpsState=gpsState,crossPosition=crossPosition,controlLive=controlLive,editTarget=editTarget,targetValue=targetValue,monitorOrder=monitorOrder,gpsSample=gpsSample,gpscfg=GPSCFG,navDisplay=navDisplay,direction=direction} end
local wasCandidate=FLEET15_CANDIDATE==true
local model=newModel()
local monitorName=args[1]
local selected
local monitors={}
local screens={}
local screenPages=settings and settings.get and settings.get('fleet.pages',{}) or {}
if type(screenPages)~='table' then screenPages={} end
for name,value in pairs(screenPages)do if type(value)~='number' or value%1~=0 or value<1 or value>PAGE_COUNT then screenPages[name]=nil end end
local function savePages()
  if not FLEET15_CANDIDATE and settings and settings.set then pcall(function()settings.set('fleet.pages',screenPages);settings.save()end) end
end
local screenOffsets={}
local screenNavModes={}
local opened={}
local page=7
local offset=0
local client='15:'..tostring(os.epoch('utc'))..':'..math.random(1,1000000000)
local sequence=0
local pending
model.bootStart=os.epoch('utc')
model.bootEffect=BOOT_EFFECT
local function connect()
  local radio=false
  for _,side in ipairs(redstone.getSides()) do
    if peripheral.hasType(side,'modem') then
      local ok,wireless=pcall(peripheral.call,side,'isWireless')
      if ok and wireless then
        for _,ch in ipairs({CHANNEL,ACK_CHANNEL}) do
          local good,isOpen=pcall(peripheral.call,side,'isOpen',ch)
          if good and not isOpen then
            good=pcall(peripheral.call,side,'open',ch)
            if good then opened[side]=opened[side] or {};opened[side][ch]=true end
          end
          radio=radio or good
        end
      end
    end
  end
  local names,sizes={},{}
  for _,name in ipairs(peripheral.getNames()) do
    if peripheral.hasType(name,'monitor') then
      local ok,w,h=pcall(peripheral.call,name,'getSize')
      if ok then
        names[#names+1]=name;sizes[name]=w*h

      end
    end
  end
  for name in pairs(monitors) do if not peripheral.hasType(name,'monitor') then monitors[name]=nil end end
  names=monitorOrder(names,sizes,monitorName)
  local detected=#names
  while #names>10 do table.remove(names) end
  model.monitorStatus=tostring(#names)..' ACTIVE / '..detected..' DETECTED'
  local active={}
  for _,name in ipairs(names) do
    active[name]=true
    if not monitors[name] then
      local good,scale=pcall(peripheral.call,name,'getTextScale')
      monitors[name]={scale=good and scale or nil};pcall(peripheral.call,name,'setTextScale',0.5)
    end
  end
  for name,info in pairs(monitors) do
    if not active[name] then
      if info.scale then pcall(peripheral.call,name,'setTextScale',info.scale) end
      monitors[name]=nil
    end
  end
  if FLEET15_CANDIDATE then names={} end
  selected=names[1];return radio,names
end
local function transmit(m)
  m.protocol='fleet_ui_v1';m.source=15;m.time=os.epoch('utc');m.client=client
  m.session=model.packet and model.packet.session
  for _,side in ipairs(redstone.getSides()) do
    if peripheral.hasType(side,'modem') then
      local ok,wireless=pcall(peripheral.call,side,'isWireless')
      if ok and wireless then pcall(peripheral.call,side,'transmit',UI_CHANNEL,ACK_CHANNEL,m) end
    end
  end
end
local function act(action,display)
  local now=os.epoch('utc')
  local chosen=action:match('^PAGE_(%d+)$')
  if chosen then
    chosen=tonumber(chosen);if chosen>=1 and chosen<=PAGE_COUNT then screenPages[display or selected or 'terminal']=chosen;if not display then page=chosen end;savePages() end;return
  end
  if action:sub(1,5)=='FORM_' then
    local field=action:sub(6)
    if field=='COPY' then
      if gpsState(model.gps,now)=='FIX' then model.forms[model.form or 'hoverY']=string.format('%.1f',model.gps.y) end
    elseif model.forms[field]~=nil then model.form=field end;return
  end
  if action:sub(1,6)=='FEDIT_' then
    local key=action:sub(7);local f=model.form or 'hoverY';local v=model.forms[f] or ''
    if key=='CLEAR' then v='' elseif key=='BACK' then v=v:sub(1,-2)
    elseif key=='-' then v=v:sub(1,1)=='-' and v:sub(2) or '-'..v
    elseif key=='.' then if not v:find('.',1,true) then v=v..'.' end
    elseif key:match('^%d$') and #v<12 then v=v..key end
    model.forms[f]=v;return
  end
  if action:sub(1,5)=='KIND_' then model.testKind=action:sub(6);return end
  if action=='UPDATE_ALL' then
    if FLEET15 and FLEET15.requestUpdate and not model.adminBusy then
      if FLEET15.requestUpdate() then model.adminBusy=true;model.commandText='UPDATE ALL accepted' end
    else model.commandText='Update busy or startup_15 required' end
    return
  end
  local stopping=action=='STOP' or action=='MOTION_STOP' or action=='ADMIN_STOP' or action=='NAV_CANCEL' or action=='TEST_ABORT'
  if action=='ADMIN_STOP' and FLEET15 and FLEET15.emergencyStop then FLEET15.emergencyStop() end
  if action=='NAV_EDIT' or action=='NAV_STATUS' then
    screenNavModes[display or 'terminal']=action=='NAV_EDIT' and 'EDIT' or 'STATUS';return
  end
  if action=='PAGE_NEXT' then
    if display then screenPages[display]=((screenPages[display] or 7)%PAGE_COUNT)+1;screenOffsets[display]=0
    else page=page%PAGE_COUNT+1;offset=0;if selected then screenPages[selected]=page end end
    savePages();return
  end
  if action=='PAGE_NAV' then
    if display then screenPages[display]=6;screenOffsets[display]=0 else page=6;offset=0;if selected then screenPages[selected]=6 end end
    savePages();return
  end
  if action:sub(1,5)=='AXIS_' then model.axis=action:sub(6);return end
  if action:sub(1,5)=='EDIT_' then editTarget(model,action:sub(6));return end
  if action=='COPY_GPS' then
    if gpsState(model.gps,now)=='FIX' then
      for _,axis in ipairs({'x','y','z'}) do model.target[axis]=tostring(math.floor(model.gps[axis]+0.5)) end
    end
    return
  end
  if model.adminBusy and not stopping then model.commandText='UPDATE in progress';return end
  if not stopping and not controlLive(model,now) then model.commandText='BLOCKED: CONTROL STALE';return end
  if pending and not stopping then model.commandText='WAIT for command ACK';return end
  local target
  if action=='NAV_START' then
    target=targetValue(model)
    if not target or gpsState(model.gps,now)~='FIX' then model.commandText='Valid XYZ and GPS FIX required';return end
  end
  if action=='HOVER_START' or action=='DRIVE' or action=='TEST_START' then
    local f=model.forms
    target=action=='HOVER_START' and {y=tonumber(f.hoverY)} or action=='DRIVE' and {heading=tonumber(f.heading),speed=tonumber(f.speed)} or {test=model.testKind,y=tonumber(f.testY),heading=tonumber(f.testHeading),speed=tonumber(f.testSpeed),duration=tonumber(f.duration)}
    if gpsState(model.gps,now)~='FIX' then model.commandText='Fresh GPS required';return end
  end
  if action=='ARM' or action=='NAV_START' or action=='HOVER_START' or action=='DRIVE' or action=='TEST_START' then
    if model.confirm~=action or now>(model.confirmUntil or 0) then
      model.confirm=action;model.confirmUntil=now+4000;model.commandText='Tap again to confirm '..action;return
    end
  end
  model.confirm=nil
  sequence=sequence+1
  pending={kind='PILOT',action=action,target=target,seq=sequence,started=now,lastSent=now}
  transmit(pending);model.commandText='SENT #'..sequence..' '..action
end
local function redraw()
  if wasCandidate and not FLEET15_CANDIDATE and FLEET_VIEW_BLACKOUT then FLEET_VIEW_BLACKOUT() end
  local radio,names=connect()
  model.hasMonitor=#names>0
  model.adminManaged=FLEET15~=nil and FLEET15.ready==true and (not FLEET15.serviceAvailable or FLEET15.serviceAvailable())
  model.adminBusy=FLEET15~=nil and FLEET15.busy==true
  local now=os.epoch('utc')
  screens={}
  local roles={7,6,1,2,5,8,3,7,6,8}
  if #names==0 then
    local shown=BOOT_EFFECT and now-model.bootStart<5500 and 0 or (screenPages.terminal or page)
    local ok,buttons=pcall(draw,term.current(),model,now,shown,radio,offset,screenNavModes.terminal)
    screens.terminal=ok and buttons or {}
  else
    for i,name in ipairs(names) do
      local initial=i==1 and page or roles[i]
      screenPages[name]=screenPages[name] or initial
      local shown=BOOT_EFFECT and now-model.bootStart<5500 and 0 or screenPages[name]
      local scroll=screenOffsets[name] or (i==1 and offset or 0)
      local screen=peripheral.wrap(name)
      local ok,buttons=pcall(draw,screen,model,now,shown,radio,scroll,screenNavModes[name])
      screens[name]=ok and buttons or {}
    end
  end
end
local function run()
  redraw()
  if FLEET15_HEALTH then FLEET15_HEALTH(VERSION) end
  local timer=os.startTimer(0.25)
  while true do
    local e,a,b,c,d=os.pullEvent()
    local update=false
    if e=='fleet15_boot' then model.bootStart=os.epoch('utc');update=true end
    if e=='modem_message' and (b==CHANNEL or b==ACK_CHANNEL) then
      local ok,wireless=pcall(peripheral.call,a,'isWireless')
      if ok and wireless then
        if b==CHANNEL then
          local previous=model.session
          if accept(model,d,os.epoch('utc')) and previous and previous~=model.session then
            pending=nil;model.confirm=nil;model.commandText='Controller session changed'
          end
        elseif type(d)=='table' and d.protocol=='fleet_ack_v1' and d.source==11 and finite(d.time)
          and math.abs(os.epoch('utc')-d.time)<2000 and type(d.ack)=='table' then
          local ack=d.ack
          if pending and ack.client==client and ack.seq==pending.seq then
            model.commandText=(ack.ok and 'ACK COMMAND: ' or 'REJECTED: ')..tostring(ack.reason)
            pending=nil
          end
        end
        update=true
      end
    elseif e=='key' then
      if selected and screenPages[selected] then page=screenPages[selected] end
      if a==keys.q then return end
      if a==keys.space then act(page==8 and 'ADMIN_STOP' or 'STOP');update=true
      elseif page==6 and a==keys.backspace then editTarget(model,'BACKSPACE');update=true
      elseif page==6 and a==keys.enter then act('NAV_START');update=true
      elseif a==keys.tab or a==keys.left or a==keys.right then act('PAGE_NEXT');update=true
      elseif a==keys.up then offset=math.max(0,offset-1);if selected then screenOffsets[selected]=offset end;update=true
      elseif a==keys.down then offset=math.min(80,offset+1);if selected then screenOffsets[selected]=offset end;update=true
      elseif page~=6 then
        local map={[keys.one]=1,[keys.two]=2,[keys.three]=3,[keys.four]=4,[keys.five]=5,[keys.six]=6,[keys.seven]=7,[keys.eight]=8}
        if map[a] then page=map[a];offset=0;if selected then screenPages[selected]=page;screenOffsets[selected]=0 end;savePages();update=true end
      end
    elseif e=='char' and (page==9 or page==10 or page==11) then
      if a:match('^[0-9%.%-]$') then act('FEDIT_'..a,selected);update=true end
    elseif e=='char' and page==6 then
      if a:match('^[0-9%-]$') then editTarget(model,a);update=true
      elseif a=='x' or a=='y' or a=='z' then model.axis=a;update=true end
    elseif e=='monitor_touch' and screens[a] then
      for _,button in ipairs(screens[a] or {}) do
        if b>=button.x and b<button.x+button.w and c>=button.y and c<button.y+button.h and button.enabled then
          act(button.action,a);update=true;break
        end
      end
    elseif e=='timer' and a==timer then
      local now=os.epoch('utc')
      if model.confirm and now>(model.confirmUntil or 0) then model.confirm=nil end
      if pending then
        if now-pending.started>3000 then model.commandText='NO ACK: command outcome unknown';pending=nil
        elseif now-pending.lastSent>=500 then pending.lastSent=now;transmit(pending) end
      end
      update=true;timer=os.startTimer(0.25)
    elseif e=='monitor_resize' or e=='peripheral' or e=='peripheral_detach' then update=true end
    if update then redraw() end
  end
end
local function gpsReader()
  while true do
    local ok,x,y,z=pcall(gps.locate,GPSCFG.gpsLocateTimeout,false)
    model.gps=gpsSample(model.gps,ok,x,y,z,os.epoch('utc'))
    sleep(GPSCFG.pollSeconds)
  end
end
local function heartbeat()
  while true do if not FLEET15_CANDIDATE then transmit({kind='GPS',fix=model.gps}) end;sleep(0.5) end
end
local function adminReports()
  while true do
    local ok,report=pcall(function()
      if not fs.exists('fleet_deploy_last.txt') then return nil end
      local h=fs.open('fleet_deploy_last.txt','r');if not h then return nil end
      local data=h.readAll();h.close()
      if #data>1048576 then return nil end
      local t=textutils.unserialize(data)
      if type(t)=='table' and type(t.targets)=='table' then return t end
    end)
    if ok then model.adminReport=report end
    sleep(.25)
  end
end
FLEET_VIEW_BLACKOUT=function()
  wasCandidate=false
  model.bootStart=os.epoch('utc')
  if not BOOT_EFFECT then return end
  local _,names=connect()
  for _,name in ipairs(names)do pcall(function()local m=peripheral.wrap(name);m.setBackgroundColor(colors.black);m.clear()end)end
end
local ok,err=pcall(function() parallel.waitForAny(run,gpsReader,heartbeat,adminReports,ROLE.run) end)
for side,channels in pairs(opened) do for ch in pairs(channels) do pcall(peripheral.call,side,'close',ch) end end
for name,info in pairs(monitors) do
  pcall(peripheral.call,name,'setBackgroundColor',colors.black)
  pcall(peripheral.call,name,'setTextColor',colors.white)
  pcall(peripheral.call,name,'clear');pcall(peripheral.call,name,'setCursorPos',1,1)
  pcall(peripheral.call,name,'write','DISPLAY STOPPED')
  if info.scale then pcall(peripheral.call,name,'setTextScale',info.scale) end
end
if not ok then print(tostring(err)) end
