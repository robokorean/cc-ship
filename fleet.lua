local args={...}
local MAIN_COUNT=7
local SUB_COUNT=3
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
local VERSION='2026.10.24-r19'
local CFG={tick=0.05,finePower=1,nodeTimeout=1,commandTimeout=3,
  stopWriteTimeout=0.75,
  relayTimeout=0.5,assistDelay=3,assistRise=1,releaseRate=8,mainSlew=4,
  deadzone=0.5,hoverDeadzone=0.5,movingDeadzone=1,moveEnterSpeed=1,moveExitSpeed=0.3,moveExitSeconds=2,kp=0.7,kd=0.12,fineRise=2.75,fineFall=3.5,sensor='gimbal_sensor_1'}
local NAVCFG={courseVerified=true,yawSign=1,hoverMain=9,maxMain=10,maxVector=18,
  turnVector=18,minCourseSpeed=0.5,maxSpeed=3,arrivalRadius=10,arrivalY=5,
  arrivalSpeed=0.5,arrivalHold=3,gpsTimeout=5,uiTimeout=3,mainRate=0.25,cruiseY=350,altitudeBand=20,safetyDrop=80,stableVertical=1,
  stableTilt=5,stableRate=3,stabilizeSeconds=3,probeVector=24,probeSeconds=4,probeHoldSeconds=3,
  probeFixes=2,probeDistance=1,probeMaxSpeed=1.5,courseTimeout=5,
  alignDegrees=15,turnSeconds=3,brakeVector=6}
local YAWCFG={bodyIds={12,13},bowSign=1,bowSignSource='DEFAULT_LEFT_RIGHT_UP',yawOffset=0,maxAge=2,maxSkew=0.25,
  mountDistance=5,mountTolerance=0.75,minHorizontal=1.5,recoverFixes=3,maxTilt=70,
  maxRate=120,rateFilter=0.4,alignError=5,exitError=10,settleRate=2,alignSeconds=1,
  prediction=1,fineBand=15,maxVector=24,vectorRate=12,maxBoost=1,boostRise=0.5,boostFall=2,
  slipDegrees=60,slipSpeed=1,gpsLocateTimeout=2.5,gpsPollSeconds=0.5}
local LANDCFG={far=50,middle=20,near=5,fast=2,medium=1,slow=0.5,creep=0.2,
  tolerance=0.75,holdSpeed=0.25,positionGain=0.2,velocityGain=0.8,maxAscent=1,
  prediction=3,excessSpeed=0.5,brakeRise=2,resumeSeconds=3,exitRadius=1.5,yOffset=0}
-- CORE: 12=LEFT, 13=RIGHT. Default bow uses body-up convention; fleet.bow_sign=-1 is exceptional reversal. 0=X+, 90=Z+.
-- ID 11: fleet.velocity_lateral_sign / forward_sign / vertical_sign = +1 or -1.
local VELCFG={maxAge=0.5,pollSeconds=0.1,lateralSign=1,forwardSign=1,verticalSign=1,
  forwardLimit=50,reverseLimit=30,limitMargin=2,cruiseSpeed=3,acceleration=0.5,
  deceleration=0.5,speedGain=6,slipThreshold=2,maxCrab=15}
local CRUISECFG={lockError=7,lockExit=12,lockRate=2,lockSeconds=1,
  acceleration=3,slipNormal=2,slipSevere=4,slipRelease=3.5,slipDeceleration=1,
  slipFilter=0.5,brakeMargin=20,reactionSeconds=1.5,minimumDeceleration=0.05,
  brakeSamples=5,brakeWindow=20,speedDeadband=0.35,integralGain=0.8,maxIntegral=12,
  holdVector=6,vectorRise=12,vectorFall=12,quantHysteresis=1,reverseError=1,
  distanceBands={{1000,50},{500,40},{250,30},{100,18},{50,9},{0,3}}}
local function setting(name,default)
  if settings and settings.get then local ok,v=pcall(settings.get,name,default);if ok then return v end end
  return default
end
do
  local raw=setting('fleet.bow_sign',nil)
  if raw==nil then YAWCFG.bowSign=1;YAWCFG.bowSignSource='DEFAULT_LEFT_RIGHT_UP'
  else
    local v=tonumber(raw)
    if v==1 or v==-1 then YAWCFG.bowSign=v;YAWCFG.bowSignSource='EXPLICIT_OVERRIDE'
    else YAWCFG.bowSign=nil;YAWCFG.bowSignSource='INVALID_SETTING' end
  end
end
YAWCFG.yawOffset=tonumber(setting('fleet.bow_offset',0))
YAWCFG.legacyOffset=setting('fleet.yaw_offset',nil)
do
  local v=tonumber(setting('fleet.yaw_mount_tolerance',YAWCFG.mountTolerance));if v and v==v and v>=0.25 and v<=2 then YAWCFG.mountTolerance=v end
  v=tonumber(setting('fleet.yaw_horizontal_min',YAWCFG.minHorizontal));if v and v==v and v>=0.5 and v<=4.5 then YAWCFG.minHorizontal=v end
  v=tonumber(setting('fleet.yaw_recover_fixes',YAWCFG.recoverFixes));if v and v==v and v>=2 and v<=10 then YAWCFG.recoverFixes=math.floor(v) end
  v=tonumber(setting('fleet.yaw_max_tilt',YAWCFG.maxTilt));if v and v==v and v>=30 and v<=85 then YAWCFG.maxTilt=v end
end
for _,role in ipairs({'lateral','forward','vertical'}) do
  local v=tonumber(setting('fleet.velocity_'..role..'_sign',1))
  VELCFG[role..'Sign']=(v==1 or v==-1) and v or 1
end
do local v=tonumber(setting('fleet.cruise_speed',3));if v and v==v and math.abs(v)<math.huge then VELCFG.cruiseSpeed=math.max(-30,math.min(50,v)) end end
local MODECFG={verticalGain=0.8,positionGain=0.2,hoverTrimGain=0.03,hoverTrimLimit=1,
  testDuration=20,testMaxDuration=60,testSample=0.25,testHeightLimit=20}
local TEST_RECORDS=setmetatable({},{__mode='k'})
local pendingTestLogs={}
local UI_CHANNEL=42111
local ACK_CHANNEL=42112
local RELAYS={back='redstone_relay_24',right='redstone_relay_23',
  front='redstone_relay_21',left='redstone_relay_22'}
local PROTO='fleet_v2'
local IDS={12,13,14,16,17,18,19}
local FINE={[16]={zone='LF'},[17]={zone='RF'},
  [18]={zone='LB'},[19]={zone='RB'}}
local SIDES={[12]={left='LFs',top='LBs',right='LFm',bottom='LBm'},
  [13]={left='RFm',top='RBs',right='RFs',bottom='RBm'},
  [14]={left='LFWD',right='LBACK',top='RFWD',bottom='RBACK'}}
local function clamp(v,a,b) return math.max(a,math.min(b,v)) end
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function validArray(t,n)
  if type(t)~='table' or #t~=n then return false end
  for i=1,n do if not finite(t[i]) then return false end end
  return true
end
local function uid() return tostring(os.epoch('utc'))..':'..math.random(1,1000000000) end
local function fresh(m,ms)
  if type(m)~='table' or not finite(m.time) then return false end
  local age=os.epoch('utc')-m.time
  return age>=-100 and age<=ms
end
local function roleWorker()
  ROLE.run()
end
local function receiveFlight(protocol)
  while true do local id,m=rednet.receive(protocol);local slot=ROLE.logical(id)
    if slot then return slot,m end
  end
end
local function send(id,m)
  m.time=os.epoch('utc');local actual=ROLE.resolve(id);if actual then return rednet.send(actual,m,PROTO) end;return false
end
local function wiring()
  local owned={}
  local id=ROLE.slot
  local wired,wireless=0,0
  for _,side in ipairs(redstone.getSides()) do
    if peripheral.hasType(side,'modem') then
      local radio=peripheral.call(side,'isWireless')
      local use=id==10 or (FINE[id] and radio) or (not FINE[id] and not radio)
      if use then
        if radio then wireless=wireless+1 else wired=wired+1 end
        if not rednet.isOpen(side) then rednet.open(side);owned[#owned+1]=side end
      end
    end
  end
  local missing=(id==10 and (wired==0 or wireless==0))
    or (FINE[id] and wireless==0) or (id~=10 and not FINE[id] and wired==0)
  if missing then
    for _,side in ipairs(owned) do pcall(rednet.close,side) end
    error(id==10 and 'ID 10 needs wired + ender modems'
      or FINE[id] and 'Fine node needs an ender modem' or 'Wired modem required',0)
  end
  return function() for _,side in ipairs(owned) do pcall(rednet.close,side) end end
end
local function relayValid(t)
  if type(t)~='table' then return false end
  for direction in pairs(RELAYS) do
    local v=t[direction]
    if not finite(v) or v<0 or v>15 or v%1~=0 then return false end
  end
  return true
end
local function geometry(g,previous)
  assert(validArray(g,3),'Invalid gravity')
  local length=math.sqrt(g[1]^2+g[2]^2+g[3]^2)
  assert(length>0.001,'Zero gravity vector')
  local tilt=math.deg(math.acos(clamp(-g[2]/length,-1,1)))
  local h=math.sqrt(g[1]^2+g[3]^2)
  local axis
  if h/length>0.00001 then axis={g[3]/h,g[1]/h}
  else axis=previous or {1,0} end
  if tilt<0.000001 then return 0,0,axis,tilt end
  return tilt*axis[1],tilt*axis[2],axis,tilt
end
local function zones(r,p)
  return {LF=math.max(0,-r,p),LB=math.max(0,-r,-p),
    RF=math.max(0,r,p),RB=math.max(0,r,-p)}
end
local function allocate(signal,count)
  local fine={}
  for i=1,(count or 5) do fine[i]=clamp(signal-i+1,0,1)*CFG.finePower end
  return fine
end
local THRUST={Kmain=1,Ksub=1,Kfine=1,mainCount=MAIN_COUNT,subCount=SUB_COUNT,fineCount=5,
  handoffSeconds=1.75,mainDelay=CFG.assistDelay,rise=CFG.fineRise,fall=CFG.fineFall,
  recoveryFall=4,mainRise=0.75,mainFall=2,mainError=2,mainClosing=1.5,
  fastClosing=3,releaseHorizon=2}
local ZONES={'LF','RF','LB','RB'}
local function capacities(count)
  assert(THRUST.Kmain>0 and THRUST.Ksub>0 and THRUST.Kfine>0,'Thrust coefficients must be positive')
  assert(CFG.finePower>0 and CFG.finePower<=1,'finePower must be in (0,1]')
  local m=THRUST.mainCount*THRUST.Kmain
  local s=THRUST.subCount*THRUST.Ksub
  local f=(count or THRUST.fineCount)*THRUST.Kfine*CFG.finePower
  return m,s,f
end
local function estimate(m,s,f)
  local total=0;for i=1,#f do total=total+(f[i] or 0) end
  return THRUST.Kmain*THRUST.mainCount*m/15+THRUST.Ksub*THRUST.subCount*s/15+THRUST.Kfine*total
end
local function newMixer(counts)
  local engine={zones={},counts=counts or {LF=5,RF=5,LB=5,RB=5}}
  for _,z in ipairs(ZONES) do
    engine.zones[z]={fineCount=engine.counts[z] or 5,total=0,main=0,sub=0,fine=0,mainBlend=0,subBlend=0,hold=0,latched=false,assisting=false,phase='FINE'}
  end
  return engine
end
local function balance(r,p,base,counts)
  local signed={LF=-r+p,RF=r+p,LB=-r-p,RB=r-p}
  local inc,dec,add,cut={},{},0,0
  local diag={paired=0,unpaired=0,saturated=0,baseTotal=base*4}
  for _,z in ipairs(ZONES) do
    local cm,cs,cf=capacities(counts and counts[z]);local maximum=cm+cs+cf
    inc[z]=math.min(math.max(0,signed[z]),math.max(0,maximum-base))
    dec[z]=math.min(math.max(0,-signed[z]),base)
    add=add+inc[z];cut=cut+dec[z]
    diag.saturated=diag.saturated+math.max(0,signed[z]-inc[z])
  end
  local reductionScale=cut>add and add/cut or 1
  local targets={}
  for _,z in ipairs(ZONES) do targets[z]=math.max(0,base+inc[z]-dec[z]*reductionScale) end
  diag.paired=math.min(add,cut);diag.unpaired=math.max(0,add-cut)
  diag.headroomLimited=diag.unpaired>1e-8 or diag.saturated>1e-8
  return targets,diag,signed
end
local function recoveryState(z,motion)
  if type(motion)~='table' then
    return {known=false,error=0,closing=0,blocked=true,fast=motion==true}
  end
  if not finite(motion.roll) or not finite(motion.pitch)
    or not finite(motion.rateR) or not finite(motion.rateP) then
    return {known=false,error=0,closing=0,blocked=true,fast=false}
  end
  local sr=(z=='LF' or z=='LB') and -1 or 1
  local sp=(z=='LF' or z=='RF') and 1 or -1
  local er,ep=math.max(0,sr*motion.roll-CFG.deadzone),math.max(0,sp*motion.pitch-CFG.deadzone)
  local weight=er+ep
  local closing=weight>0 and -(er*sr*motion.rateR+ep*sp*motion.rateP)/weight or 0
  local error=math.max(er,ep)
  local fast=closing>=THRUST.fastClosing or (closing>0 and error/closing<=THRUST.releaseHorizon)
  return {known=true,error=error,closing=closing,fast=fast,
    blocked=motion.recovery==true or error<THRUST.mainError or closing>=THRUST.mainClosing or fast}
end
local function prepareZone(st,goal,baseLevel,dt,motion)
  local cm,cs,cf=capacities(st.fineCount);local qm=cm/15
  local base=baseLevel*qm
  local extra=st.total-base
  local wanted=goal-base
  if wanted>math.min(cs,cf)+1e-6 and extra>=math.min(cs,cf)-1e-6 then st.latched=true end
  if wanted<cs-0.2 then st.latched=false end
  local desiredSub=st.latched and 15 or 0
  st.subBlend=st.subBlend+clamp(desiredSub-st.subBlend,-15*dt/THRUST.handoffSeconds,15*dt/THRUST.handoffSeconds)
  local subComplete=st.subBlend>=15-1e-6
  local saturated=st.sub==15 and st.fine*THRUST.Kfine>=cf-1e-6
  local needsMain=wanted>cs+cf+1e-6
  if motion.blocked or not needsMain then st.hold=0;st.assisting=false
  elseif not st.assisting then
    if subComplete and saturated then st.hold=st.hold+dt else st.hold=0 end
    if st.hold>=THRUST.mainDelay then st.assisting=true end
  end
  local assist=st.assisting
  if st.main>baseLevel and not assist then st.subBlend=st.sub end
  local desiredMain=assist and 15 or baseLevel
  if not assist and not st.releasing then st.mainBlend=math.min(st.mainBlend,math.max(baseLevel,st.main)) end
  st.releasing=not assist
  local step=desiredMain>st.mainBlend and THRUST.mainRise or THRUST.mainFall
  if desiredMain>st.mainBlend and st.mainBlend<baseLevel then step=CFG.mainSlew end
  st.mainBlend=st.mainBlend+clamp(desiredMain-st.mainBlend,-step*dt,step*dt)
  if assist then st.mainBlend=math.min(st.mainBlend,math.max(baseLevel,st.main)+1) end
  local maxMain
  if st.mainBlend>=st.main then maxMain=math.floor(st.mainBlend+1e-8)
  else maxMain=math.ceil(st.mainBlend-1e-8) end
  maxMain=clamp(math.max(baseLevel,maxMain,st.main),0,15)
  local maxSub=math.min(15,math.max(st.sub,math.ceil(st.subBlend-1e-8)))
  local ceiling=base+cs
  if subComplete then ceiling=base+cs+cf end
  if assist or st.main>baseLevel then ceiling=maxMain*qm+cs+cf end
  local releaseGoal
  if st.main>baseLevel and not assist then releaseGoal=math.max(baseLevel,st.mainBlend)*qm+cs+cf end
  local minMain,minSub=0,0
  if st.main>baseLevel and not assist then
    minMain=math.min(st.main,math.ceil(st.mainBlend-1e-8));minSub=st.sub
  end
  ceiling=math.min(ceiling,maxMain*qm+maxSub*cs/15+cf)
  ceiling=math.max(st.total,ceiling)
  st.phase=assist and 'MAIN+TRIM' or (st.subBlend>1e-6 and not subComplete and 'HANDOFF' or subComplete and 'SUB+FINE' or 'FINE')
  if (st.main>baseLevel or st.mainBlend>baseLevel+1e-6) and not assist then st.phase='MAIN RELEASE' end
  return {maxMain=maxMain,maxSub=maxSub,mainTarget=st.mainBlend,subTarget=st.subBlend,
    ceiling=ceiling,assist=assist,suppressed=motion.blocked,closing=motion.closing,
    error=motion.error,fast=motion.fast,hold=st.hold,releaseGoal=releaseGoal,
    minMain=minMain,minSub=minSub,floor=minMain*qm+minSub*cs/15}
end
local function quantize(st,total,plan)
  local cm,cs,cf=capacities(st.fineCount);local qm,qs=cm/15,cs/15
  local best,cost
  local function search(ml,mh,sl,sh)
    for m=ml,mh do for s=sl,sh do
      local residual=total-m*qm-s*qs
      if residual>=-1e-8 and residual<=cf+1e-8 then
        local score=100*math.abs(m-plan.mainTarget)+10*math.abs(s-plan.subTarget)+0.01*math.max(0,residual)
        if not cost or score<cost then best={main=m,sub=s,fineUnits=clamp(residual,0,cf)};cost=score end
      end
    end end
  end
  search(math.max(plan.minMain,st.main-1),math.min(plan.maxMain,st.main+1),math.max(plan.minSub,st.sub-1),math.min(plan.maxSub,st.sub+1))
  if not best then search(plan.minMain,plan.maxMain,plan.minSub,plan.maxSub) end
  assert(best,'No feasible thrust allocation')
  best.fineLevels=allocate(best.fineUnits/(THRUST.Kfine*CFG.finePower),st.fineCount)
  best.fine=best.fineUnits/THRUST.Kfine
  best.total=estimate(best.main,best.sub,best.fineLevels)
  return best
end
local function mixStep(engine,r,p,baseLevel,dt,enabled,recovery,baseDemand)
  if not enabled then
    local zero=newMixer(engine.counts);engine.zones=zero.zones
    local out={}
    for _,z in ipairs(ZONES) do out[z]={main=0,sub=0,fine=0,fineLevels=allocate(0,engine.counts[z]),total=0,target=0,phase='OFF',assist=false,signal=0} end
    return out,{total=0,targetTotal=0,net=0,paired=0,unpaired=0,headroomLimited=false}
  end
  dt=clamp(dt,0,0.2);baseLevel=clamp(math.floor(baseLevel+0.5),0,15)
  local cm=capacities();local base=cm*clamp(baseDemand or baseLevel,0,15)/15
  local goals,diag,signed=balance(r,p,base,engine.counts)
  local plans,candidate={},{}
  local sumOld,sumGoal,up,down=0,0,0,0
  local fast=recovery==true
  for _,z in ipairs(ZONES) do fast=fast or recoveryState(z,recovery).fast end
  local fall=fast and THRUST.recoveryFall or THRUST.fall
  for _,z in ipairs(ZONES) do
    local st=engine.zones[z];local motion=recoveryState(z,recovery)
    plans[z]=prepareZone(st,goals[z],baseLevel,dt,motion)
    if plans[z].releaseGoal then goals[z]=math.min(goals[z],plans[z].releaseGoal) end
    goals[z]=math.max(goals[z],plans[z].floor)
    local target=math.min(goals[z],plans[z].ceiling)
    local delta=clamp(target-st.total,-fall*dt,THRUST.rise*dt)
    candidate[z]=delta
    sumOld=sumOld+st.total;sumGoal=sumGoal+goals[z]
    up=up+math.max(0,delta);down=down+math.max(0,-delta)
  end
  local requestedNet=clamp(sumGoal-sumOld,-4*fall*dt,4*THRUST.rise*dt)
  local net=clamp(requestedNet,-down,up)
  local upScale,downScale=1,1
  if up-down>net and up>0 then upScale=clamp((down+net)/up,0,1)
  elseif up-down<net and down>0 then downScale=clamp((up-net)/down,0,1) end
  local out={};local total=0
  for _,z in ipairs(ZONES) do
    local st=engine.zones[z];local d=candidate[z]
    d=d>=0 and d*upScale or d*downScale
    local desired=math.max(0,st.total+d)
    local v=quantize(st,math.min(desired,plans[z].ceiling),plans[z])
    st.main=v.main;st.sub=v.sub;st.fine=v.fine;st.total=v.total
    v.phase=st.phase;v.assist=plans[z].assist;v.target=goals[z];v.signal=math.max(0,signed[z])
    v.correction=st.total-base;v.ceiling=plans[z].ceiling
    v.mainSuppressed=plans[z].suppressed;v.closing=plans[z].closing;v.mainHold=plans[z].hold
    out[z]=v;total=total+v.total
  end
  diag.total=total;diag.targetTotal=sumGoal;diag.net=total-sumOld
  diag.estimate='COMMAND-EQUIVALENT / NOT MEASURED'
  return out,diag
end
local function rotationValues(left,right)
  assert(finite(left) and finite(right),'Invalid rotation angle')
  local function level(v) return math.floor(math.abs(clamp(v,-90,90))/6+0.5) end
  return {left=left>0 and level(left) or 0,right=left<0 and level(left) or 0,
    top=right>0 and level(right) or 0,bottom=right<0 and level(right) or 0}
end
local function attitudeMotionStep(s,velocity,actual,gpsState,rotation,armed,time)
  local speed,source
  if finite(velocity.forward) and finite(velocity.lateral) and finite(velocity.vertical) then
    speed=math.max(math.sqrt(velocity.forward^2+velocity.lateral^2),math.abs(velocity.vertical));source='VELOCITY'
  elseif gpsState=='FIX' and actual and finite(actual.sampleTime) and time-actual.sampleTime>=-100 and time-actual.sampleTime<=1500
    and finite(actual.horizontalSpeed) and finite(actual.vy) then
    speed=math.max(actual.horizontalSpeed,math.abs(actual.vy));source='GPS'
  end
  local commanded=armed and rotation.enabled and (math.abs(rotation.left or 0)>0 or math.abs(rotation.right or 0)>0)
  local changed=false
  if not armed then changed=s.moving==true;s.moving=false;s.quietSince=nil
  elseif commanded or (speed and speed>=CFG.moveEnterSpeed) or not speed then
    changed=s.moving~=true;s.moving=true;s.quietSince=nil
  elseif s.moving and speed<=CFG.moveExitSpeed then
    s.quietSince=s.quietSince or time
    if time-s.quietSince>=CFG.moveExitSeconds*1000 then s.moving=false;s.quietSince=nil;changed=true end
  else s.quietSince=nil end
  s.speed=speed;s.source=source or 'UNKNOWN';s.commanded=commanded==true
  s.mode=s.moving and 'MOVING' or 'HOVER';s.deadzone=s.moving and CFG.movingDeadzone or CFG.hoverDeadzone
  CFG.deadzone=s.deadzone
  return s.deadzone,changed
end
local function axisDemand(e,rate)
  if math.abs(e)<=CFG.deadzone then return 0 end
  local sign=e>0 and 1 or -1
  local excess=math.abs(e)-CFG.deadzone
  if rate*sign<0 then excess=math.min(excess,math.max(0,sign*(e+rate*0.5)-CFG.deadzone)) end
  return sign*clamp(CFG.kp*excess+CFG.kd*rate*sign,0,35)
end
local RECOVERY={enterTilt=18,enterRate=25,rateTilt=5,exitTilt=6,exitRate=3,
  settleSeconds=3,minSeconds=2,crossWindow=8,growth=1.15,growingCrossings=2,
  prediction=0.8,kp=0.35,kd=0.35,maxDemand=8,centreTilt=6,centreDemand=3,demandRate=5}
local function newRecovery()
  return {active=false,age=0,stable=0,axes={{peak=0,lastPeak=0,crossings={}},{peak=0,lastPeak=0,crossings={}}},r=0,p=0}
end
local function recoveryStep(s,r,p,rr,rp,tilt,dt,time)
  local growing=false
  for i,e in ipairs({r,p}) do
    local a=s.axes[i];local sign=e>0.2 and 1 or e< -0.2 and -1 or a.sign
    if sign and a.sign and sign~=a.sign then
      if a.lastPeak>1 and a.peak>a.lastPeak*RECOVERY.growth then a.crossings[#a.crossings+1]=time end
      a.lastPeak=a.peak;a.peak=math.abs(e)
    else a.peak=math.max(a.peak,math.abs(e)) end
    a.sign=sign
    while #a.crossings>0 and time-a.crossings[1]>RECOVERY.crossWindow do table.remove(a.crossings,1) end
    growing=growing or #a.crossings>=RECOVERY.growingCrossings
  end
  local speed=math.max(math.abs(rr),math.abs(rp))
  local enter=tilt>=RECOVERY.enterTilt or (tilt>=RECOVERY.rateTilt and speed>=RECOVERY.enterRate) or growing
  if not s.active and enter then s.active=true;s.age=0;s.stable=0;s.reason=growing and 'GROWING OSCILLATION' or 'TILT / ANGULAR RATE' end
  if s.active then
    s.age=s.age+dt
    if tilt<=RECOVERY.exitTilt and speed<=RECOVERY.exitRate then s.stable=s.stable+dt else s.stable=0 end
    if s.age>=RECOVERY.minSeconds and s.stable>=RECOVERY.settleSeconds then
      s.active=false;s.reason='SETTLED';s.stable=0
      for _,a in ipairs(s.axes) do a.crossings={};a.peak=0;a.lastPeak=0 end
    end
  end
  return s.active
end
local function recoveryDemand(s,r,p,rr,rp,dt)
  local function axis(e,rate,old)
    local predicted=e+rate*RECOVERY.prediction
    local excess=math.max(0,math.abs(predicted)-CFG.deadzone)*(predicted>=0 and 1 or -1)
    local limit=math.abs(e)<=RECOVERY.centreTilt and RECOVERY.centreDemand or RECOVERY.maxDemand
    local target=clamp(RECOVERY.kp*excess+RECOVERY.kd*rate,-limit,limit)
    if math.abs(e)<=CFG.deadzone and math.abs(rate)<=RECOVERY.exitRate then target=0 end
    return clamp(old+clamp(target-old,-RECOVERY.demandRate*dt,RECOVERY.demandRate*dt),-limit,limit)
  end
  s.r=axis(r,rr,s.r);s.p=axis(p,rp,s.p)
  return s.r,s.p
end

local function validPosition(t)
  return type(t)=='table' and finite(t.x) and finite(t.y) and finite(t.z)
    and math.abs(t.x)<=30000000 and math.abs(t.z)<=30000000 and math.abs(t.y)<=30000000
end
local function navMetrics(target,fix,previous)
  local dx,dy,dz=target.x-fix.x,target.y-fix.y,target.z-fix.z
  local h=math.sqrt(dx*dx+dz*dz)
  local out={dx=dx,dy=dy,dz=dz,horizontal=h,distance=math.sqrt(h*h+dy*dy)}
  if previous and fix.time>previous.time then
    local dt=(fix.time-previous.time)/1000
    local vx,vy,vz=(fix.x-previous.x)/dt,(fix.y-previous.y)/dt,(fix.z-previous.z)/dt
    out.speed=math.sqrt(vx*vx+vy*vy+vz*vz);out.horizontalSpeed=math.sqrt(vx*vx+vz*vz)
    out.vx=vx;out.vy=vy;out.vz=vz;out.sampleTime=fix.time
    if out.horizontalSpeed>=NAVCFG.minCourseSpeed then
      local atan2=math.atan2 or function(y,x) return math.atan(y,x) end
      if h>0 then out.error=math.deg(atan2(vx*dz-vz*dx,vx*dx+vz*dz))end
      out.course=math.deg(atan2(vz,vx));out.courseValid=true
    end
  end
  return out
end
local function ingestGPS(s,sample,now)
  if type(sample)~='table' then return false end
  local stamp=finite(sample.sampleTime) and sample.sampleTime or sample.time
  if not finite(stamp) or stamp>now+100 or (s.sampleTime and stamp<s.sampleTime) then return false end
  local good=sample.ok==true and not sample.degraded and validPosition(sample)
    and finite(sample.time) and now-sample.time<=NAVCFG.gpsTimeout*1000 and sample.time<=now+100
  if s.sampleTime==stamp and not good then return false end
  s.sampleTime=stamp
  if good then
    if not s.fix or sample.time>s.fix.time then
      s.previous=not s.degraded and s.fix or nil
      s.fix={ok=true,x=sample.x,y=sample.y,z=sample.z,time=sample.time}
    end
    s.degraded=false;s.failures=0
  else
    s.degraded=true;s.previous=nil
    s.failures=finite(sample.failures) and sample.failures or (s.failures or 0)+1
  end
  return true
end
local function navGPSState(s,now)
  if not s.fix or now-s.fix.time>NAVCFG.gpsTimeout*1000 or now<s.fix.time-100 then return 'LOST' end
  return s.degraded and 'DEGRADED' or 'FIX'
end
local function wrapAngle(a) return (a+180)%360-180 end
local function atanDeg(z,x)
  local atan2=math.atan2 or function(y,v)return math.atan(y,v)end
  return math.deg(atan2(z,x))
end
local function sampleGPS(last,id,ok,x,y,z,time)
  if ok and validPosition({x=x,y=y,z=z}) then
    return {id=id,ok=true,x=x,y=y,z=z,time=time,sampleTime=time,degraded=false,failures=0}
  end
  last=last or {id=id,ok=false};last.degraded=true;last.sampleTime=time
  last.failures=(last.failures or 0)+1;last.error=not ok and tostring(x) or 'NO FIX'
  return last
end
local function yawPose(nodes,target,time,track,position,attitude)
  track=track or {}
  local ids={12,13}
  local q={valid=false,fixes=0,required=2,source='GPS_LR_12_13',reason='BOW GPS DEGRADED',time=time,
    offset=YAWCFG.yawOffset,bowSign=YAWCFG.bowSign,bowSignSource=YAWCFG.bowSignSource,bodyIds=ids,samples={},
    expectedDistance=YAWCFG.mountDistance,mountTolerance=YAWCFG.mountTolerance,minHorizontal=YAWCFG.minHorizontal,
    recoveryRequired=YAWCFG.recoverFixes,recoveryFixes=track.goodFrames or 0,tilt=attitude and attitude.tilt}
  local function latchInvalid(code,reason)
    q.reasonCode=code;q.reason=reason;q.recoveryFixes=0
    track.recovering=true;track.goodFrames=0;track.pose=nil;track.times=nil
    return q
  end
  local function recovering(reason)
    q.reasonCode='YAW_RECOVERING';q.reason=reason;q.recoveryFixes=track.goodFrames or 0
    track.pose=nil;track.times=nil
    return q
  end
  local function finish()
    q.valid=true;q.age=(time-q.time)/1000
    q.targetOrigin=validPosition(position) and position or q.center;q.targetSource=validPosition(position) and 'NAV GPS' or '12/13 MIDPOINT'
    if validPosition(target)then
      local dx,dz=target.x-q.targetOrigin.x,target.z-q.targetOrigin.z
      if dx*dx+dz*dz>0.0001 then q.targetYaw=wrapAngle(atanDeg(dz,dx));q.error=wrapAngle(q.targetYaw-q.yaw)end
    end
    return q
  end
  local points={};local oldest,newest=math.huge,-math.huge
  for _,id in ipairs(ids)do
    local n=nodes[id];local g=n and n.gps
    local state='NO DATA'
    if type(g)=='table' then
      if g.error=='NO LOCAL WIRELESS GPS'then state='NO LOCAL WIRELESS GPS'
      elseif not n.ok then state='NODE FAULT'
      elseif not finite(n.time) or time-n.time>CFG.nodeTimeout*1000 or time-n.time< -100 then state='NODE STALE'
      elseif g.ok~=true then state='NO FIX'
      elseif not finite(g.time) or time-g.time>YAWCFG.maxAge*1000 or time-g.time< -100 then state='STALE'
      elseif g.degraded or g.ok~=true then state=g.ok and 'DEGRADED' or 'NO FIX'
      elseif g.id~=id or not validPosition(g)then state='INVALID FIX'
      else state='FIX';points[id]=g;q.fixes=q.fixes+1;oldest=math.min(oldest,g.time);newest=math.max(newest,g.time)end
    end
    q.samples[id]={state=state,x=g and g.x,y=g and g.y,z=g and g.z,time=g and g.time,sampleTime=g and g.sampleTime,error=g and g.error}
  end
  if q.fixes~=2 then return latchInvalid('YAW_GPS_DEGRADED','12 '..q.samples[12].state..' / 13 '..q.samples[13].state)end
  q.oldest=oldest;q.skew=(newest-oldest)/1000
  if q.skew>YAWCFG.maxSkew then return latchInvalid('YAW_GPS_DEGRADED','12/13 GPS sample skew')end
  local left,right=points[12],points[13];q.left=left;q.right=right
  q.center={x=(left.x+right.x)/2,y=(left.y+right.y)/2,z=(left.z+right.z)/2}
  local dx,dy,dz=right.x-left.x,right.y-left.y,right.z-left.z
  q.lr={x=dx,y=dy,z=dz};q.deltaY=dy
  q.distance3d=math.sqrt(dx*dx+dy*dy+dz*dz);q.distanceError=q.distance3d-YAWCFG.mountDistance
  q.horizontalBaseline=math.sqrt(dx*dx+dz*dz);q.baseline=q.horizontalBaseline
  if math.abs(q.distanceError)>YAWCFG.mountTolerance then
    return latchInvalid('YAW_MOUNT_DISTANCE_INVALID',string.format('12/13 3D distance %.2f; expected %.2f +/- %.2f',q.distance3d,YAWCFG.mountDistance,YAWCFG.mountTolerance))
  end
  if q.horizontalBaseline<YAWCFG.minHorizontal then
    return latchInvalid('YAW_HORIZONTAL_PROJECTION_INVALID',string.format('12/13 horizontal projection %.2f below %.2f',q.horizontalBaseline,YAWCFG.minHorizontal))
  end
  if attitude and finite(attitude.tilt) and attitude.tilt>YAWCFG.maxTilt then
    return latchInvalid('YAW_ATTITUDE_UNTRUSTED',string.format('Body tilt %.1f exceeds bow-up trust %.1f',attitude.tilt,YAWCFG.maxTilt))
  end
  if YAWCFG.bowSign~=1 and YAWCFG.bowSign~=-1 then return latchInvalid('BOW_CONFIG_INVALID','fleet.bow_sign must be +1 or -1 when explicitly set')end
  if not finite(YAWCFG.yawOffset)then return latchInvalid('BOW_CONFIG_INVALID','Invalid fleet.bow_offset')end
  local g=attitude and attitude.gravity
  if not validArray(g,3)then return latchInvalid('YAW_ATTITUDE_UNTRUSTED','Body-up gravity vector unavailable')end
  local gl=math.sqrt(g[1]^2+g[2]^2+g[3]^2)
  if gl<0.001 then return latchInvalid('YAW_ATTITUDE_UNTRUSTED','Body-up gravity vector invalid')end
  local wf,wu,wr=-g[1]/gl,-g[2]/gl,-g[3]/gl
  local rx,ry,rz=dx/q.distance3d,dy/q.distance3d,dz/q.distance3d
  local px,py,pz=-ry*rx,1-ry*ry,-ry*rz
  local pl=math.sqrt(px*px+py*py+pz*pz)
  local localPlane=math.sqrt(wf*wf+wu*wu)
  if pl<0.05 or localPlane<0.05 then return latchInvalid('YAW_ATTITUDE_UNTRUSTED','Body-up/right geometry cannot resolve bow')end
  px,py,pz=px/pl,py/pl,pz/pl
  local qx,qy,qz=py*rz-pz*ry,pz*rx-px*rz,px*ry-py*rx
  local a,b=wf/localPlane,wu/localPlane
  local fx,fy,fz=a*px+b*qx,a*py+b*qy,a*pz+b*qz
  local ux,uy,uz=b*px-a*qx,b*py-a*qy,b*pz-a*qz
  q.right={x=rx,y=ry,z=rz};q.forward={x=fx,y=fy,z=fz};q.bodyUp={x=ux,y=uy,z=uz}
  q.gravityLocalUp={forward=wf,up=wu,right=wr};q.rightVertical=ry;q.gravityRightError=wr-ry
  local fh=math.sqrt(fx*fx+fz*fz)
  if fh<0.05 then return latchInvalid('YAW_ATTITUDE_UNTRUSTED','Bow horizontal projection too short')end
  q.rawYaw=wrapAngle(atanDeg(fz,fx))
  local pairNew=not track.candidateTimes
  if track.candidateTimes then pairNew=left.time>track.candidateTimes[12] and right.time>track.candidateTimes[13] end
  if pairNew then track.candidateTimes={[12]=left.time,[13]=right.time} end
  if track.recovering~=false then
    if pairNew then track.goodFrames=(track.goodFrames or 0)+1 end
    q.recoveryFixes=track.goodFrames or 0
    if q.recoveryFixes<YAWCFG.recoverFixes then
      return recovering(string.format('BOW HOLD: fresh geometry %d/%d',q.recoveryFixes,YAWCFG.recoverFixes))
    end
    track.recovering=false;track.goodFrames=YAWCFG.recoverFixes
  end
  local allNew=not track.times
  if track.times then allNew=left.time>track.times[12] and right.time>track.times[13] end
  local pose=track.pose
  if not allNew then
    if not pose or time-pose.oldest>YAWCFG.maxAge*1000 then return latchInvalid('YAW_GPS_DEGRADED','Waiting for complete new 12/13 frame')end
    for k,v in pairs(pose)do q[k]=v end;q.pending=true;return finish()
  end
  q.yaw=wrapAngle(q.rawYaw+(YAWCFG.bowSign==-1 and 180 or 0)+YAWCFG.yawOffset)
  q.time=(left.time+right.time)/2;q.rate=0;q.rateValid=false
  if pose then
    local dt=(q.time-pose.time)/1000
    if dt>0.05 and dt<=YAWCFG.maxAge then
      local rate=wrapAngle(q.yaw-pose.yaw)/dt
      if math.abs(rate)>YAWCFG.maxRate then return latchInvalid('YAW_GPS_DEGRADED','BOW GPS sample jump / rate invalid')end
      q.rate=pose.rateValid and pose.rate+(rate-pose.rate)*dt/(YAWCFG.rateFilter+dt) or rate;q.rateValid=true
    end
  end
  track.times={[12]=left.time,[13]=right.time}
  q.reason='BOW from 12 LEFT -> 13 RIGHT + body-up; '..(YAWCFG.bowSignSource or 'DEFAULT')
  track.pose={};for k,v in pairs(q)do track.pose[k]=v end
  return finish()
end
local function directionDiagnostics(nav,rotation,time,track)
  track=track or {};local y=nav.yaw or {};local m=nav.actual or {};local warnings={}
  local course=nav.gps=='FIX' and m.courseValid and finite(m.course) and finite(m.sampleTime) and time-m.sampleTime<=2000 and (m.horizontalSpeed or 0)>=1
  local gap=course and y.valid and wrapAngle(m.course-y.yaw) or nil
  local opposite=finite(gap) and math.abs(gap)>=150
  local mean=rotation.enabled and ((rotation.appliedLeft or rotation.left or 0)+(rotation.appliedRight or rotation.right or 0))/2 or 0
  local reverse=opposite and mean>=3
  if opposite then warnings[#warnings+1]='BOW_COURSE_OPPOSITE'end
  if reverse then warnings[#warnings+1]='FORWARD_COMMAND_REVERSE_MOTION'end
  if m.sampleTime and m.sampleTime~=track.motionTime then
    track.motionTime=m.sampleTime
    if reverse then track.reverseSince=track.reverseSince or time;track.reverseFixes=(track.reverseFixes or 0)+1
    else track.reverseSince=nil;track.reverseFixes=0 end
  end
  if not reverse then track.reverseSince=nil;track.reverseFixes=0 end
  if reverse and track.reverseSince and time-track.reverseSince>=3000 and track.reverseFixes>=3 then warnings[#warnings+1]='VECTOR_DIRECTION_SUSPECT'end
  local turn=rotation.enabled and math.abs((rotation.left or 0)-(rotation.right or 0))>=6 and y.valid and finite(y.error)
  if turn and y.time~=track.yawTime then
    track.yawTime=y.time;local e=math.abs(y.error)
    if not track.turnSince or e<(track.lastError or e)-0.5 then track.turnSince=time;track.startError=e end
    track.lastError=e
    track.growing=time-track.turnSince>=2000 and e-(track.startError or e)>=5
  elseif not turn then track.turnSince=nil;track.startError=nil;track.lastError=nil;track.growing=false end
  if track.growing then warnings[#warnings+1]='YAW_ERROR_GROWING'end
  if y.reasonCode=='YAW_BASELINE_INVALID'then warnings[#warnings+1]='YAW_BASELINE_INVALID'
  elseif y.reasonCode=='YAW_MOUNT_DISTANCE_INVALID'then warnings[#warnings+1]='YAW_MOUNT_DISTANCE_INVALID'
  elseif y.reasonCode=='YAW_HORIZONTAL_PROJECTION_INVALID'then warnings[#warnings+1]='YAW_HORIZONTAL_PROJECTION_INVALID'
  elseif y.reasonCode=='YAW_ATTITUDE_UNTRUSTED'then warnings[#warnings+1]='YAW_ATTITUDE_UNTRUSTED'
  elseif y.reasonCode=='YAW_RECOVERING'then warnings[#warnings+1]='YAW_RECOVERING'
  elseif y.reasonCode=='YAW_GPS_DEGRADED'then warnings[#warnings+1]='YAW_GPS_DEGRADED'
  elseif y.reasonCode=='BOW_CONFIG_INVALID'then warnings[#warnings+1]='BOW_CONFIG_INVALID'
  elseif y.reasonCode=='BOW_UNVERIFIED'then warnings[#warnings+1]='BOW_UNVERIFIED'end
  return {warnings=warnings,bowCourseError=gap,course=course and m.course or nil,bow=y.valid and y.yaw or nil,
    target=y.targetYaw,forwardVector=mean,reverseFixes=track.reverseFixes or 0,reason=y.reason,time=time}
end
local function velocityValues(packet,time)
  local out={source='GPS',time=time}
  for _,role in ipairs({'lateral','forward','vertical'}) do
    local r=type(packet)=='table' and packet[role]
    if type(r)=='table' and r.ok==true and finite(r.value) and math.abs(r.value)<10000
      and finite(r.time) and time-r.time>=-100 and time-r.time<=VELCFG.maxAge*1000 then
      out[role]=r.value;out[role..'Time']=r.time;out[role..'Axis']=r.axis;out.source='SENSOR'
    end
  end
  return out
end
local function applyVelocity(m,values,pose)
  m.gpsVy=m.vy;m.gpsSpeed=m.horizontalSpeed
  if finite(values.forward) then m.forward=values.forward;m.forwardSource='SENSOR_2';m.forwardTime=values.forwardTime end
  if finite(values.lateral) then m.lateral=values.lateral end
  if finite(values.vertical) then m.vy=values.vertical;m.verticalSource='SENSOR_3' end
  if finite(m.forward) and finite(m.lateral) then m.horizontalSpeed=math.sqrt(m.forward^2+m.lateral^2) end
  if not finite(m.forward) and pose and pose.valid and finite(m.vx) then
    m.forward=m.vx*math.cos(math.rad(pose.yaw))+m.vz*math.sin(math.rad(pose.yaw))
  end
  return m
end
local function speedGuard(left,right,v)
  if not finite(v) then return left,right,nil end
  if v>=VELCFG.forwardLimit-VELCFG.limitMargin then return -NAVCFG.brakeVector,-NAVCFG.brakeVector,'FORWARD LIMIT / BRAKE' end
  if v<=-VELCFG.reverseLimit+VELCFG.limitMargin then return NAVCFG.brakeVector,NAVCFG.brakeVector,'REVERSE LIMIT / BRAKE' end
  return left,right,nil
end
local function resetCruise(nav)
  nav.directionLock=false;nav.directionLockSince=nil;nav.motionEstablished=false
  nav.targetForward=0;nav.cruiseIntegral=0;nav.cruiseDemand=0;nav.cruiseVector=0;nav.cruiseInitialized=false
  nav.brakeSample=nil;nav.slipFactor=1;nav.slipSevere=false;nav.accelerationAllowed=nil
end
local function directionLock(nav,pose,stable)
  local good=pose and pose.valid and pose.rateValid and finite(pose.error) and finite(pose.rate) and stable==true
  if not good then nav.directionLock=false;nav.directionLockSince=nil;return false end
  local limit=nav.directionLock and CRUISECFG.lockExit or CRUISECFG.lockError
  if math.abs(pose.error)>limit or math.abs(pose.rate)>CRUISECFG.lockRate then
    nav.directionLock=false;nav.directionLockSince=nil;return false
  end
  nav.directionLockSince=nav.directionLockSince or pose.time
  if pose.time-nav.directionLockSince>=CRUISECFG.lockSeconds*1000 then
    nav.directionLock=true;nav.motionEstablished=true
  end
  return nav.directionLock==true
end
local function brakingModel(nav,m)
  local stamp=m.forwardTime or m.sampleTime
  local old=nav.brakeSample
  if finite(stamp) and finite(m.forward) then
    if old and stamp>old.time then
      local dt=(stamp-old.time)/1000
      if dt>=0.05 and dt<=0.6 and old.angle<0 and old.v>1 and m.forward>=0
        and nav.attitudeStable==true and nav.yaw and nav.yaw.valid and nav.yaw.rateValid
        and math.abs(nav.yaw.rate)<=CRUISECFG.lockRate and math.abs(m.lateral or math.huge)<=CRUISECFG.slipNormal then
        local decel=(old.v-m.forward)/dt
        if finite(decel) and decel>0 and decel<=10 then
          nav.brakeSamples=nav.brakeSamples or {};local samples=nav.brakeSamples
          samples[#samples+1]=decel
          while #samples>CRUISECFG.brakeWindow do table.remove(samples,1) end
          if #samples>=CRUISECFG.brakeSamples then
            local sorted={};for i,v in ipairs(samples) do sorted[i]=v end;table.sort(sorted)
            nav.measuredDeceleration=clamp(sorted[math.max(1,math.floor(#sorted*0.2))]*0.8,CRUISECFG.minimumDeceleration,5)
          end
        elseif decel<=0 then
          nav.measuredDeceleration=math.max(CRUISECFG.minimumDeceleration,(nav.measuredDeceleration or VELCFG.deceleration)*0.9)
          nav.brakeConfidence='WEAK BRAKING'
        end
      end
    end
    if not old or stamp>old.time then nav.brakeSample={time=stamp,v=m.forward,angle=nav.cruiseVector or 0} end
  end
  local a=nav.measuredDeceleration or VELCFG.deceleration
  nav.brakeConfidence=nav.brakeConfidence=='WEAK BRAKING' and nav.brakeConfidence or nav.measuredDeceleration and 'MEASURED' or 'CONFIG / UNVERIFIED'
  return math.max(CRUISECFG.minimumDeceleration,a)
end
local function cruiseCommand(nav,m,dt)
  dt=clamp(dt or 0,0,0.2)
  local v=m.forward
  if not finite(v) then
    local slowing=m.horizontal<NAVCFG.arrivalRadius*3 or (m.speed or 0)>NAVCFG.maxSpeed
    local out=slowing and ((m.speed or 0)>NAVCFG.arrivalSpeed and -NAVCFG.brakeVector or 0) or NAVCFG.maxVector
    return out,out
  end
  if nav.cruiseInitialized==false then nav.targetForward=clamp(v,0,VELCFG.forwardLimit) end
  nav.cruiseInitialized=true
  local decel=brakingModel(nav,m)
  local gap=math.max(0,m.horizontal-NAVCFG.arrivalRadius)
  local margin=math.min(CRUISECFG.brakeMargin,gap*0.25)
  local reaction=CRUISECFG.reactionSeconds
  local ceiling=math.max(0,math.sqrt((decel*reaction)^2+2*decel*math.max(0,gap-margin))-decel*reaction)
  local forward=math.max(0,v)
  nav.brakingDistance=forward^2/(2*decel)+forward*reaction+NAVCFG.arrivalRadius+margin
  nav.deceleration=decel;nav.brakingSpeed=math.min(VELCFG.forwardLimit,ceiling)
  local fast=nav.directionLock==true and nav.commandMode~='HOVER' and m.forwardSource=='SENSOR_2' and finite(m.lateral)
  local goal=math.max(0,VELCFG.cruiseSpeed)
  if fast then
    for _,band in ipairs(CRUISECFG.distanceBands) do if m.horizontal>band[1] then goal=band[2];break end end
  end
  local permit=nav.accelerationAllowed~=false and not nav.altitudeLimited
  local lateral=math.abs(m.lateral or 0)
  local old=nav.targetForward or math.max(0,math.min(v,VELCFG.cruiseSpeed))
  if nav.motionEstablished and not permit and lateral<CRUISECFG.slipSevere and not nav.slipSevere then old=math.max(0,v);goal=math.max(goal,old) end
  goal=math.min(goal,VELCFG.forwardLimit,ceiling)
  if lateral<=CRUISECFG.slipNormal then nav.slipSevere=false
  elseif lateral>=CRUISECFG.slipSevere then nav.slipSevere=true
  elseif lateral<=CRUISECFG.slipRelease then nav.slipSevere=false end
  local factor=clamp((CRUISECFG.slipSevere-lateral)/(CRUISECFG.slipSevere-CRUISECFG.slipNormal),0,1)
  nav.slipFactor=(nav.slipFactor or 1)+(factor-(nav.slipFactor or 1))*dt/(CRUISECFG.slipFilter+dt)
  if lateral<=CRUISECFG.slipNormal then nav.slipFactor=1 end
  nav.lateralState=lateral<=CRUISECFG.slipNormal and 'NORMAL' or nav.slipSevere and 'GRADUAL SLOW' or 'ACCEL LIMIT'
  nav.lateralHold=lateral>CRUISECFG.slipNormal
  if nav.slipSevere then goal=math.min(goal,math.max(0,old-CRUISECFG.slipDeceleration*dt)) end
  local distanceBrake=v>ceiling+CRUISECFG.speedDeadband
  local accel=(fast and CRUISECFG.acceleration or VELCFG.acceleration)*nav.slipFactor
  if not permit or nav.slipSevere then accel=0 end
  local fall=nav.slipSevere and CRUISECFG.slipDeceleration or decel
  nav.targetForward=old+clamp(goal-old,-fall*dt,accel*dt)
  if distanceBrake then nav.targetForward=math.min(nav.targetForward,ceiling) end
  nav.targetForward=clamp(nav.targetForward,0,VELCFG.forwardLimit)
  nav.distanceTarget=goal;nav.accelerationLimited=not permit or lateral>CRUISECFG.slipNormal
  local error=nav.targetForward-v
  local effective=math.abs(error)<=CRUISECFG.speedDeadband and 0 or error
  local integral=nav.cruiseIntegral or 0
  if not ((nav.cruiseDemand or 0)>=NAVCFG.maxVector and effective>0)
    and not ((nav.cruiseDemand or 0)<=-NAVCFG.maxVector and effective<0) then
    integral=clamp(integral+effective*CRUISECFG.integralGain*dt,-CRUISECFG.maxIntegral,CRUISECFG.maxIntegral)
  end
  nav.cruiseIntegral=integral
  local braking=distanceBrake or error< -CRUISECFG.reverseError or (gap==0 and nav.targetForward<=NAVCFG.arrivalSpeed)
  local demand=clamp(CRUISECFG.holdVector+effective*VELCFG.speedGain+integral,-NAVCFG.maxVector,NAVCFG.maxVector)
  if demand>CRUISECFG.holdVector and lateral>CRUISECFG.slipNormal then
    demand=CRUISECFG.holdVector+(demand-CRUISECFG.holdVector)*nav.slipFactor
  end
  if not permit and nav.motionEstablished then demand=math.min(demand,CRUISECFG.holdVector) end
  if braking and v>NAVCFG.arrivalSpeed then demand=math.min(demand,-NAVCFG.brakeVector) end
  if not braking and nav.targetForward>0.05 then demand=math.max(demand,CRUISECFG.holdVector) end
  if gap==0 and nav.targetForward<=NAVCFG.arrivalSpeed and math.abs(v)<=NAVCFG.arrivalSpeed then demand=0 end
  local internal=nav.cruiseDemand or 0
  internal=internal+clamp(demand-internal,-CRUISECFG.vectorFall*dt,CRUISECFG.vectorRise*dt)
  nav.cruiseDemand=internal
  local q=nav.cruiseVector or 0;local h=CRUISECFG.quantHysteresis
  while internal>q+3+h and q<NAVCFG.maxVector do q=q+6 end
  while internal<q-3-h and q> -NAVCFG.maxVector do q=q-6 end
  if not braking and nav.targetForward>0.05 and q>=0 and internal>=0 then q=math.max(q,CRUISECFG.holdVector) end
  nav.cruiseVector=q
  nav.velocityState=distanceBrake and 'DISTANCE BRAKE' or nav.slipSevere and 'SLIP SLOW' or not permit and 'YAW ACCEL HOLD' or braking and 'BRAKE' or nav.directionLock and 'DIRECTION LOCK' or 'LOW SPEED'
  return speedGuard(q,q,v)
end
local function landingStage(stage)
  return stage=='FINAL' or stage=='DESCENT' or stage=='LANDING' or stage=='FLARE'
    or stage=='LAND_HOLD' or stage=='ARRIVED'
end
local function pauseLanding(nav,reason,fix)
  resetCruise(nav)
  nav.landing=true;nav.landingPaused=true;nav.landResumeSince=nil;nav.holdStart=nil
  nav.landingHoldY=nav.landingHoldY or (fix and fix.y) or nav.altitudeTarget
  nav.targetVy=0;nav.turnBoost=0;nav.stage='LAND_HOLD';nav.state='NAV HOLD';nav.reason=reason
  nav.landingPauseReason=reason
  nav.main=math.max(nav.main or 0,math.min(NAVCFG.maxMain,NAVCFG.hoverMain))
end
local function landingProfile(height)
  if height>LANDCFG.far then return -LANDCFG.fast,'DESCENT' end
  if height>LANDCFG.middle then return -LANDCFG.medium,'LANDING' end
  if height>LANDCFG.near then return -LANDCFG.slow,'FLARE' end
  if height>LANDCFG.tolerance then return -LANDCFG.creep,'FLARE' end
  if height< -LANDCFG.tolerance then return math.min(LANDCFG.maxAscent,-height*LANDCFG.positionGain),'FINAL' end
  return 0,'LAND_HOLD'
end
local function landingStep(nav,fix,m,level,dt)
  nav.landing=true;nav.turnBoost=0;nav.probe=nil
  local time=(level.now or fix.time)/1000;local goal=nav.target.y+LANDCFG.yOffset
  local stable=not level.recovery and level.tilt<=NAVCFG.stableTilt and level.rate<=NAVCFG.stableRate
  local position=m.horizontal<=NAVCFG.arrivalRadius*LANDCFG.exitRadius and (m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed
  if not stable or not position or not finite(m.vy) then
    pauseLanding(nav,not position and 'Landing HOLD: horizontal drift' or not stable and 'Landing HOLD: attitude priority' or 'Landing HOLD: velocity FIX required',fix)
  end
  local paused=nav.landingPaused
  if paused then
    local canResume=stable and position and finite(m.vy) and math.abs(m.vy)<=NAVCFG.stableVertical
      and (m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed
    if canResume then
      nav.landResumeSince=nav.landResumeSince or time
      if time-nav.landResumeSince>=LANDCFG.resumeSeconds then
        nav.landingPaused=false;nav.landResumeSince=nil;nav.landingHoldY=nil;paused=false
      end
    else nav.landResumeSince=nil end
  end
  local height=fix.y-goal;local targetVy,stage=landingProfile(height)
  local vy=m.vy
  local braking=false
  if paused then
    targetVy=clamp(((nav.landingHoldY or fix.y)-fix.y)*LANDCFG.positionGain,0,LANDCFG.maxAscent)
    stage='LAND_HOLD';nav.reason=nav.landingPauseReason or 'Landing HOLD: stabilize to resume'
  elseif finite(vy) and vy<0 and (height+vy*LANDCFG.prediction<=LANDCFG.tolerance or vy<targetVy-LANDCFG.excessSpeed) then
    targetVy=0;stage='FLARE';braking=true;nav.reason='FLARE: damp excess descent before height error'
  else nav.reason='Target Y reference; no ground contact sensor' end
  nav.targetVy=targetVy;nav.verticalSpeed=vy;nav.landingHeight=height;nav.altitudeTarget=paused and nav.landingHoldY or goal
  nav.landingPhase=stage;nav.stage=stage;nav.landingBraking=braking
  if finite(vy) then
    local wanted=clamp(NAVCFG.hoverMain+LANDCFG.velocityGain*(targetVy-vy),0,NAVCFG.maxMain)
    local rise=(braking or paused or vy<targetVy-LANDCFG.excessSpeed) and LANDCFG.brakeRise or NAVCFG.mainRate
    nav.main=nav.main+clamp(wanted-nav.main,-NAVCFG.mainRate*dt,rise*dt)
  end
  local near=not paused and stable and m.horizontal<=NAVCFG.arrivalRadius and math.abs(height)<=LANDCFG.tolerance
    and finite(vy) and math.abs(vy)<=LANDCFG.holdSpeed and (m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed
  if near then
    nav.holdStart=nav.holdStart or time;nav.stage='LAND_HOLD'
    if time-nav.holdStart>=NAVCFG.arrivalHold then nav.stage='ARRIVED';nav.reason='ARRIVED: altitude HOLD; confirm landing manually' end
  else nav.holdStart=nil end
  nav.state=nav.stage=='ARRIVED' and 'NAV ARRIVED' or nav.stage=='LAND_HOLD' and 'NAV HOLD' or 'NAV '..nav.stage
  return 0,0
end
local function yawCommand(nav,pose,dt,time)
  nav.mode='YAW';nav.yaw=pose;nav.probe=nil;nav.turnBoost=nav.turnBoost or 0
  local delta=nav.turnStamp and clamp((time-nav.turnStamp)/1000,0,0.2) or math.min(dt,0.2)
  nav.turnStamp=time
  if not pose or not pose.valid or not finite(pose.error) then
    resetCruise(nav);nav.turnAngle=0;nav.turnBoost=0;nav.yawAligned=false;nav.turnDirection='NONE';return 0,0
  end
  directionLock(nav,pose,nav.attitudeStable)
  local e=pose.error;local m=nav.metrics or {}
  nav.slipCorrection=0
  if math.abs(e)<YAWCFG.fineBand and finite(m.forward) and m.forward>YAWCFG.slipSpeed and finite(m.lateral) and math.abs(m.lateral)>VELCFG.slipThreshold then
    nav.slipCorrection=clamp(-atanDeg((math.abs(m.lateral)-VELCFG.slipThreshold)*(m.lateral>=0 and 1 or -1),m.forward),-VELCFG.maxCrab,VELCFG.maxCrab)
    e=wrapAngle(e+nav.slipCorrection)
  end
  nav.controlYawError=e
  nav.accelerationAllowed=nav.directionLock==true and math.abs(e)<=CRUISECFG.lockError
    and math.abs(pose.rate or 0)<=CRUISECFG.lockRate
  local rate=pose.rateValid and pose.rate or 0
  local a=math.abs(e);local closing=(e>=0 and 1 or -1)*rate
  local aligned=a<=(nav.yawAligned and YAWCFG.exitError or YAWCFG.alignError)
    and pose.rateValid and math.abs(rate)<=YAWCFG.settleRate
  if aligned then
    nav.yawAlignSince=nav.yawAlignSince or pose.time
    nav.yawAligned=nav.yawAligned or (pose.time-nav.yawAlignSince>=YAWCFG.alignSeconds*1000)
  else nav.yawAlignSince=nil;nav.yawAligned=false end
  local angle,boost=0,0
  if not aligned and a>YAWCFG.alignError then
    local strength=clamp((a-YAWCFG.alignError)/(90-YAWCFG.alignError),0,1)
    angle=6+(YAWCFG.maxVector-6)*strength;boost=YAWCFG.maxBoost*(0.25+0.75*strength)
    local remaining=a-math.max(0,closing)*(YAWCFG.prediction+clamp(pose.age or 0,0,YAWCFG.maxAge))
    local damping=clamp((remaining-YAWCFG.alignError)/math.max(1e-9,a-YAWCFG.alignError),0,1)
    if a<YAWCFG.fineBand and math.abs(rate)>YAWCFG.settleRate then damping=0 end
    angle=angle*damping;boost=boost*damping
    if not pose.rateValid then angle=math.min(angle,6);boost=0 end
  end
  angle=math.min(angle,YAWCFG.maxVector)
  local signed=(e>=0 and 1 or -1)*NAVCFG.yawSign*angle
  local old=nav.turnAngle or 0
  if old*signed<0 then signed=0;nav.turnAngle=0;nav.turnBoost=0
  elseif angle==0 then nav.turnAngle=0
  else nav.turnAngle=old+clamp(signed-old,-YAWCFG.vectorRate*delta,YAWCFG.vectorRate*delta) end
  local applied=(nav.turnAngle>=0 and 1 or -1)*math.floor(math.abs(nav.turnAngle)/6+0.5)*6
  if applied==0 then boost=0 end
  local maxBoost=math.max(0,math.min(YAWCFG.maxBoost,NAVCFG.maxMain-nav.main))
  boost=math.min(boost,maxBoost)
  if boost==0 then nav.turnBoost=0
  else nav.turnBoost=nav.turnBoost+clamp(boost-nav.turnBoost,-YAWCFG.boostFall*delta,YAWCFG.boostRise*delta) end
  nav.turnDirection=applied>0 and (NAVCFG.yawSign==1 and 'RIGHT' or 'LEFT')
    or applied<0 and (NAVCFG.yawSign==1 and 'LEFT' or 'RIGHT') or 'DAMP/HOLD'
  if nav.yawAligned then
    nav.turnBoost=0;nav.turnAngle=0;nav.turnDirection='ALIGNED';nav.stage='CRUISE';nav.state='NAV CRUISE'
    nav.reason='Body baseline bow aligned; GPS course monitors motion'
    local m=nav.metrics or {}
    local slip=finite(m.course) and wrapAngle(m.course-pose.yaw) or nil
    nav.slip=slip
    if slip and math.abs(slip)>YAWCFG.slipDegrees and (m.horizontalSpeed or 0)>YAWCFG.slipSpeed then
      nav.accelerationAllowed=false;nav.reason='Course/bow slip: additional acceleration held'
      return cruiseCommand(nav,m,delta)
    end
    if nav.manualCommon~=nil then return nav.manualCommon,nav.manualCommon end
    return cruiseCommand(nav,m,delta)
  end
  if nav.manualCommon~=nil then return clamp(nav.manualCommon+applied,-90,90),clamp(nav.manualCommon-applied,-90,90) end
  nav.stage='YAW_TURN';nav.state='NAV TURN';nav.reason='Closed-loop bow YAW / rate damping'
  if nav.motionEstablished and (m.forward or 0)>0.1 then
    nav.accelerationAllowed=false
    local common=cruiseCommand(nav,m,delta)
    return clamp(common+applied,-90,90),clamp(common-applied,-90,90)
  end
  return applied,-applied
end

local function navHold(nav,reason)
  resetCruise(nav)
  nav.stage='HOLD';nav.state='NAV HOLD';nav.reason=reason;nav.holdReason=reason
  nav.holdSince=nil;nav.holdProgress=0;nav.probe=nil;nav.stableSince=nil
  nav.course=nil;nav.courseTime=nil;nav.courseError=nil;nav.courseTrusted=false
  nav.retryPending=true;nav.rechecking=true;nav.targetForward=0;nav.turnBoost=0;nav.turnAngle=0;nav.yawAligned=false;nav.yawAlignSince=nil
end
local function suspendGPS(nav)
  resetCruise(nav)
  if not nav.gpsPaused then
    if landingStage(nav.stage) or nav.landing then pauseLanding(nav,'Landing HOLD: GPS DEGRADED',nav.fix) end
    if nav.probe then nav.probeCount=math.max(0,(nav.probeCount or 0)-1) end
    nav.probe=nil;nav.course=nil;nav.courseTime=nil;nav.courseError=nil;nav.courseTrusted=false
    nav.stableSince=nil;nav.holdStart=nil;nav.holdSince=nil;nav.holdProgress=0;nav.rechecking=true
    if nav.probeInfo then nav.probeInfo.result='GPS PAUSED' end
    if nav.stage~='ALTITUDE' and nav.stage~='STABILIZE' and not landingStage(nav.stage) then
      navHold(nav,'GPS recovered: stabilize before course search')
    end
  end
  nav.turnBoost=0;nav.turnAngle=0;nav.yawAligned=false;nav.yawAlignSince=nil
  nav.gpsPaused=true;nav.state='GPS DEGRADED';nav.reason='Horizontal hold; last good altitude command retained'
end
local function verticalHold(nav,fix,m,goal,dt)
  nav.altitudeTarget=goal;nav.verticalSpeed=m.vy
  if not finite(m.vy) then nav.reason='Vertical velocity unavailable; altitude command held';return end
  local error=goal-fix.y
  if math.abs(error)<5 and nav.attitudeStable then nav.hoverTrim=clamp((nav.hoverTrim or 0)+error*MODECFG.hoverTrimGain*dt,-MODECFG.hoverTrimLimit,MODECFG.hoverTrimLimit) end
  local desiredVy=clamp(error*MODECFG.positionGain,-1,1)
  local wanted=clamp(NAVCFG.hoverMain+(nav.hoverTrim or 0)+MODECFG.verticalGain*(desiredVy-m.vy),0,NAVCFG.maxMain)
  nav.targetVy=desiredVy
  nav.main=nav.main+clamp(wanted-nav.main,-NAVCFG.mainRate*dt,(m.vy< -0.5 and LANDCFG.brakeRise or 0.5)*dt)
end
local function driveVector(nav,m,speed,permit,dt)
  local v=m.forward
  if not finite(v) then nav.reason='Forward velocity unavailable; HOLD';return 0 end
  local goal=clamp(speed,-VELCFG.reverseLimit,VELCFG.forwardLimit)
  local old=nav.driveTarget or v
  if not permit and math.abs(goal)>math.abs(v) then goal=v end
  nav.driveTarget=old+clamp(goal-old,-CRUISECFG.acceleration*dt,CRUISECFG.acceleration*dt)
  local error=nav.driveTarget-v
  local active=math.abs(nav.driveTarget)>NAVCFG.arrivalSpeed
  local sign=nav.driveTarget>=0 and 1 or -1
  local demand=clamp(error*VELCFG.speedGain+(active and sign*CRUISECFG.holdVector or 0),-NAVCFG.maxVector,NAVCFG.maxVector)
  if math.abs(error)<CRUISECFG.speedDeadband and active then demand=sign*CRUISECFG.holdVector end
  if math.abs(speed)<0.01 and math.abs(v)>NAVCFG.arrivalSpeed then demand=v>0 and -NAVCFG.brakeVector or NAVCFG.brakeVector end
  local lateral=math.abs(m.lateral or 0)
  if lateral>CRUISECFG.slipNormal and demand*v>=0 then
    local factor=clamp((CRUISECFG.slipSevere-lateral)/2,0,1)
    demand=demand*factor+(v>=0 and 1 or -1)*CRUISECFG.holdVector*(1-factor)
    if lateral>=4 then nav.driveTarget=old+clamp(-v-old,-CRUISECFG.slipDeceleration*dt,CRUISECFG.slipDeceleration*dt) end
  end
  local internal=nav.driveDemand or 0
  internal=internal+clamp(demand-internal,-CRUISECFG.vectorFall*dt,CRUISECFG.vectorRise*dt);nav.driveDemand=internal
  local q=nav.driveVector or 0
  while internal>q+4 and q<NAVCFG.maxVector do q=q+6 end
  while internal<q-4 and q> -NAVCFG.maxVector do q=q-6 end
  nav.driveVector=q
  return speedGuard(q,q,v)
end
local function manualStep(nav,fix,m,level,dt)
  nav.metrics=m;nav.fix=fix;nav.state='MANUAL DRIVE';nav.stage='MANUAL'
  verticalHold(nav,fix,m,nav.holdY or fix.y,dt)
  local pose=level.yaw
  if not pose or not pose.valid then nav.reason='YAW DEGRADED: manual motion HOLD';nav.manualCommon=0;return 0,0 end
  local p={};for k,v in pairs(pose)do p[k]=v end
  p.targetYaw=nav.heading;p.error=wrapAngle(nav.heading-p.yaw)
  local permit=nav.attitudeStable and math.abs(p.error)<=CRUISECFG.lockError and p.rateValid and math.abs(p.rate)<=CRUISECFG.lockRate
  nav.manualCommon=driveVector(nav,m,nav.requestedSpeed or 0,permit,dt)
  nav.reason='Absolute heading + signed velocity; attitude has priority'
  local l,r=yawCommand(nav,p,dt,level.now or fix.time)
  nav.state='MANUAL DRIVE';nav.stage='MANUAL';return l,r
end
local function hoverStep(nav,fix,m,level,dt)
  nav.stage='HOVER';nav.state='HOVER BRAKE';nav.turnBoost=0
  local slow=(m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed
  if not nav.hoverBraked then
    verticalHold(nav,fix,m,nav.holdY or fix.y,dt)
    if slow then nav.hoverBraked=true;nav.driveTarget=nil;nav.driveDemand=0;nav.driveVector=0
    else
      nav.reason='HOVER requested: brake before X/Z/Y hold'
      local common=driveVector(nav,m,0,true,dt)
      if math.abs(m.lateral or 0)>math.max(NAVCFG.arrivalSpeed,math.abs(m.forward or 0)) and not (level.yaw and level.yaw.valid) then nav.reason='YAW DEGRADED: lateral brake alignment unavailable' end
      if math.abs(m.lateral or 0)>math.max(NAVCFG.arrivalSpeed,math.abs(m.forward or 0)) and level.yaw and level.yaw.valid then
        local p={};for k,v in pairs(level.yaw)do p[k]=v end
        p.targetYaw=wrapAngle(p.yaw+atanDeg(m.lateral,m.forward or 0));p.error=wrapAngle(p.targetYaw-p.yaw)
        nav.manualCommon=common;local l,r=yawCommand(nav,p,dt,level.now or fix.time);nav.manualCommon=nil
        nav.state='HOVER BRAKE';nav.stage='HOVER';return l,r
      end
      return common,common
    end
  end
  verticalHold(nav,fix,m,m.horizontal>NAVCFG.arrivalRadius and (nav.holdY or fix.y) or nav.target.y,dt)
  if m.horizontal>NAVCFG.arrivalRadius then
    nav.state='HOVER POSITION';nav.reason='Return to X/Z captured when HOVER was requested'
    if level.yaw and level.yaw.valid then return yawCommand(nav,level.yaw,dt,level.now or fix.time) end
    nav.reason='HOVER position HOLD: body YAW unavailable';return 0,0
  end
  nav.state='HOVER HOLD';nav.reason='Captured X/Z and requested Y; no ground-contact assumption'
  if not slow then local common=driveVector(nav,m,0,true,dt);return common,common end
  return 0,0
end
local function finishTest(nav,reason,aborted)
  if not nav.test or nav.test.finished then return end
  nav.test.finished=true;nav.test.aborted=aborted==true;nav.test.reason=reason
  local records=TEST_RECORDS[nav] or {}
  pendingTestLogs[#pendingTestLogs+1]={version=VERSION,summary=nav.test,records=records,configApplied=false}
end
local function testStep(nav,fix,m,level,dt)
  local t=nav.test;local time=(level.now or fix.time)/1000
  t.started=t.started or time;t.elapsed=time-t.started
  nav.testStart=nav.testStart or {x=fix.x,y=fix.y,z=fix.z}
  local start=nav.testStart
  t.displacement=math.sqrt((fix.x-start.x)^2+(fix.z-start.z)^2)
  if not t.lastPosition then t.lastPosition={x=start.x,z=start.z,time=fix.time} end
  if fix.time>t.lastPosition.time then t.pathDistance=(t.pathDistance or 0)+math.sqrt((fix.x-t.lastPosition.x)^2+(fix.z-t.lastPosition.z)^2);t.lastPosition={x=fix.x,z=fix.z,time=fix.time} end
  t.distance=t.pathDistance or 0
  t.maxSpeed=math.max(t.maxSpeed or 0,m.horizontalSpeed or 0);t.verticalSpeed=m.vy
  t.yawRate=level.yaw and level.yaw.rate
  t.maxYawRate=math.max(t.maxYawRate or 0,math.abs(t.yawRate or 0))
  if t.previousV and time>t.previousTime then t.acceleration=((m.forward or 0)-t.previousV)/(time-t.previousTime) end
  t.previousV=m.forward or 0;t.previousTime=time
  local l,r=0,0
  if t.kind=='THRUST' then
    local stage=math.min(3,1+math.floor(t.elapsed/5));l=stage*6;r=l
    nav.main=clamp(NAVCFG.hoverMain+(stage-1)*0.25,0,NAVCFG.maxMain);t.power=nav.main;t.vector=l
  elseif t.kind=='BRAKE' then
    verticalHold(nav,fix,m,nav.holdY,dt)
    l=driveVector(nav,m,0,true,dt);r=l
    if (m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed then
      t.stopTime=t.elapsed;t.stopDistance=t.distance;t.deceleration=t.elapsed>0 and t.startSpeed/t.elapsed or nil
      finishTest(nav,'Brake complete',false)
    end
  elseif t.kind=='HOVER' then
    verticalHold(nav,fix,m,nav.target.y,dt)
    t.power=nav.main;t.heightChange=fix.y-start.y
    if math.abs(m.vy or math.huge)<0.15 then t.hoverSum=(t.hoverSum or 0)+nav.main;t.hoverCount=(t.hoverCount or 0)+1;t.hoverEstimate=t.hoverSum/t.hoverCount end
  else
    nav.heading=t.heading;nav.requestedSpeed=0;l,r=manualStep(nav,fix,m,level,dt)
    local error=level.yaw and level.yaw.valid and wrapAngle(t.heading-level.yaw.yaw)
    if error then
      t.turnSign=t.turnSign or (error>=0 and 1 or -1)
      if t.turnSign*error<0 then t.overshoot=math.max(t.overshoot or 0,math.abs(error)) end
      t.lastError=error
      if math.abs(error)<5 and math.abs(t.yawRate or math.huge)<2 then t.settleSince=t.settleSince or time;if time-t.settleSince>=1 then t.turnTime=t.elapsed;finishTest(nav,'Yaw settled',false) end else t.settleSince=nil end
    end
  end
  if not t.lastSample or time-t.lastSample>=MODECFG.testSample then
    local records=TEST_RECORDS[nav] or {};TEST_RECORDS[nav]=records
    if #records<300 then records[#records+1]={time=time,x=fix.x,y=fix.y,z=fix.z,forward=m.forward,lateral=m.lateral,vertical=m.vy,forwardSource=m.forwardSource,verticalSource=m.verticalSource,yawRate=t.yawRate,main=nav.main,left=l,right=r} end
    t.samples=#records;t.lastSample=time
  end
  if math.abs(fix.y-start.y)>MODECFG.testHeightLimit then finishTest(nav,'Height deviation safety abort',true) end
  if t.elapsed>=t.duration then local incomplete=(t.kind=='BRAKE' and not t.stopTime) or (t.kind=='YAW' and not t.turnTime);finishTest(nav,incomplete and 'Timeout: stopping/settling not reached' or 'Duration complete',incomplete) end
  nav.state='TEST '..t.kind;nav.stage='TEST';nav.reason=t.finished and t.reason or 'Measured test; configuration will NOT be overwritten'
  if t.finished then nav.commandMode='HOVER';nav.target={x=fix.x,y=fix.y,z=fix.z};nav.hoverBraked=false;nav.holdY=fix.y;nav.manualCommon=nil;return 0,0 end
  return l,r
end
local function navStep(nav,fix,previous,level,dt)
  local m=applyVelocity(navMetrics(nav.target,fix,previous),level.velocity or {},level.yaw);nav.metrics=m;nav.fix=fix;nav.probeAngle=NAVCFG.probeVector
  local time=(level.now or fix.time)/1000
  nav.turnBoost=nav.turnBoost or 0
  nav.attitudeStable=not level.recovery and level.tilt<=NAVCFG.stableTilt and level.rate<=NAVCFG.stableRate
  local pose=level.yaw
  if pose and pose.valid then
    m.dx=nav.target.x-pose.center.x;m.dz=nav.target.z-pose.center.z
    m.horizontal=math.sqrt(m.dx*m.dx+m.dz*m.dz);m.distance=math.sqrt(m.horizontal*m.horizontal+m.dy*m.dy)
  end
  if level.recovery then
    resetCruise(nav)
    if nav.commandMode=='TEST' then finishTest(nav,'RECOVERY safety abort',true);nav.commandMode='HOVER';nav.target={x=fix.x,y=fix.y,z=fix.z};nav.holdY=fix.y;nav.hoverBraked=false;nav.manualCommon=nil end
    if landingStage(nav.stage) or nav.landing then pauseLanding(nav,'Landing HOLD: RECOVERY',fix) else nav.stage='ALTITUDE' end
    nav.turnBoost=0;nav.turnAngle=0;nav.yawAligned=false;nav.yawAlignSince=nil
    nav.state='RECOVERY';nav.reason='Navigation suspended for attitude recovery'
    nav.stableSince=nil;nav.course=nil;nav.courseTime=nil;nav.courseTrusted=false;nav.probe=nil;nav.holdSince=nil;nav.holdProgress=0
    if nav.probeInfo then nav.probeInfo.result='RECOVERY PAUSED' end
    return 0,0
  end
  if nav.commandMode=='TEST' and (not level.velocity or not finite(level.velocity.forward) or not finite(level.velocity.lateral) or not finite(level.velocity.vertical)) then
    finishTest(nav,'Velocity sensor data lost: test aborted',true);nav.commandMode='HOVER';nav.target={x=fix.x,y=fix.y,z=fix.z};nav.holdY=fix.y;nav.hoverBraked=false;nav.manualCommon=nil
  end
  if nav.commandMode=='MANUAL' then return manualStep(nav,fix,m,level,dt) end
  if nav.commandMode=='TEST' then return testStep(nav,fix,m,level,dt) end
  if nav.commandMode=='HOVER' then return hoverStep(nav,fix,m,level,dt) end
  local stage=nav.stage or 'ALTITUDE'
  nav.stage=stage
  if landingStage(stage) then return landingStep(nav,fix,m,level,dt) end
  local yGoal=NAVCFG.cruiseY
  nav.altitudeTarget=yGoal
  nav.altitudeLimited=fix.y<yGoal-NAVCFG.altitudeBand
  local targetVy=clamp((yGoal-fix.y)*0.1,-0.5,nav.altitudeLimited and 2 or 1)
  local desiredMain=clamp(NAVCFG.hoverMain+MODECFG.verticalGain*(targetVy-(m.vy or 0)),0,NAVCFG.maxMain)
  nav.main=nav.main+clamp(desiredMain-nav.main,-NAVCFG.mainRate*dt,(nav.altitudeLimited and 1 or NAVCFG.mainRate)*dt)
  local stable=level.tilt<=NAVCFG.stableTilt and level.rate<=NAVCFG.stableRate
  if stage~='ALTITUDE' and not landingStage(stage) and fix.y<NAVCFG.cruiseY-NAVCFG.safetyDrop then
    nav.stage='ALTITUDE';nav.stableSince=nil;nav.probe=nil;nav.course=nil;nav.courseTrusted=false;stage='ALTITUDE'
  end
  if stage=='ALTITUDE' then
    nav.state='NAV ALTITUDE';nav.reason='Acquire safe lower cruise band; upper altitude is advisory'
    if fix.y>=NAVCFG.cruiseY-NAVCFG.altitudeBand and math.abs(m.vy or math.huge)<=NAVCFG.stableVertical then
      nav.stage='STABILIZE';nav.stableSince=nil
    end
    return 0,0
  end
  if stage=='STABILIZE' then
    nav.state='NAV STABILIZE';nav.reason='Holding cruise altitude and attitude'
    if stable and fix.y>=NAVCFG.cruiseY-NAVCFG.altitudeBand then
      nav.stableSince=nav.stableSince or time
      if time-nav.stableSince>=NAVCFG.stabilizeSeconds then nav.stage='ORIENT';nav.orientSince=time end
    else nav.stableSince=nil end
    return 0,0
  end
  if stage=='HOLD' then
    nav.state='NAV HOLD';nav.reason=nav.holdReason or 'Stabilize before course search'
    local settled=stable and fix.y>=NAVCFG.cruiseY-NAVCFG.altitudeBand
      and math.abs(m.vy or math.huge)<=NAVCFG.stableVertical
      and (m.horizontalSpeed or math.huge)<=NAVCFG.probeMaxSpeed
    if settled then
      nav.holdSince=nav.holdSince or time;nav.holdProgress=time-nav.holdSince
      if nav.holdProgress>=NAVCFG.probeHoldSeconds then nav.stage='ORIENT' end
    else nav.holdSince=nil;nav.holdProgress=0 end
    return 0,0
  end
  if not stable then
    if nav.probeInfo then nav.probeInfo.result='ATTITUDE PAUSED' end
    navHold(nav,'Attitude priority: stabilize before course search');return 0,0
  end
  if pose and pose.valid then nav.yawInvalidHeld=nil
  elseif not nav.yawInvalidHeld then
    nav.yawInvalidHeld=true;nav.mode='COURSE'
    navHold(nav,'YAW INVALID: HOLD before course fallback');return 0,0
  end
  if m.courseValid and pose and pose.valid then nav.course=m.course;nav.courseTime=time;nav.courseError=m.error;nav.courseTrusted=true end
  if m.horizontal<=NAVCFG.arrivalRadius then
    nav.turnBoost=0;nav.turnAngle=0;nav.state='NAV BRAKE';nav.stage='BRAKE';nav.reason='Slow before target-Y landing approach'
    if (m.horizontalSpeed or math.huge)<=NAVCFG.arrivalSpeed then nav.stage='FINAL';nav.landing=true;nav.holdStart=nil;return 0,0 end
    if finite(m.forward) then
      local along=m.forward
      local v=math.abs(along)>NAVCFG.arrivalSpeed and (along>0 and -NAVCFG.brakeVector or NAVCFG.brakeVector) or 0
      return v,v
    end
    return nav.course and -NAVCFG.brakeVector or 0,nav.course and -NAVCFG.brakeVector or 0
  end
  if pose and pose.valid then return yawCommand(nav,pose,dt,level.now or fix.time) end
  if nav.mode=='YAW' then nav.mode='COURSE';navHold(nav,'YAW DEGRADED: HOLD before course fallback');return 0,0 end
  nav.mode='COURSE';nav.turnBoost=0;nav.turnAngle=0
  local atan2=math.atan2 or function(y,x) return math.atan(y,x) end
  local function course(dx,dz)
    local tx,tz=nav.target.x-fix.x,nav.target.z-fix.z
    nav.course=math.deg(atan2(dz,dx));nav.courseTime=time
    nav.courseError=math.deg(atan2(dx*tz-dz*tx,dx*tx+dz*tz));nav.courseTrusted=true;nav.rechecking=false
    nav.probeFailCount=0;nav.retryPending=false;nav.holdSince=nil;nav.holdProgress=0
  end
  if stage=='TURN' then
    nav.state='NAV ORIENT';nav.reason='Bounded differential yaw pulse; re-probe after turning'
    if time<(nav.turnUntil or 0) then return nav.turn, -nav.turn end
    navHold(nav,'Turn complete: stabilize and recheck course')
    return 0,0
  end
  if stage=='PROBE' then
    nav.state='NAV PROBE';nav.reason='Bounded forward course search; GPS course is not bow yaw'
    local probe=nav.probe
    if not probe then navHold(nav,'Probe interrupted: stabilize and retry');return 0,0 end
    if fix.time>(probe.lastFix or probe.time*1000) then
      probe.fixes=probe.fixes+1;probe.lastFix=fix.time
    end
    local dx,dz=fix.x-probe.x,fix.z-probe.z
    local moved=math.sqrt(dx*dx+dz*dz)
    nav.probeInfo={angle=NAVCFG.probeVector,move=moved,fixes=probe.fixes,time=fix.time,result='ACTIVE'}
    if time-probe.time>=NAVCFG.probeSeconds then
      nav.probe=nil
      if probe.fixes>=NAVCFG.probeFixes and moved>=NAVCFG.probeDistance then
        course(dx,dz);nav.probeInfo.result='EST';nav.stage='ORIENT'
      else
        nav.probeFailCount=(nav.probeFailCount or 0)+1;nav.probeInfo.result='RETRY'
        navHold(nav,probe.fixes<NAVCFG.probeFixes and 'Need more FIXES; HOLD then retry'
          or 'Need more MOVE; HOLD then retry')
      end
      return 0,0
    end
    return NAVCFG.probeVector,NAVCFG.probeVector
  end
  if stage=='CRUISE' and m.courseValid then
    nav.course=m.course;nav.courseTime=time;nav.courseError=m.error;nav.courseTrusted=true;nav.rechecking=false
    nav.probeFailCount=0;nav.retryPending=false
  end
  if nav.courseTime and time-nav.courseTime>NAVCFG.courseTimeout then nav.course=nil;nav.courseTrusted=false end
  if stage=='BRAKE' then nav.stage='ORIENT';stage='ORIENT' end
  if not nav.course then
    nav.state='NAV ORIENT';nav.reason='Course searching; bounded forward probe permitted'
    if (m.horizontalSpeed or math.huge)>NAVCFG.probeMaxSpeed then
      navHold(nav,'Course search HOLD: wait for stable, slow GPS motion');return 0,0
    end
    nav.probeCount=(nav.probeCount or 0)+1;nav.probe={x=fix.x,z=fix.z,time=time,fixes=0,lastFix=fix.time};nav.stage='PROBE'
    nav.probeInfo={angle=NAVCFG.probeVector,move=0,fixes=0,time=fix.time,result='ACTIVE'}
    nav.retryPending=false;nav.state='NAV PROBE'
    return NAVCFG.probeVector,NAVCFG.probeVector
  end
  local angle=nav.courseError or 180
  if math.abs(angle)>NAVCFG.alignDegrees then
    nav.state='NAV ORIENT';nav.stage='TURN';nav.courseTrusted=false
    nav.turn=(angle>0 and 1 or -1)*NAVCFG.yawSign*NAVCFG.turnVector
    nav.turnUntil=time+NAVCFG.turnSeconds;nav.reason='Align bow before forward cruise'
    return nav.turn,-nav.turn
  end
  nav.stage='CRUISE';nav.state='NAV CRUISE';nav.reason='Cruise altitude; GPS course estimate'
  return cruiseCommand(nav,m,dt)
end

local LOG_CHANNEL=42618
local LOG_MAGIC='fleet_log_v1'
local LOG_QUEUE,LOG_RECENT={},{}
local LOG_RUN=tostring(os.epoch and os.epoch('utc') or 0)..':'..math.random(1,1000000000)
local LOG_SEQ=0
local function emitLog(category,code,data)
  local stamp=os.epoch('utc');data=data or {}
  local signature=category..':'..code..':'..tostring(data.reason or data.error or data.state or data.action or '')
  if data.seq~=nil then signature=signature..':'..tostring(data.client)..':'..tostring(data.seq)end
  if LOG_RECENT[signature] and stamp-LOG_RECENT[signature]<1000 then return end
  LOG_RECENT[signature]=stamp
  for k,t in pairs(LOG_RECENT)do if stamp-t>5000 then LOG_RECENT[k]=nil end end
  LOG_SEQ=LOG_SEQ+1
  LOG_QUEUE[#LOG_QUEUE+1]={magic=LOG_MAGIC,key=setting('fleet.admin_key',''),id=LOG_RUN..':'..LOG_SEQ,
    source=ROLE and ROLE.slot or 0,actualId=ROLE and ROLE.actual or 0,role=ROLE and ROLE.role or '?',time=stamp,version=VERSION,category=category,code=code,data=data}
  if #LOG_QUEUE>64 then table.remove(LOG_QUEUE,1)end
end
local function logSender()
  while true do
    for _=1,4 do
      local m=table.remove(LOG_QUEUE,1);if not m then break end
      pcall(function()for _,side in ipairs(redstone.getSides())do if peripheral.hasType(side,'modem')then
        pcall(peripheral.call,side,'transmit',LOG_CHANNEL,LOG_CHANNEL,m)
      end end end)
    end
    sleep(0.1)
  end
end
local function logClean(value,seen,depth)
  local kind=type(value)
  if kind=='number'then return finite(value) and value or ('NONFINITE:'..tostring(value))end
  if kind~='table'then if kind=='string' or kind=='boolean' or kind=='nil'then return value end;return tostring(value)end
  seen=seen or {};depth=depth or 0
  if seen[value] or depth>12 then return '[CYCLE/DEPTH LIMIT]'end
  seen[value]=true;local count,max,array=0,0,true
  for k in pairs(value)do count=count+1;if type(k)~='number' or k%1~=0 or k<1 then array=false else max=math.max(max,k)end end
  array=array and count==max
  local out={}
  for k,v in pairs(value)do out[array and k or tostring(k)]=logClean(v,seen,depth+1)end
  seen[value]=nil;return out
end
local function newBlackbox()
  local function option(name,default,lo,hi)local n=tonumber(setting('fleet.blackbox_'..name,default));return finite(n) and clamp(n,lo,hi) or default end
  local c={interval=option('interval',1,0.5,1),maxBytes=option('bytes',32768,8192,131072),eventBytes=option('event_bytes',65536,8192,131072),
    reserve=option('reserve',24576,8192,262144),historySeconds=option('history_seconds',60,20,120),enabled=setting('fleet.blackbox',true)~=false}
  local b={config=c,queue={},history={},signatures={},seen={},written=0,dropped=0,error=nil,lastWrite=nil,lastSnapshot=-math.huge,lastStatus=nil,retry=0}
  local function encode(r)
    r=logClean(r)
    local ok,s=pcall(function()if textutils.serializeJSON then return textutils.serializeJSON(r)end;return textutils.serialize(r):gsub('\n',' ')end)
    if not ok then b.error=tostring(s);return nil end
    if #s>math.min(c.maxBytes,c.eventBytes,16384)-1 then
      b.dropped=b.dropped+1
      r={schema=1,time=r.time,source=r.source,actualId=r.actualId,role=r.role,category=r.category,code=r.code,data={truncated=true,originalBytes=#s}}
      local good,v=pcall(textutils.serialize,r);if not good then b.error=tostring(v);return nil end;s=v:gsub('\n',' ')
    end
    return s..'\n'
  end
  local function record(category,code,data,source)
    source=source or {}
    return {schema=1,time=source.time or os.epoch('utc'),receivedTime=os.epoch('utc'),source=source.source or 11,
      actualId=source.actualId or ROLE and ROLE.actual or 11,role=source.role or 'SENSOR_UI',run=LOG_RUN,
      session=b.lastStatus and b.lastStatus.session,version=source.version or VERSION,category=category,code=code,data=data}
  end
  local function enqueue(text,event,critical)
    if not c.enabled or not text then return end
    if #b.queue>=96 then
      local victim
      for i,v in ipairs(b.queue)do if not v.critical then victim=i;break end end
      table.remove(b.queue,victim or 1);b.dropped=b.dropped+1
    end
    b.queue[#b.queue+1]={text=text,event=event,critical=critical}
  end
  function b.event(category,code,data,critical,source)
    if not c.enabled then return end
    if data and data.ok~=false and (data.action=='STOP' or data.action=='MOTION_STOP' or data.action=='ADMIN_STOP' or data.action=='TEST_ABORT')then critical=true end
    local s=encode(record(category,code,data,source));if not s then return end
    b.lastEvent={time=os.epoch('utc'),category=category,code=code}
    if critical then
      local lines={};local size=#s;local now=os.epoch('utc')
      for i=#b.history,1,-1 do local h=b.history[i]
        if now-h.time<=30000 and size+#h.text<=c.eventBytes then table.insert(lines,1,h.text);size=size+#h.text end
      end
      lines[#lines+1]=s;enqueue(table.concat(lines),true,true)
    else enqueue(s,true,false)end
  end
  local function transition(key,value,category,code,data,critical)
    if b.signatures[key]~=value then b.signatures[key]=value;b.event(category,code,data,critical)end
  end
  local function summary(m,now)
    local nav=m.nav or {};local d=m.diagnostic or {};local nodes={};local control={}
    for _,id in ipairs({12,13,14,16,17,18,19})do local n=d.nodes and d.nodes[id]
      if n then nodes[tostring(id)]={actualId=n.actualId,role=n.role,version=n.version,ok=n.ok,state=n.state,error=n.error,
        age=finite(n.time) and (now-n.time)/1000 or nil,fineCount=n.fineCount,appliedReported=n.applied,gps=n.gps,localSensors=n.localSensors}end
    end
    for _,z in ipairs({'LF','RF','LB','RB'})do local v=m.zones and m.zones[z];if v then control[z]={main=v.main,sub=v.sub,fine=v.fine,fineLevels=v.fineLevels,signal=v.signal,phase=v.phase,total=v.total,target=v.target}end end
    return {state=m.state,armed=m.armed,error=m.error,coreVersion=m.version,coreAge=finite(m.time) and (now-m.time)/1000 or nil,
      fresh=fresh(m,1000),roles=m.roles,control={main=m.main,mainDemand=m.mainDemand,zones=control,vector=m.rotation,estimate=m.thrust},
      attitude={angles=m.angles,recovery=m.recovery,deadzone=m.deadzone,motion=m.attitudeMotion},nav={active=nav.active,mode=nav.commandMode,stage=nav.stage,state=nav.state,reason=nav.reason,
        gps=nav.gps,fix=nav.fix,target=nav.target,bow=nav.yaw,actual=nav.actual,course=nav.course,courseTrusted=nav.courseTrusted,courseError=nav.courseError,
        targetForward=nav.targetForward,turnAngle=nav.turnAngle,turnBoost=nav.turnBoost,yawSign=nav.yawSign,directionLock=nav.directionLock,
        velocity=nav.velocity,landing=nav.landing,landingPhase=nav.landingPhase,targetVy=nav.targetVy,diagnostics=nav.directionDiagnostics},
      sensor={name=d.sensor,present=d.present,ok=d.sensorOK,error=d.sensorError,gravity=d.gravity,rawAngles=d.rawAngles,
        time=d.sensorTime,age=finite(d.sensorTime) and (now-d.sensorTime)/1000 or nil,relay=m.inputs,relayAge=m.relayAge,relayError=d.relayWarning,velocity=d.velocity},nodes=nodes}
  end
  function b.observe(m)
    if not c.enabled or type(m)~='table'then return end
    b.lastStatus=m;local now=os.epoch('utc');local nav=m.nav or {};local d=m.diagnostic or {}
    local details={state=m.state,armed=m.armed,error=m.error,mode=nav.commandMode,stage=nav.stage,reason=nav.reason}
    transition('session',m.session,'SYSTEM','CORE_SESSION',{session=m.session,version=m.version})
    transition('state',tostring(m.state)..':'..tostring(m.armed)..':'..tostring(m.error),'SYSTEM','CONTROL_STATE',details,m.state=='FAULT' or m.state=='STOPPED')
    transition('armed',m.armed==true,'SYSTEM',m.armed and 'ARM' or 'DISARM',details)
    transition('mode',tostring(nav.active)..':'..tostring(nav.commandMode)..':'..tostring(nav.stage),'NAV','MODE_STAGE',details)
    transition('recovery',m.recovery and m.recovery.active==true,'ATTITUDE','RECOVERY',{recovery=m.recovery,angles=m.angles})
    transition('coreLink',fresh(m,1000),'NETWORK','CORE_LINK',{online=fresh(m,1000),time=m.time},not fresh(m,1000))
    transition('sensor',tostring(d.sensorOK)..':'..tostring(d.sensorError)..':'..tostring(finite(d.sensorTime) and now-d.sensorTime<=500),'SENSOR','BODY_SENSOR',
      {ok=d.sensorOK,error=d.sensorError,time=d.sensorTime},d.sensorOK==false)
    for _,name in ipairs({'lateral','forward','vertical'})do local v=d.velocity and d.velocity[name]
      transition('velocity:'..name,tostring(v and v.ok)..':'..tostring(v and v.error)..':'..tostring(v and finite(v.time) and now-v.time<=VELCFG.maxAge*1000),'SENSOR','VELOCITY_STATE',
        {role=name,sensor=v and v.sensor,ok=v and v.ok,error=v and v.error,time=v and v.time})
    end
    transition('gps',tostring(nav.gps)..':'..tostring(nav.yaw and nav.yaw.reason),'SENSOR','GPS_BOW',{gps=nav.gps,bow=nav.yaw})
    local vector=m.rotation or {}
    transition('vector',tostring(vector.enabled)..':'..tostring(vector.left)..':'..tostring(vector.right)..':'..tostring(m.main),'CONTROL','VECTOR_MAIN',
      {main=m.main,vector=vector,targetForward=nav.targetForward})
    for _,id in ipairs({12,13,14,16,17,18,19})do local n=d.nodes and d.nodes[id]
      local online=n and finite(n.time) and now-n.time<=CFG.nodeTimeout*1000
      transition('node:'..id,tostring(online==true)..':'..tostring(n and n.ok)..':'..tostring(n and n.error)..':'..tostring(n and n.fineCount),'NODE','NODE_STATE',
        {id=id,actualId=n and n.actualId,role=n and n.role,online=online==true,ok=n and n.ok,error=n and n.error,fineCount=n and n.fineCount},n and n.ok==false or not online)
    end
    transition('conflict',m.roles and m.roles.conflict or '', 'NETWORK','ROLE_CONFLICT',{error=m.roles and m.roles.conflict},m.roles and m.roles.conflict~=nil)
    local warnings=nav.directionDiagnostics and nav.directionDiagnostics.warnings or {}
    transition('directions',table.concat(warnings,','),'NAV','DIRECTION_DIAGNOSTICS',nav.directionDiagnostics)
    for _,warning in ipairs(warnings)do
      if b.signatures['warn:'..warning]~=true then b.event('NAV',warning,nav.directionDiagnostics,false)end
      b.signatures['warn:'..warning]=true
    end
    for _,warning in ipairs({'BOW_COURSE_OPPOSITE','YAW_ERROR_GROWING','FORWARD_COMMAND_REVERSE_MOTION','YAW_BASELINE_INVALID','YAW_MOUNT_DISTANCE_INVALID','YAW_HORIZONTAL_PROJECTION_INVALID','YAW_ATTITUDE_UNTRUSTED','YAW_RECOVERING','YAW_GPS_DEGRADED','VECTOR_DIRECTION_SUSPECT','BOW_CONFIG_INVALID','BOW_UNVERIFIED'})do
      local found=false;for _,v in ipairs(warnings)do found=found or v==warning end;if not found then b.signatures['warn:'..warning]=false end
    end
    if now-b.lastSnapshot>=c.interval*1000 then
      b.lastSnapshot=now;local text=encode(record('SNAPSHOT','SHIP_STATE',summary(m,now)))
      if text then
        b.history[#b.history+1]={time=now,text=text};while #b.history>0 and (now-b.history[1].time>c.historySeconds*1000 or #b.history>120)do table.remove(b.history,1)end
        enqueue(text,false,false)
      end
    end
  end
  function b.status()return {enabled=c.enabled,path='fleet_blackbox.log',events='fleet_blackbox_event.log',queued=#b.queue,history=#b.history,
    written=b.written,dropped=b.dropped,error=b.error,lastWrite=b.lastWrite,lastEvent=b.lastEvent}end
  local function size(path)
    if not fs.exists(path)then return 0 end
    assert(not fs.isDir(path),'Blackbox path is a directory')
    if fs.getSize then return fs.getSize(path)end
    local h=assert(fs.open(path,'r'));local v=h.readAll();h.close();return #v
  end
  local function append(group)
    local path=group.event and 'fleet_blackbox_event.log' or 'fleet_blackbox.log'
    local prev=group.event and 'fleet_blackbox_event_prev.log' or 'fleet_blackbox_prev.log'
    local max=group.event and c.eventBytes or c.maxBytes
    if size(path)+#group.text>max then
      if fs.exists(prev)then assert(not fs.isDir(prev),'Blackbox previous path is a directory');fs.delete(prev)end
      if fs.exists(path)then fs.move(path,prev)end
    end
    local free=assert(fs.getFreeSpace,'No free-space API')('')
    for _,old in ipairs({'fleet_blackbox_prev.log','fleet_blackbox.log','fleet_blackbox_event_prev.log'})do
      if free~='unlimited' and free<#group.text+c.reserve and fs.exists(old)then assert(not fs.isDir(old),'Blackbox cleanup path is a directory');fs.delete(old);free=fs.getFreeSpace('')end
    end
    assert(free=='unlimited' or type(free)=='number' and free>=#group.text+c.reserve,'Blackbox Out of space; protected code/rollback files untouched')
    local h,why=fs.open(path,'a');assert(h,why);local ok,err=pcall(h.write,group.text);h.close();assert(ok,err)
    b.written=b.written+1;b.lastWrite=os.epoch('utc');b.error=nil
  end
  function b.flush()
    if not c.enabled or os.clock()<b.retry then return end
    for _=1,2 do
      local index
      for i,g in ipairs(b.queue)do if g.critical then index=i;break end end
      index=index or 1;local group=b.queue[index];if not group then return end
      local ok,err=pcall(append,group)
      if not ok then b.error=tostring(err);b.retry=os.clock()+5;return end
      table.remove(b.queue,index)
    end
  end
  function b.safeObserve(m)local ok,err=pcall(b.observe,m);if not ok then b.error=tostring(err)end end
  function b.accept(m)
    if type(m)~='table' or m.magic~=LOG_MAGIC or m.key~=setting('fleet.admin_key','') or not fresh(m,10000)
      or type(m.id)~='string' or #m.id>150 or type(m.category)~='string' or #m.category>20 or type(m.code)~='string' or #m.code>80
      or type(m.data)~='table' or not ROLE or not ROLE.roles[m.source] or not finite(m.actualId) or ROLE.resolve(m.source)~=m.actualId then return false end
    if b.seen[m.id]then return false end;b.seen[m.id]=os.clock()
    b.event(m.category,m.code,m.data,m.category=='SAFETY' or m.data.error~=nil,m)
    return true
  end
  function b.worker()
    b.event('SYSTEM','BLACKBOX_START',{version=VERSION,interval=c.interval,config=c})
    while true do
      if b.lastStatus then b.safeObserve(b.lastStatus)end
      local ok,err=pcall(b.flush);if not ok then b.error=tostring(err);b.retry=os.clock()+5 end
      for k,t in pairs(b.seen)do if os.clock()-t>30 then b.seen[k]=nil end end
      sleep(0.2)
    end
  end
  return b
end
if args[1]=='test_api' then return {attitudeMotionStep=attitudeMotionStep,logClean=logClean,newBlackbox=newBlackbox,directionDiagnostics=directionDiagnostics,rolesFactory=newRoles,discoverFine=discoverFine,modecfg=MODECFG,verticalHold=verticalHold,manualStep=manualStep,hoverStep=hoverStep,testStep=testStep,finishTest=finishTest,testRecords=function(nav)return TEST_RECORDS[nav]end,cruisecfg=CRUISECFG,directionLock=directionLock,resetCruise=resetCruise,brakingModel=brakingModel,velocityValues=velocityValues,applyVelocity=applyVelocity,speedGuard=speedGuard,cruiseCommand=cruiseCommand,velcfg=VELCFG,geometry=geometry,zones=zones,allocate=allocate,rotationValues=rotationValues,cfg=CFG,navcfg=NAVCFG,axisDemand=axisDemand,navMetrics=navMetrics,newMixer=newMixer,mixStep=mixStep,estimate=estimate,balance=balance,thrust=THRUST,recoveryState=recoveryState,recoverycfg=RECOVERY,newRecovery=newRecovery,recoveryStep=recoveryStep,recoveryDemand=recoveryDemand,navStep=navStep,ingestGPS=ingestGPS,navGPSState=navGPSState,suspendGPS=suspendGPS,navHold=navHold,yawcfg=YAWCFG,landcfg=LANDCFG,yawPose=yawPose,yawCommand=yawCommand,wrapAngle=wrapAngle,sampleGPS=sampleGPS,landingProfile=landingProfile,landingStep=landingStep,landingStage=landingStage} end
local function managedStop()
  while true do
    local _,id=os.pullEvent('fleet_managed_stop')
    if id==os.getComputerID() then return end
  end
end
local function runtime(state,active,errorText,maintenance)
  if FLEET_RUN and os.queueEvent then
    os.queueEvent('fleet_runtime',os.getComputerID(),{state=state,active=active,error=errorText,
      version=VERSION,time=os.epoch('utc'),run=FLEET_RUN,maintenance=maintenance})
  end
end
local function bodyGPS(id,receive)
  local last={id=id,ok=false}
  sleep((id-10)*0.08)
  while true do
    local scanned,radio=pcall(function()
      for _,side in ipairs(redstone.getSides()) do
        if peripheral.hasType(side,'modem') then
          local ok,v=pcall(peripheral.call,side,'isWireless');if ok and v==true then return true end
        end
      end
      return false
    end)
    radio=scanned and radio
    local ok,x,y,z
    if radio then ok,x,y,z=pcall(function()return gps.locate(YAWCFG.gpsLocateTimeout,false)end)
    else ok,x=false,'NO LOCAL WIRELESS GPS' end
    last=sampleGPS(last,id,ok,x,y,z,os.epoch('utc'));receive(last)
    sleep(YAWCFG.gpsPollSeconds)
  end
end
local function node(id)
  local stopWire=wiring()
  local names={}
  local zero={}
  if FINE[id] then
    names=discoverFine();for i=1,#names do zero[i]=0 end
  else for side in pairs(SIDES[id]) do zero[side]=0 end end
  local target,applied={},{}
  for k,v in pairs(zero) do target[k]=v end
  local session,lastSeq,lastRx=nil,-1,-math.huge
  local errorText,healthy=nil,false
  local force=true
  local nodeGPS={id=id,ok=false}
  local localSensors={}
  local function localSensorReader()
    if not FINE[id] then while true do sleep(60) end end
    while true do
      local bindings=setting('fleet.local_sensors',{})
      local sample={};local count=0
      if type(bindings)=='table' then for role,name in pairs(bindings)do
        if type(role)=='string' and #role<=40 and type(name)=='string' and #name<=100 and count<8 then
          count=count+1
          local record={name=name,bodyReference=false,ok=true,values={}}
          local ok,methods=pcall(peripheral.getMethods,name)
          if not ok or type(methods)~='table' then record.ok=false;record.error='Local sensor unavailable'
          else
            for _,method in ipairs(methods)do
              if method=='getVelocity' or method=='getAxis' or method=='getAngles' or method=='getGravity' then
                local good,value=pcall(peripheral.call,name,method)
                local valid=method=='getVelocity' and finite(value) or method=='getAxis' and type(value)=='string' and #value<=16 or method=='getAngles' and validArray(value,2) or method=='getGravity' and validArray(value,3)
                if good and valid then record.values[method]=value
                else record.ok=false;record.error=tostring(value) end
              end
            end
          end
          if next(record.values)==nil then record.ok=false;record.error=record.error or 'No supported local sensor read method' end
          record.time=os.epoch('utc');sample[role]=record
        end
      end end
      localSensors=sample;sleep(0.5)
    end
  end
  local function gpsReader()
    if FINE[id] then while true do sleep(60) end end
    bodyGPS(id,function(g)nodeGPS=g end)
  end
  local function reset()
    target={};for k,v in pairs(zero) do target[k]=v end
    force=true
  end
  local function write(values)
    if id==14 then
      for _,pair in ipairs({{'left','right'},{'top','bottom'}}) do
        local a,b=pair[1],pair[2]
        local ok,err=pcall(function()
          if values[a]>0 and values[b]>0 then error('Rotation direction conflict') end
          if force or applied[a]~=values[a] or applied[b]~=values[b] then
            redstone.setAnalogOutput(a,0);applied[a]=0
            redstone.setAnalogOutput(b,0);applied[b]=0
            if values[a]>0 then redstone.setAnalogOutput(a,values[a]);applied[a]=values[a] end
            if values[b]>0 then redstone.setAnalogOutput(b,values[b]);applied[b]=values[b] end
          end
        end)
        if not ok then errorText=tostring(err);healthy=false end
      end
      force=false;return
    end
    local tasks={}
    for key,value in pairs(values) do
      if force or applied[key]~=value then
        local k,v=key,value
        tasks[#tasks+1]=function()
          local ok,err
          if FINE[id] then ok,err=pcall(peripheral.call,names[k],'setPowerNormalized',v)
          else ok,err=pcall(redstone.setAnalogOutput,k,v) end
          if ok then applied[k]=v else errorText=tostring(err);healthy=false end
        end
      end
    end
    if #tasks>0 then parallel.waitForAll(table.unpack(tasks)) end
    force=false
  end
  local function validate()
    errorText=nil;healthy=true;applied={};force=true
    if FINE[id] then
      for _,name in ipairs(names) do
        if not peripheral.hasType(name,'ion_thruster') then errorText='Missing '..name;healthy=false;break end
        local methods=peripheral.getMethods(name) or {}
        local found=false
        for _,m in ipairs(methods) do if m=='setPowerNormalized' then found=true end end
        if not found then errorText='No setPowerNormalized: '..name;healthy=false;break end
      end
    end
  end
  local function receiver()
    while true do
      local from,m=receiveFlight(PROTO)
      if from==10 and fresh(m,1000) then
        if m.kind=='BIND' and type(m.session)=='string' then
          if FINE[id] then
            local ok,list=pcall(discoverFine)
            if ok then
              local changed=#list~=#names;for i,n in ipairs(list)do changed=changed or names[i]~=n end
              if changed then write(zero) end
              names=list;zero={};for i=1,#names do zero[i]=0 end
            else healthy=false;errorText=tostring(list);reset() end
          end
          reset();session=m.session;lastSeq=-1;lastRx=os.clock();validate()
          if FINE[id] then local ok,why=pcall(discoverFine);if not ok then healthy=false;errorText=tostring(why) end end
        elseif m.kind=='STOP' then reset();lastRx=-math.huge
        elseif m.kind=='OUTPUT' and m.session==session and finite(m.seq) and m.seq>lastSeq then
          local good=type(m.values)=='table'
          if m.disabled==true then reset();lastSeq=m.seq;lastRx=os.clock() end
          if m.disabled~=true then for k in pairs(zero) do
            local v=good and m.values[k]
            if not finite(v) or v<0 or v>(FINE[id] and 1 or 15)
              or (not FINE[id] and v%1~=0) then good=false end
          end
          end
          if id==14 and good and ((m.values.left>0 and m.values.right>0)
            or (m.values.top>0 and m.values.bottom>0)) then good=false end
          if m.disabled==true then reset()
          elseif good and healthy then target=m.values;lastSeq=m.seq;lastRx=os.clock()
          else reset();healthy=false;errorText=errorText or 'Invalid command' end
        end
      end
    end
  end
  local function writer()
    write(zero);validate()
    while true do
      local conflict=ROLE.conflict();if conflict then healthy=false;errorText=conflict end
      if os.clock()-lastRx>CFG.nodeTimeout or not healthy then reset() end
      local snapshot={};for k,v in pairs(target) do snapshot[k]=v end
      write(snapshot)
      if not healthy then reset();write(zero) end
      sleep(CFG.tick)
    end
  end
  local function report()
    local lastEvent;local localFaults={}
    emitLog('SYSTEM','NODE_START',{id=id,version=VERSION})
    while true do
      if FINE[id] then
        for _,name in ipairs(names) do
          if not peripheral.hasType(name,'ion_thruster') then
            healthy=false;errorText='Missing '..name;reset()
          end
        end
      end
      local active=false;for _,v in pairs(applied) do if v>0 then active=true end end
      for role,sample in pairs(localSensors)do
        local failure=sample.ok==false and tostring(sample.error or 'Local sensor failed') or nil
        if failure~=localFaults[role]then localFaults[role]=failure;emitLog('SENSOR',failure and 'LOCAL_SENSOR_ERROR' or 'LOCAL_SENSOR_RECOVERED',
          {id=id,role=role,name=sample.name,error=failure,bodyReference=false})end
      end
      local event=tostring(healthy)..':'..tostring(errorText)..':'..tostring(#names)
      if event~=lastEvent then lastEvent=event;emitLog(healthy and 'NODE' or 'SAFETY',healthy and 'NODE_READY' or 'NODE_FAULT',{id=id,error=errorText,fineCount=FINE[id] and #names,appliedReported=applied})end
      runtime(healthy and 'OUTPUT NODE' or 'FAULT',active,errorText)
      send(10,{kind='NODE',session=session,id=id,ok=healthy,error=errorText,
        localSensors=FINE[id] and localSensors or nil,fineCount=FINE[id] and #names or nil,fineNames=FINE[id] and names or nil,role=ROLE.role,actualId=ROLE.actual,seq=lastSeq,applied=applied,gps=not FINE[id] and nodeGPS or nil,version=VERSION,state=healthy and
          (os.clock()-lastRx<=CFG.nodeTimeout and 'RECEIVING' or 'WAITING') or 'FAULT'})
      term.clear();term.setCursorPos(1,1)
      print('FLEET NODE '..id)
      print(id==14 and 'ROTATION L / R' or FINE[id] and FINE[id].zone or 'MAIN / SUB')
      print(healthy and 'READY' or tostring(errorText))
      for k,v in pairs(applied) do print(tostring(k)..': '..string.format('%.3f',v)) end
      sleep(0.25)
    end
  end
  local function keyboard()
    while true do local _,k=os.pullEvent('key');if k==keys.q then return end end
  end
  local ok,err=pcall(function() parallel.waitForAny(receiver,writer,report,keyboard,managedStop,gpsReader,roleWorker,localSensorReader,logSender) end)
  force=true
  parallel.waitForAny(function()pcall(write,zero)end,function()sleep(CFG.stopWriteTimeout)end)
  stopWire()
  if not ok then
    if FLEET_RUN then os.queueEvent('fleet_run_error',os.getComputerID(),tostring(err),FLEET_RUN) end
    print(tostring(err))
  end
end
local function controller()
  local stopWire=wiring()
  print('FLEET FAST CONTROL 10 - use computer 11 UI')
  local session=uid()
  local health={}
  local enabled,armed=false,false
  local baseMain=0
  local uiSeen=-math.huge
  local uiSeq=-1
  local sequence=0
  local state='CHECKING'
  local checkStart=os.clock()
  local faultText
  local inputs={left=0,right=0,front=0,back=0}
  local relaySeen,relaySeq=-math.huge,-1
  local lastTick
  local roll,pitch,tilt=0,0,0
  local axis,prev,lastRead,rawGravity,rawAngles,angleTime
  local rateR,rateP=0,0
  local relayWarning
  local sensorTime
  local sensorOK,sensorError,sensorPresent=false,nil,false
  local angleOK,angleError=false,nil
  local rotation={enabled=false,left=0,right=0}
  local mixer=newMixer({LF=0,RF=0,LB=0,RB=0})
  local recovery=newRecovery()
  local attitudeMotion={moving=false,mode='HOVER',deadzone=CFG.hoverDeadzone}
  local thrustState={total=0}
  local zoneState={}
  local interval=0
  local nav={active=false,state='NAV IDLE',reason='Experimental / not flight tested'}
  local navFix,navPrevious,pilotSeen,navFixTime=nil,nil,-math.huge,nil
  local gpsTrack={}
  local yawTrack={}
  local directionTrack={}
  local velocityPacket={}
  local function gpsReader() bodyGPS(10,function(g)health[10]={ok=true,time=os.epoch('utc'),gps=g} end) end
  local requestSeq,requestAck={},{}
  local function cancelNav(state,reason)
    finishTest(nav,reason or 'Cancelled',true)
    resetCruise(nav)
    if nav.active then
      rotation={enabled=false,left=0,right=0}
      if finite(nav.manualBase) then baseMain=nav.manualBase end
    end
    nav.active=false;nav.targetForward=0;nav.turnBoost=0;nav.turnAngle=0;nav.yawAligned=false;nav.courseTrusted=false;nav.state=state or 'NAV CANCELLED';nav.reason=reason
  end
  local function stop(reason)
    emitLog(reason=='FAULT' and 'SAFETY' or 'SYSTEM',reason,{reason=faultText or reason,state=state})
    cancelNav(reason=='FAULT' and 'NAV FAULT' or 'NAV CANCELLED',reason=='FAULT' and (faultText or 'Flight control fault') or 'Flight stopped')
    rotation={enabled=false,left=0,right=0}
    armed=false;enabled=false;baseMain=0;mixer=newMixer(mixer.counts);recovery=newRecovery();thrustState={total=0}
    for _,id in ipairs(IDS) do send(id,{kind='STOP',session=session}) end
    state=reason
  end
  local function bind()
    stop('CHECKING');session=uid();health={};uiSeq=-1
    requestSeq={};requestAck={};navFix=nil;navPrevious=nil;navFixTime=nil;gpsTrack={};yawTrack={};velocityPacket={};pilotSeen=-math.huge
    faultText=nil;prev=nil;lastRead=nil;relayWarning=nil;relaySeen=-math.huge;relaySeq=-1;checkStart=os.clock()
    for _,id in ipairs(IDS) do send(id,{kind='BIND',session=session}) end
  end
  local maintenanceSince,maintenanceMissing,maintenanceFrames=nil,nil,0
  local function maintenanceAllowed()
    local m=FLEET_MAINTENANCE
    return FLEET_UPDATE_LOCK and type(m)=='table' and m.secured==true and os.clock()<m.expires
      and not armed and not rotation.enabled and not nav.active and baseMain==0
  end
  local function ready()
    local conflict=ROLE.conflict();if conflict then return false,conflict end
    for _,id in ipairs(IDS)do local h=health[id]
      if h and (h.ok==false or h.error) then return false,'Node '..id..': '..tostring(h.error or 'FAULT') end
    end
    for _,id in ipairs(IDS) do local h=health[id]
      if not h or h.session~=session or os.clock()-h.seen>CFG.nodeTimeout then return false,'Node '..id..': no response',true end
    end
    local names={}
    for id,f in pairs(FINE) do
      local h=health[id]
      if not h or type(h.fineCount)~='number' or h.fineCount<1 or h.fineCount>64 then return false,'Fine inventory missing: '..f.zone end
      for _,name in ipairs(h.fineNames or {})do if names[name] then return false,'Duplicate/shared Fine '..name end;names[name]=true end
    end
    local conflict=ROLE.conflict();if conflict then return false,conflict end
    for _,id in ipairs(IDS) do
      local h=health[id]
      if not h or h.session~=session or os.clock()-h.seen>CFG.nodeTimeout or not h.ok then
        return false,'Node '..id..': '..(h and h.error or 'no response')
      end
    end
    return true
  end
  local function pilot(m)
    local a=m.action
    local allowed={HOVER_START=true,DRIVE=true,TEST_START=true,TEST_ABORT=true,STOP=true,MOTION_STOP=true,ADMIN_STOP=true,NAV_CANCEL=true,RECHECK=true,NAV_START=true,ARM=true,MAIN_UP=true,MAIN_DOWN=true,VECTOR_OFF=true,VECTOR_ON=true,VECTOR_ZERO=true,VECTOR_FWD=true,VECTOR_BACK=true,LEFT_UP=true,LEFT_DOWN=true,RIGHT_UP=true,RIGHT_DOWN=true}
    if type(a)~='string' or not allowed[a] then return false,'Unknown command' end
    if a=='ADMIN_STOP' then stop('STOPPED');return true,'MASTER STOP: DISARM and all outputs zero' end
    if a=='STOP' or a=='MOTION_STOP' or a=='TEST_ABORT' then
      cancelNav('NAV CANCELLED','Motion stopped; ARM and manual base retained')
      rotation={enabled=false,left=0,right=0}
      return true,'MOTION STOP: vector zero; ARM unchanged'
    end
    if a=='NAV_CANCEL' then cancelNav('NAV CANCELLED','Pilot cancelled');return true,'NAV cancelled; manual base restored' end
    if a=='RECHECK' then bind();return true,'Recheck started' end
    if FLEET_UPDATE_LOCK and a~='VECTOR_OFF' then return false,'UPDATE maintenance: all output activation locked' end
    if a=='HOVER_START' or a=='DRIVE' or a=='TEST_START' then
      local ok,why=ready();local t=m.target or {}
      if type(t)~='table' then return false,'Invalid mode request' end
      if t.y~=nil and (not finite(t.y) or math.abs(t.y)>30000000) then return false,'Invalid target Y' end
      if t.duration~=nil and (not finite(t.duration) or t.duration<1 or t.duration>MODECFG.testMaxDuration) then return false,'Test duration must be 1..60 seconds' end
      if t.speed~=nil and (not finite(t.speed) or t.speed< -30 or t.speed>50) then return false,'Signed speed must be -30..50' end
      if not ok or faultText or not armed or not sensorOK or recovery.active then return false,why or faultText or 'ARM/stable sensor required' end
      if navGPSState(gpsTrack,os.epoch('utc'))~='FIX' then return false,'Fresh GPS required' end
      local velocity=velocityValues(velocityPacket,os.epoch('utc'))
      if not finite(velocity.forward) or not finite(velocity.vertical) or not finite(velocity.lateral) then return false,'All three velocity sensors required' end
      local pose=yawPose(health,nil,os.epoch('utc'),yawTrack,nil,{tilt=tilt,gravity=rawGravity})
      if a=='DRIVE' and (not pose.valid or not finite(t.heading) or not finite(t.speed) or t.speed>50 or t.speed< -30) then return false,'Calibrated body YAW, absolute heading and signed speed -30..50 required' end
      if a=='HOVER_START' and (not finite(t.y) or math.abs(t.y)>30000000) then return false,'Valid HOVER Y required' end
      if a=='TEST_START' then
        if not ({THRUST=true,BRAKE=true,HOVER=true,YAW=true})[t.test] then return false,'Select THRUST/BRAKE/HOVER/YAW' end
        if t.test=='YAW' and (not pose.valid or not finite(t.heading)) then return false,'Calibrated YAW/heading required' end
        if t.test=='BRAKE' and math.abs(velocity.forward)<math.max(1,math.abs(tonumber(t.speed) or 1)) then return false,'Reach selected starting speed before BRAKE TEST' end
      end
      local manual=nav.active and nav.manualBase or baseMain
      cancelNav('NAV CANCELLED','New operating mode')
      nav={active=true,manualBase=manual,main=manual,holdY=navFix.y,target={x=navFix.x,y=t.y or navFix.y,z=navFix.z},state='MODE CHECK',commandMode=a=='DRIVE' and 'MANUAL' or a=='HOVER_START' and 'HOVER' or 'TEST',heading=finite(t.heading) and wrapAngle(t.heading) or nil,requestedSpeed=t.speed}
      resetCruise(nav)
      if a=='TEST_START' then nav.test={kind=t.test,duration=clamp(tonumber(t.duration) or MODECFG.testDuration,1,MODECFG.testMaxDuration),heading=finite(t.heading) and wrapAngle(t.heading) or nil,startSpeed=math.abs(velocity.forward)} end
      rotation={enabled=true,left=0,right=0};navFixTime=nil
      return true,nav.commandMode..' accepted'
    end
    if a=='NAV_START' then
      cancelNav('NAV CANCELLED','New navigation request')
      nav={active=false,state='NAV CHECK',target=m.target}
      local ok,why=ready()
      if not validPosition(m.target) then nav.state='NAV FAULT';nav.reason='Invalid XYZ';return false,nav.reason end
      if not ok or faultText or not armed or not sensorOK then
        nav.state='NAV FAULT';nav.reason=why or faultText or 'ARM and sensor required';return false,nav.reason
      end
      if navGPSState(gpsTrack,os.epoch('utc'))~='FIX' then
        nav.state='NAV GPS LOST';nav.reason='Fresh GPS FIX required';return false,nav.reason
      end
      if not NAVCFG.courseVerified or (NAVCFG.yawSign~=1 and NAVCFG.yawSign~=-1)
        or not finite(NAVCFG.hoverMain) or NAVCFG.hoverMain<0 or NAVCFG.hoverMain>NAVCFG.maxMain then
        nav.state='NAV FAULT';nav.reason='Set tested NAVCFG: courseVerified, yawSign, hoverMain';return false,nav.reason
      end
      if not finite(NAVCFG.cruiseY) or NAVCFG.cruiseY< -64 or NAVCFG.cruiseY>10000 then nav.state='NAV FAULT';nav.reason='Invalid cruiseY';return false,nav.reason end
      if recovery.active then nav.state='NAV FAULT';nav.reason='RECOVERY active';return false,nav.reason end
      if baseMain>NAVCFG.maxMain then nav.state='NAV FAULT';nav.reason='Reduce manual main below NAV maxMain';return false,nav.reason end
      resetCruise(nav);nav.brakeSamples=nil;nav.measuredDeceleration=nil;nav.brakeConfidence=nil
      nav.active=true;nav.commandMode='CRUISE';nav.targetForward=0;nav.probeFailCount=0;nav.probeAngle=NAVCFG.probeVector;nav.manualBase=baseMain;nav.main=baseMain;nav.stage='ALTITUDE';nav.state='NAV ALTITUDE';nav.started=os.clock();nav.cruiseY=NAVCFG.cruiseY
      nav.reason='Cruise altitude first; experimental GPS course control';navFixTime=nil
      rotation={enabled=true,left=0,right=0};return true,'Experimental GOTO accepted'
    end
    cancelNav('NAV CANCELLED','Manual control')
    if a=='ARM' then
      if FLEET_UPDATE_LOCK then return false,'UPDATE verification pending; ARM locked' end
      local ok,why=ready()
      if not ok or faultText or not lastRead or os.clock()-lastRead>=0.5 then return false,why or faultText or 'Sensor not ready' end
      armed=true;enabled=true;baseMain=0;return true,'ARM accepted'
    elseif a=='MAIN_UP' or a=='MAIN_DOWN' then
      if not armed then return false,'ARM required' end
      baseMain=clamp(baseMain+(a=='MAIN_UP' and 1 or -1),0,15);return true,'Main command accepted'
    elseif a=='VECTOR_OFF' then rotation={enabled=false,left=0,right=0};return true,'Vector disabled'
    elseif a=='VECTOR_ON' or a=='VECTOR_ZERO' or a=='VECTOR_FWD' or a=='VECTOR_BACK'
      or a=='LEFT_UP' or a=='LEFT_DOWN' or a=='RIGHT_UP' or a=='RIGHT_DOWN' then
      local ok,why=ready();if not ok or faultText then return false,why or faultText end
      rotation.enabled=true
      if a=='VECTOR_ON' or a=='VECTOR_ZERO' then rotation.left=0;rotation.right=0
      elseif a=='VECTOR_FWD' or a=='VECTOR_BACK' then
        local d=a=='VECTOR_FWD' and 6 or -6
        rotation.left=clamp(rotation.left+d,-90,90);rotation.right=clamp(rotation.right+d,-90,90)
      elseif a=='LEFT_UP' then rotation.left=clamp(rotation.left+6,-90,90)
      elseif a=='LEFT_DOWN' then rotation.left=clamp(rotation.left-6,-90,90)
      elseif a=='RIGHT_UP' then rotation.right=clamp(rotation.right+6,-90,90)
      else rotation.right=clamp(rotation.right-6,-90,90) end
      return true,'Vector command accepted'
    end
    return false,'Unknown command'
  end
  local function receiver()
    while true do
      local id,m=receiveFlight(PROTO)
      if fresh(m,1000) and m.kind=='NODE' and m.session==session then
        for _,n in ipairs(IDS) do
          if id==n and m.id==id then
            if FINE[id] then
              local count=m.fineCount
              if finite(count) and count%1==0 and count>=1 and count<=64 and type(m.fineNames)=='table' and #m.fineNames==count then
                local z=FINE[id].zone
                if armed and mixer.counts[z]~=count then faultText='Fine inventory changed: '..z;stop('FAULT') end
                mixer.counts[z]=count;mixer.zones[z].fineCount=count
              else m.ok=false;m.error='Invalid Fine inventory' end
            end
            m.seen=os.clock();health[id]=m
          end
        end
      elseif id==11 and fresh(m,1000) then
        if m.kind=='HEARTBEAT' and m.session==session then uiSeen=os.clock()
        elseif m.kind=='BODY_GPS' and m.session==session then
          health[11]={ok=true,time=m.time,gps=m.gps}
        elseif m.kind=='VELOCITY' and m.session==session and type(m.values)=='table' then
          for _,role in ipairs({'lateral','forward','vertical'}) do
            local v=m.values[role];local old=velocityPacket[role]
            if type(v)=='table' and finite(v.time) and (not old or not finite(old.time) or v.time>=old.time) then velocityPacket[role]=v end
          end
        elseif m.kind=='NAV_FIX' and m.session==session and fresh({time=m.pilotTime},3000) then
          pilotSeen=os.clock()
          local g=m.fix
          if type(g)=='table' then local copy={};for k,v in pairs(g)do copy[k]=v end;copy.id=15;health[15]={ok=true,time=m.time,gps=copy} end
          ingestGPS(gpsTrack,m.fix,os.epoch('utc'))
          navFix=gpsTrack.fix;navPrevious=gpsTrack.previous
        elseif m.kind=='PILOT' and m.session==session and type(m.client)=='string' and #m.client<=100
          and finite(m.seq) and m.seq%1==0 and m.seq>=0 then
          uiSeen=os.clock()
          local k=m.client
          if requestSeq[k]==nil then
            local count=0;for _ in pairs(requestSeq) do count=count+1 end
            if count>=16 then k=nil end
          end
          if k then
            if not requestSeq[k] or m.seq>requestSeq[k] then
              requestSeq[k]=m.seq
              local ok,reason=pilot(m)
              emitLog('EVENT','PILOT_ACK',{action=m.action,client=k,seq=m.seq,ok=ok,reason=reason,target=m.target})
              requestAck[k]={kind='PILOT_ACK',client=k,seq=m.seq,ok=ok,reason=reason,session=session,level='COMMAND ACCEPTED'}
            end
            if requestAck[k] and requestAck[k].seq==m.seq then send(11,requestAck[k]) end
          end
        elseif m.kind=='STOP' then stop('STOPPED')
        elseif m.kind=='RECHECK' then bind()
        elseif m.kind=='RELAY' and fresh(m,CFG.relayTimeout*1000) and m.session==session and finite(m.seq) and m.seq>relaySeq then
          relaySeq=m.seq
          if relayValid(m.inputs) then inputs=m.inputs;relaySeen=os.clock();relayWarning=nil
          else relayWarning='Invalid relay data' end
        elseif m.kind=='RELAY_ERROR' and m.session==session then
          relayWarning=tostring(m.error)
        elseif m.kind=='ROT_ARM' and m.session==session and not faultText and not FLEET_UPDATE_LOCK then
          if ready() then rotation={enabled=true,left=0,right=0} end
        elseif m.kind=='ARM' and m.session==session and not faultText and not FLEET_UPDATE_LOCK then
          local ok=ready()
          if ok and lastRead and os.clock()-lastRead<0.5 then armed=true;enabled=true;baseMain=0 end
        elseif m.kind=='COMMAND' and m.session==session and finite(m.seq) and m.seq>uiSeq then
          uiSeq=m.seq;uiSeen=os.clock()
          if m.enabled==false and armed then stop('OFF')
          elseif m.enabled==true and armed and not faultText and finite(m.main) then
            local ok=ready()
            if ok and lastRead and os.clock()-lastRead<0.5 then
              enabled=true;armed=true;baseMain=clamp(math.floor(m.main),0,15)
            end
          end
          if type(m.rotation)=='table' and type(m.rotation.enabled)=='boolean'
            and finite(m.rotation.left) and finite(m.rotation.right) and not faultText and not FLEET_UPDATE_LOCK then
            local h=health[14]
            if h and h.ok and os.clock()-h.seen<=CFG.nodeTimeout and (rotation.enabled or not m.rotation.enabled) then
              rotation={enabled=m.rotation.enabled,left=clamp(m.rotation.left,-90,90),right=clamp(m.rotation.right,-90,90)}
            end
          end
        end
      end
    end
  end
  local function baseDemand()
    return nav.active and clamp(nav.main+(nav.turnBoost or 0),0,NAVCFG.maxMain) or baseMain
  end
  local function output(r,p,dt)
    local conflict=ROLE.conflict();if conflict and (armed or rotation.enabled) then faultText=conflict;stop('FAULT') end
    if nav.active and nav.commandMode=='MANUAL' and not (nav.yaw and nav.yaw.valid) then rotation.left=0;rotation.right=0 end
    local velocity=velocityValues(velocityPacket,os.epoch('utc'))
    local forward=velocity.forward
    if not finite(forward) and nav.yaw and nav.yaw.valid and nav.actual and finite(nav.actual.vx) and nav.gps=='FIX' then
      forward=nav.actual.vx*math.cos(math.rad(nav.yaw.yaw))+nav.actual.vz*math.sin(math.rad(nav.yaw.yaw))
    end
    if rotation.enabled and not recovery.active then
      local l,r,why=speedGuard(rotation.left,rotation.right,forward)
      rotation.appliedLeft=l;rotation.appliedRight=r;nav.speedGuard=why
    else rotation.appliedLeft=rotation.left;rotation.appliedRight=rotation.right
    end
    local demand=baseDemand();local base=math.floor(demand+1e-8)
    nav.boostApplied=nav.active and demand-nav.main or 0
    local recovering={roll=roll,pitch=pitch,rateR=rateR,rateP=rateP,recovery=recovery.active}
    zoneState,thrustState=mixStep(mixer,r,p,base,dt,armed,recovering,demand)
    local red={[12]={},[13]={}}
    for _,id in ipairs({16,17,18,19}) do
      local z=FINE[id].zone;local v=zoneState[z]
      send(id,{kind='OUTPUT',disabled=not armed,session=session,seq=sequence,values=v.fineLevels})
      for n,map in pairs(SIDES) do
        for side,key in pairs(map) do
          if key==z..'s' then red[n][side]=v.sub elseif key==z..'m' then red[n][side]=v.main end
        end
      end
    end
    for _,id in ipairs({12,13}) do send(id,{kind='OUTPUT',session=session,seq=sequence,values=red[id]}) end
    send(14,{kind='OUTPUT',session=session,seq=sequence,values=rotationValues(rotation.enabled and (rotation.appliedLeft or rotation.left) or 0,rotation.enabled and (rotation.appliedRight or rotation.right) or 0)})
  end
  local function loop()
    bind()
    while true do
      local tickTimer=os.startTimer(CFG.tick)
      local ok,g=pcall(peripheral.call,CFG.sensor,'getGravity')
      local good,r,p,a,t=pcall(function()
        assert(ok,'Sensor read failed: '..tostring(g))
        return geometry(g,axis)
      end)
      local now=os.clock()
      local dt=lastTick and now-lastTick or CFG.tick
      lastTick=now;interval=dt
      sensorOK=good;sensorError=not good and tostring(r) or nil
      local presentOK,present=pcall(peripheral.isPresent,CFG.sensor)
      sensorPresent=presentOK and present or good
      if good then
        roll,pitch,axis,tilt=r,p,a,t;rawGravity=g;sensorTime=os.epoch('utc');lastRead=now
        if prev and dt>0 and dt<0.5 then
          rateR=0.6*rateR+0.4*clamp((r-prev[1])/dt,-180,180)
          rateP=0.6*rateP+0.4*clamp((p-prev[2])/dt,-180,180)
        else rateR=0;rateP=0 end
        prev={r,p}
      else faultText=tostring(r);stop('FAULT') end
      local connected,why,transient=ready()
      local maintenance=maintenanceAllowed()
      if maintenance then
        if connected then
          local zero,complete=true,true
          for _,id in ipairs(IDS)do local count=0;for _,v in pairs(health[id].applied or {})do count=count+1;if not finite(v) or v~=0 then zero=false end end;if count~=(FINE[id] and health[id].fineCount or 4) then complete=false end end
          if not complete then connected=false;transient=true;why='Maintenance output reports pending' end
          if not zero then connected=false;transient=false;why='Maintenance output zero not confirmed' end
        end
        if not connected then
          maintenanceSince=nil;maintenanceFrames=0
          maintenanceMissing=maintenanceMissing or now
          if not transient or now-maintenanceMissing>=4 then faultText=why;stop('FAULT') end
        else maintenanceMissing=nil;maintenanceSince=maintenanceSince or now end
      else
        maintenanceSince=nil;maintenanceMissing=nil;maintenanceFrames=0
        if not connected and (armed or rotation.enabled or now-checkStart>3) then faultText=why;stop('FAULT') end
      end
      if (armed or rotation.enabled) and now-uiSeen>CFG.commandTimeout then faultText='UI connection lost';stop('FAULT') end
      if (armed or rotation.enabled) and dt>CFG.nodeTimeout then faultText='Control stalled';stop('FAULT') end
      if not faultText then
        state=armed and (recovery.active and 'RECOVERY' or 'LEVEL') or (connected and good and 'READY / OFF' or 'CHECKING')
      end
      sequence=sequence+1
      local _,motionChanged=attitudeMotionStep(attitudeMotion,velocityValues(velocityPacket,os.epoch('utc')),nav.actual,nav.gps,rotation,armed,os.epoch('utc'))
      if motionChanged then emitLog('ATTITUDE','DEADZONE_MODE',{mode=attitudeMotion.mode,deadzone=attitudeMotion.deadzone,speed=attitudeMotion.speed,source=attitudeMotion.source})end
      local cr,cp=axisDemand(roll,rateR),axisDemand(pitch,rateP)
      if armed and not faultText then
        recoveryStep(recovery,roll,pitch,rateR,rateP,tilt,math.min(dt,0.2),now)
        if recovery.active then
          state='RECOVERY';cr,cp=recoveryDemand(recovery,roll,pitch,rateR,rateP,math.min(dt,0.2))
          rotation.left=0;rotation.right=0
          if nav.active then
            if landingStage(nav.stage) or nav.landing then pauseLanding(nav,'Landing HOLD: RECOVERY',navFix) else nav.stage='ALTITUDE' end
            if nav.commandMode=='TEST' then finishTest(nav,'RECOVERY safety abort',true);nav.commandMode='HOVER';if navFix then nav.target={x=navFix.x,y=navFix.y,z=navFix.z};nav.holdY=navFix.y end;nav.hoverBraked=false;nav.manualCommon=nil end
            resetCruise(nav);nav.state='RECOVERY';nav.turnBoost=0;nav.turnAngle=0;nav.yawAligned=false;nav.course=nil;nav.courseTime=nil;nav.courseTrusted=false;nav.probe=nil
          end
        end
      end
      output(cr,cp,math.min(dt,0.2))
      repeat
        local _,timer=os.pullEvent('timer')
        if timer==tickTimer then break end
      until false
    end
  end
  local function report()
    while true do
      if not armed then
        for _,id in ipairs(IDS)do local h=health[id];if not h or h.session~=session or os.clock()-(h.seen or 0)>CFG.nodeTimeout then send(id,{kind='BIND',session=session}) end end
      end
      if maintenanceAllowed() and maintenanceSince then maintenanceFrames=maintenanceFrames+1 end
      runtime(state,armed or rotation.enabled or nav.active,faultText,maintenanceAllowed() and
        {token=FLEET_MAINTENANCE.token,zero=maintenanceSince~=nil,readySince=maintenanceSince,frames=maintenanceFrames,missingSince=maintenanceMissing} or nil)
      send(11,{kind='STATUS',session=session,armed=armed,state=state,error=faultText,
        inputs=inputs,relayAge=os.clock()-relaySeen,interval=interval,main=baseMain,zones=zoneState,
        seq=sequence,version=VERSION,roles=ROLE.snapshot(),recovery={active=recovery.active,reason=recovery.reason,stable=recovery.stable,rateR=rateR,rateP=rateP},thrust=thrustState,mainCommand=math.floor(baseDemand()+1e-8),mainDemand=baseDemand(),nav=nav,deadzone=CFG.deadzone,attitudeMotion=attitudeMotion,rotation={enabled=rotation.enabled,left=rotation.enabled and (rotation.appliedLeft or rotation.left) or 0,
          right=rotation.enabled and (rotation.appliedRight or rotation.right) or 0,outputs=rotationValues(rotation.enabled and (rotation.appliedLeft or rotation.left) or 0,rotation.enabled and (rotation.appliedRight or rotation.right) or 0)},angles=sensorTime and {roll=roll,pitch=pitch,time=sensorTime},
        diagnostic={sensor=CFG.sensor,sensorOK=sensorOK,sensorError=sensorError,present=sensorPresent,
          angleOK=angleOK,angleError=angleError,gravity=rawGravity,rawAngles=rawAngles,angleTime=angleTime,
          sensorTime=sensorTime,velocity=velocityPacket,relayWarning=relayWarning,relayAge=os.clock()-relaySeen,
          relays=RELAYS,nodes=health,deadzone=CFG.deadzone}})
      sleep(0.25)
    end
  end
  local function testLogger()
    while true do
      local data=table.remove(pendingTestLogs,1)
      if data then local ok,why=pcall(function()local h=assert(fs.open('fleet_test_last.txt','w'));h.write(textutils.serialize(data));h.close()end);if not ok then data.summary.logError=tostring(why) end end
      sleep(0.25)
    end
  end
  local function navigation()
    local lastNavClock=os.clock()
    while true do
      local navDt=clamp(os.clock()-lastNavClock,0,0.2);lastNavClock=os.clock()
      local pose=yawPose(health,nav.target,os.epoch('utc'),yawTrack,navFix,{tilt=tilt,gravity=rawGravity});nav.yaw=pose
      nav.velocity=velocityValues(velocityPacket,os.epoch('utc'))
      nav.limits={forward=VELCFG.forwardLimit,reverse=VELCFG.reverseLimit,cruise=VELCFG.cruiseSpeed}
      nav.gps=navGPSState(gpsTrack,os.epoch('utc'));nav.gpsAge=navFix and (os.epoch('utc')-navFix.time)/1000 or nil
      nav.gpsFailures=gpsTrack.failures or 0;nav.yawSign=NAVCFG.yawSign;nav.probeAngle=NAVCFG.probeVector
      if navFix and nav.gps=='FIX' then nav.actual=navMetrics(nav.target or navFix,navFix,navPrevious)
      else nav.actual=nil end
      if nav.active then
        local wall=os.epoch('utc')/1000
        if nav.mode~='YAW' and nav.stage=='TURN' and nav.turnUntil and wall>=nav.turnUntil then
          rotation={enabled=true,left=0,right=0};navHold(nav,'Turn complete: stabilize and recheck course')
        elseif nav.stage=='PROBE' and nav.probe and wall-nav.probe.time>=NAVCFG.probeSeconds then
          rotation={enabled=true,left=0,right=0}
        end
        if os.clock()-pilotSeen>NAVCFG.uiTimeout then cancelNav('NAV CANCELLED','15 UI link lost')
        elseif navGPSState(gpsTrack,os.epoch('utc'))=='LOST' then cancelNav('NAV GPS LOST','Last good GPS FIX exceeded gpsTimeout')
        elseif not armed or not sensorOK or faultText then cancelNav('NAV FAULT',faultText or sensorError or 'Flight control unavailable')
        elseif navGPSState(gpsTrack,os.epoch('utc'))=='DEGRADED' then
          suspendGPS(nav);rotation={enabled=true,left=0,right=0}
          if nav.landing and finite(nav.velocity.vertical) then
            nav.verticalSpeed=nav.velocity.vertical;nav.targetVy=0
            local hold=clamp(NAVCFG.hoverMain-LANDCFG.velocityGain*nav.verticalSpeed,NAVCFG.hoverMain,NAVCFG.maxMain)
            nav.main=nav.main+clamp(hold-nav.main,0,LANDCFG.brakeRise*navDt)
          end
        elseif nav.mode=='YAW' and not pose.valid and (nav.stage=='YAW_TURN' or nav.stage=='CRUISE') then
          nav.mode='COURSE';nav.yawInvalidHeld=true;navHold(nav,'YAW DEGRADED: HOLD before course fallback');rotation={enabled=true,left=0,right=0}
        elseif navFixTime~=navFix.time or nav.velocity.source=='SENSOR' then
          nav.gpsPaused=false
          local dt=nav.velocity.source=='SENSOR' and navDt or navFixTime and math.min(5,(navFix.time-navFixTime)/1000) or 0
          navFixTime=navFix.time
          local l,r=navStep(nav,navFix,navPrevious,{recovery=recovery.active,tilt=tilt,rate=math.max(math.abs(rateR),math.abs(rateP)),yaw=pose,velocity=nav.velocity,now=os.epoch('utc')},dt)
          if nav.active then rotation={enabled=true,left=l,right=r}
          else rotation={enabled=false,left=0,right=0} end
        elseif (not nav.commandMode or nav.commandMode=='CRUISE') and nav.mode=='YAW' and pose.valid and not recovery.active and (nav.stage=='YAW_TURN' or nav.stage=='CRUISE') then
          local l,r=yawCommand(nav,pose,navDt,os.epoch('utc'));rotation={enabled=true,left=l,right=r}
        end
      end
      nav.directionDiagnostics=directionDiagnostics(nav,rotation,os.epoch('utc'),directionTrack)
      sleep(0.1)
    end
  end
  local function angleReader()
    while true do
      local ok,a=pcall(peripheral.call,CFG.sensor,'getAngles')
      angleOK=ok and validArray(a,2);angleError=not angleOK and tostring(a) or nil
      if angleOK then rawAngles=a;angleTime=os.epoch('utc') end
      sleep(0.25)
    end
  end
  local function keyboard()
    while true do
      local _,k=os.pullEvent('key')
      if k==keys.space then stop('STOPPED') elseif k==keys.q then return end
    end
  end
  local ok,err=pcall(function() parallel.waitForAny(loop,receiver,report,angleReader,navigation,keyboard,managedStop,gpsReader,roleWorker,testLogger,logSender) end)
  stop('STOPPED');stopWire()
  if not ok then
    if FLEET_RUN then os.queueEvent('fleet_run_error',os.getComputerID(),tostring(err),FLEET_RUN) end
    print(tostring(err))
  end
end
local function ui()
  local stopWire=wiring()
  local status,received=nil,nil
  local enabled,main=false,0
  local session,seq=nil,0
  local rotation={enabled=false,left=0,right=0}
  local relaySequence=0
  local relayError
  local blackbox=newBlackbox()
  local localClient='11:'..uid()
  local radioOwned={}
  local logOwned={}
  local function gpsReader()
    bodyGPS(11,function(g)if session then send(10,{kind='BODY_GPS',session=session,gps=g}) end end)
  end
  local function velocityReader()
    local values={}
    local tasks={}
    for i,role in ipairs({'lateral','forward','vertical'}) do
      local name,r='velocity_sensor_'..i,role
      tasks[#tasks+1]=function()while true do
        local ok,value=pcall(peripheral.call,name,'getVelocity')
        local stamp=os.epoch('utc')
        local axisOK,axis=pcall(peripheral.call,name,'getAxis')
        values[r]={ok=ok and finite(value),value=ok and finite(value) and value*VELCFG[r..'Sign'] or nil,
          error=not ok and tostring(value):sub(1,200) or not finite(value) and 'Invalid velocity value' or nil,
          axis=axisOK and tostring(axis):sub(1,20) or '?',time=stamp,sensor=name}
        sleep(VELCFG.pollSeconds)
      end end
    end
    tasks[#tasks+1]=function()while true do
      if session then send(10,{kind='VELOCITY',session=session,values=values}) end
      sleep(VELCFG.pollSeconds)
    end end
    parallel.waitForAll(table.unpack(tasks))
  end
  local function command()
    if session then send(10,{kind='HEARTBEAT',session=session}) end
  end
  local function pilot(action,client,number,target)
    if not session then return end
    if not client then seq=seq+1;client=localClient;number=seq end
    blackbox.event('EVENT','PILOT_REQUEST',{action=action,client=client,seq=number,target=target})
    send(10,{kind='PILOT',session=session,client=client,seq=number,action=action,target=target})
  end
  local function transmit(channel,m)
    for _,side in ipairs(redstone.getSides()) do
      if peripheral.hasType(side,'modem') then
        local ok,radio=pcall(peripheral.call,side,'isWireless')
        if ok and radio then pcall(peripheral.call,side,'transmit',channel,channel,m) end
      end
    end
  end
  local function radioLoop()
    while true do
      for _,side in ipairs(redstone.getSides()) do
        if peripheral.hasType(side,'modem') then
          local ok,radio=pcall(peripheral.call,side,'isWireless')
          if ok and radio then
            local good,opened=pcall(peripheral.call,side,'isOpen',UI_CHANNEL)
            if good and not opened then
              if pcall(peripheral.call,side,'open',UI_CHANNEL) then radioOwned[side]=true end
            end
          end
        end
      end
      sleep(1)
    end
  end
  local function remote()
    while true do
      local _,side,channel,reply,m=os.pullEvent('modem_message')
      local ok,radio=pcall(peripheral.call,side,'isWireless')
      if ok and radio and channel==UI_CHANNEL and fresh(m,2000) and m.protocol=='fleet_ui_v1' and m.source==15 then
        if m.action=='STOP' or m.action=='MOTION_STOP' or m.action=='ADMIN_STOP' or m.action=='TEST_ABORT' then pilot(m.action,m.client,m.seq)
        elseif m.session==session then
          if m.kind=='GPS' then send(10,{kind='NAV_FIX',session=session,fix=m.fix,pilotTime=m.time})
          elseif m.kind=='PILOT' and type(m.client)=='string' and #m.client<=100 and finite(m.seq) then
            pilot(m.action,m.client,m.seq,m.target)
          end
        end
      end
    end
  end
  local function off()
    rotation={enabled=false,left=0,right=0}
    enabled=false;main=0;send(10,{kind='STOP'});command()
  end
  local function lines()
    if not status then return {'Waiting for computer 10...'} end
    local v=status.inputs or {left=0,right=0,front=0,back=0}
    local out={status.state,string.format('Relay L:%d R:%d F:%d B:%d',v.left,v.right,v.front,v.back),
      string.format('Loop: %.0f ms  Input age: %.0f ms',status.interval*1000,status.relayAge*1000),
      string.format('Sensor control / tolerance +/-%.1f deg',status.deadzone or 1),'Main base: '..main}
    for _,z in ipairs({'LF','RF','LB','RB'}) do
      local v=status.zones[z]
      if v then out[#out+1]=string.format('%s demand %.1f fine %.1f sub %d main %d',z,v.signal,v.fine,v.sub,v.main) end
    end
    if status.error then out[#out+1]=status.error end
    if relayError then out[#out+1]=relayError end
    out[#out+1]='A:auto W/S:main SPACE:stop R:check Q:exit'
    out[#out+1]=string.format('ROT %s L:%d R:%d deg',rotation.enabled and 'ON' or 'OFF',rotation.left,rotation.right)
    out[#out+1]='T:rot J/L:left K/I:right N:down (6 deg)'
    out[#out+1]='Altitude hold: not connected'
    return out
  end
  local function receiver()
    while true do
      local from,m=receiveFlight(PROTO)
      if from==10 and fresh(m,1000) and m.kind=='PILOT_ACK' then
        blackbox.event('EVENT','PILOT_ACK',{client=m.client,seq=m.seq,ok=m.ok,reason=m.reason})
        transmit(ACK_CHANNEL,{protocol='fleet_ack_v1',source=11,ack=m,time=os.epoch('utc')})
      elseif from==10 and fresh(m,1000) and m.kind=='STATUS' and type(m.session)=='string' then
        if session~=m.session then enabled=false;main=0;seq=0;session=m.session;rotation={enabled=false,left=0,right=0} end
        status=m;received=os.clock();enabled=m.armed==true;main=m.main or 0
        if m.rotation then rotation=m.rotation end
        if m.error or m.state=='STOPPED' then enabled=false;main=0;rotation={enabled=false,left=0,right=0} end
        blackbox.safeObserve(m)
      end
    end
  end
  local function blackboxRadio()
    local lastScan=-math.huge
    if not blackbox.config.enabled then while true do sleep(60)end end
    while true do
      if os.clock()-lastScan>=1 then lastScan=os.clock();pcall(function()for _,side in ipairs(redstone.getSides())do if peripheral.hasType(side,'modem')then
        if not peripheral.call(side,'isOpen',LOG_CHANNEL)then peripheral.call(side,'open',LOG_CHANNEL);logOwned[side]=true end
      end end end)end
      local e,side,ch,reply,m=os.pullEventRaw()
      if e=='fleet_blackbox_admin' and side==ROLE.actual then pcall(blackbox.accept,ch)end
      if e=='modem_message' then
        pcall(function()
          if ch==LOG_CHANNEL then blackbox.accept(m)
          elseif (ch==42615 or ch==42616) and type(m)=='table' and m.magic=='fleet_admin_v1' and m.key==setting('fleet.admin_key','') and fresh(m,10000)
            and type(m.rid)=='string' and #m.rid<=120 and type(m.op)=='string' and type(m.body)=='table'then
            local body=m.body;local key='admin:'..m.rid..':'..m.op..':'..tostring(body.state)
            if not blackbox.seen[key] and m.op~='FILE_CHUNK' and (m.op~='RESULT' or body.state~='RECEIVED')then
              blackbox.seen[key]=os.clock();local info=body.info or {}
              blackbox.event('ADMIN',m.op,{from=m.from,to=m.to,rid=m.rid,state=body.state,detail=body.detail,token=body.token,
                version=info.adminVersion,running=info.runningCode,files=info.files},body.state=='FAILED')
            end
          end
        end)
      end
    end
  end
  local function relayReader()
    while true do
      local timer=os.startTimer(CFG.tick)
      local sample,sampleError={},nil
      local tasks={}
      for direction,name in pairs(RELAYS) do
        local d,n=direction,name
        tasks[#tasks+1]=function()
          local ok,value=pcall(peripheral.call,n,'getAnalogInput','front')
          if ok and finite(value) and value>=0 and value<=15 and value%1==0 then sample[d]=value
          else sampleError='Relay read failed: '..n end
        end
      end
      parallel.waitForAll(table.unpack(tasks))
      relayError=sampleError
      if session then
        relaySequence=relaySequence+1
        if sampleError then send(10,{kind='RELAY_ERROR',session=session,error=sampleError})
        else send(10,{kind='RELAY',session=session,seq=relaySequence,inputs=sample}) end
      end
      repeat
        local _,t=os.pullEvent('timer')
        if t==timer then break end
      until false
    end
  end
  local function heartbeat()
    while true do
      if received and os.clock()-received>2 then off() end
      command();sleep(0.5)
    end
  end
  local function diagnostics()
    local d=status.diagnostic or {}
    local a=status.angles or {}
    local out={'CONTROL: '..tostring(d.sensor or 'unknown')..' / gravity',
      finite(a.roll) and finite(a.pitch) and string.format('Control R %.2f P %.2f / tolerance %.1f deg',a.roll,a.pitch,status.deadzone or 1) or 'Control R/P: NO DATA'}
    out[#out+1]='Sensor '..(d.present and 'PRESENT' or 'MISSING')..' / '..(d.sensorOK and 'READ OK' or 'READ FAILED')
    if d.sensorError then out[#out+1]=tostring(d.sensorError):sub(1,160) end
    if d.sensorTime then out[#out+1]=string.format('Last gravity age: %.2fs',(os.epoch('utc')-d.sensorTime)/1000) end
    local function add(v) out[#out+1]=v end
    if d.gravity then add(string.format('Raw gravity: %.3f %.3f %.3f',table.unpack(d.gravity))) end
    if d.rawAngles then
      add(string.format('Raw angles: %.2f %.2f (age %.2fs)',d.rawAngles[1],d.rawAngles[2],
        (os.epoch('utc')-(d.angleTime or 0))/1000))
    else add('Raw angles: NO DATA') end
    if d.angleOK==false then add('Raw angle read: FAILED') end
    local r,p=a.roll or 0,a.pitch or 0
    local deadzone=status.deadzone or 1
    if d.sensorOK and fresh(a,500) then add('Lift: '..(r>deadzone and 'RIGHT' or r< -deadzone and 'LEFT' or 'L/R OK')..' / '..
      (p>deadzone and 'FRONT' or p< -deadzone and 'BACK' or 'F/B OK')) else add('Lift: UNKNOWN / STALE') end
    add('Relay comparison only: lamp = LOW side')
    for _,key in ipairs({'front','back','left','right'}) do
      local valid=(d.relayAge or math.huge)<=0.5 and not d.relayWarning
      add(string.format('%s %s: %s',key,(d.relays or {})[key] or '?',
        valid and tostring(status.inputs[key]) or 'STALE / UNKNOWN'))
    end
    if d.relayWarning then add(d.relayWarning) end
    local function values(v)
      if type(v)~='table' then return '?' end
      local text={}
      for i=1,math.min(8,#v) do text[i]=finite(v[i]) and string.format('%.0f',v[i]*100) or '?' end
      return table.concat(text,' ')..' %'
    end
    local nodes=d.nodes or {}
    local function recent(n) return n and n.ok and fresh(n,1000) end
    for _,id in ipairs({16,17,18,19}) do
      local z=FINE[id].zone;local cmd=status.zones[z]
      local sideId=(z=='LF' or z=='LB') and 12 or 13
      local n,fineNode=nodes[sideId],nodes[id]
      local mainValue,subValue='?','?'
      if recent(n) and type(n.applied)=='table' then
        for side,key in pairs(SIDES[sideId]) do
          if key==z..'m' then mainValue=tostring(n.applied[side] or '?') end
          if key==z..'s' then subValue=tostring(n.applied[side] or '?') end
        end
      end
      add(z..' M'..MAIN_COUNT..'/S'..SUB_COUNT..'/Fine '..tostring(fineNode and fineNode.fineCount or '?')..' commands -> reports')
      add(string.format(' M %s -> %s / S %s -> %s',cmd and cmd.main or '?',mainValue,cmd and cmd.sub or '?',subValue))
      add(' Fine cmd: '..values(cmd and cmd.fineLevels))
      add(' Fine set: '..values(recent(fineNode) and fineNode.applied or nil))
    end
    add('Tcmd = COMMAND-EQUIVALENT; NOT measured thrust')
    local t=status.thrust
    if t then
      add(string.format('Sum %.3f / goal %.3f / paired %.3f',t.total or 0,t.targetTotal or 0,t.paired or 0))
      add(string.format('Unpaired %.3f / saturation %.3f',t.unpaired or 0,t.saturated or 0))
      if t.headroomLimited then add('HEADROOM LIMITED: net lift increase possible') end
    end
    for _,z in ipairs({'LF','RF','LB','RB'}) do
      local v=status.zones[z]
      if v then
        add(string.format('%s %s T %.3f -> %.3f',z,v.phase or '?',v.total or 0,v.target or 0))
        add(string.format(' Assist %s / rise blocked %s / close %.2f deg/s',tostring(v.assist==true),tostring(v.mainSuppressed==true),v.closing or 0))
        add(string.format(' Saturation hold %.2fs / %.2fs',v.mainHold or 0,THRUST.mainDelay))
      end
    end
    local nav=status.nav or {};local y=nav.yaw or {}
    add('BOW: 12 LEFT -> 13 RIGHT, perpendicular X/Z; Fine GPS unused')
    add('RAW YAW '..tostring(y.rawYaw)..' / offset '..tostring(y.offset)..' / baseline '..tostring(y.baseline))
    add('CORE fleet.bow_sign=1/-1; RAW +1; optional fleet.bow_offset')
    local vel=nav.velocity or {}
    add('VEL 1 lateral '..tostring(vel.lateral)..' / 2 forward '..tostring(vel.forward)..' / 3 vertical '..tostring(vel.vertical))
    add('Axes diagnostic ONLY: '..tostring(vel.lateralAxis)..' / '..tostring(vel.forwardAxis)..' / '..tostring(vel.verticalAxis))
    add('LOW SPEED '..VELCFG.cruiseSpeed..' / LIMIT +50 -30 / '..tostring(nav.velocityState or nav.speedGuard or 'IDLE'))
    add(string.format('DIRECTION LOCK %s / target F %.2f / demand %.2f / vector %s',tostring(nav.directionLock==true),nav.targetForward or 0,nav.cruiseDemand or 0,tostring(nav.cruiseVector or 0)))
    add(string.format('BRAKE %.1fb / decel %.3f / %s / lateral %s',nav.brakingDistance or 0,nav.deceleration or VELCFG.deceleration,nav.brakeConfidence or 'CONFIG / UNVERIFIED',nav.lateralState or '?'))
    add('YAW axes: 0=X+, +90=Z+, +/-180=X-, -90=Z-')
    add('YAW '..tostring(y.valid==true)..' / '..tostring(y.reason)..' / FIXES '..tostring(y.fixes or 0))
    if y.valid then
      add(string.format('Bow %.2f / target %s / error %s / rate %s',y.yaw,tostring(y.targetYaw),tostring(y.error),y.rateValid and tostring(y.rate) or 'FIRST FRAME'))
      add(string.format('LEFT 12 X/Z %.2f %.2f / RIGHT 13 %.2f %.2f',y.left.x,y.left.z,y.right.x,y.right.z))
      add(string.format('Center %.2f %.2f %.2f / baseline %.2f / skew %.3fs',y.center.x,y.center.y,y.center.z,y.baseline,y.skew))
    end
    add(string.format('TURN %s / boost %.2f command base; LEVEL has priority',nav.turnDirection or 'NONE',nav.boostApplied or 0))
    if nav.landing then add('LANDING '..tostring(nav.landingPhase)..' VY '..tostring(nav.verticalSpeed)..' -> '..tostring(nav.targetVy));add('Target GPS Y offset '..LANDCFG.yOffset..'; no ground contact sensing') end
    local logs=blackbox.status();add('BLACKBOX 11 '..(logs.enabled and 'ON' or 'OFF')..' queued '..logs.queued..' dropped '..logs.dropped)
    if logs.error then add('LOG WARNING '..logs.error:sub(1,120))end
    add('Reports = successful writes, NOT measured thrust')
    add('Node reports may lag commands by 0.25s+')
    return out
  end
  local function nodeReports()
    local reports={}
    for id,n in pairs((status.diagnostic or {}).nodes or {}) do
      reports[id]={time=n.time,ok=n.ok,state=n.state,error=n.error,version=n.version,applied=n.applied,gps=n.gps,localSensors=n.localSensors,fineCount=n.fineCount,fineNames=n.fineNames,role=n.role,actualId=n.actualId}
    end
    reports[10]={actualId=status.roles and status.roles.map.CORE,role='CORE',time=status.time,ok=not status.error,state=status.state,error=status.error,version=status.version,gps=reports[10] and reports[10].gps}
    reports[11]={actualId=status.roles and status.roles.map.SENSOR_UI,role='SENSOR_UI',time=os.epoch('utc'),ok=true,state='UI / RELAY',error=relayError,version=VERSION,gps=reports[11] and reports[11].gps}
    return reports
  end
  local function display()
    while true do
      runtime('UI / RELAY',enabled or rotation.enabled or (status and status.nav and status.nav.active)==true,relayError)
      local text=lines()
      local lost=not received or os.clock()-received>2
      term.clear();term.setCursorPos(1,1)
      print('FLEET UI 11'..(lost and ' / NO SIGNAL' or ''))
      for _,s in ipairs(text) do print(s) end
      if not lost then
        for _,side in ipairs(redstone.getSides()) do
          if peripheral.hasType(side,'modem') then
            local ok,wireless=pcall(peripheral.call,side,'isWireless')
            if ok and wireless then
              pcall(peripheral.call,side,'transmit',42110,42110,{protocol='ship_status_v1',source=10,relay=11,
                state={result=status.state,stages={'--','--','--'},radio='VIA 11',cycle=status.seq,lines=text},
                telemetry={version=1,session=status.session,seq=status.seq,time=status.time,state=status.state,
                  inputs=status.inputs,relayAge=status.relayAge,zones=status.zones,error=status.error or relayError,angles=status.angles,diagnosticLines=diagnostics(),thrust=status.thrust,nodes=nodeReports(),rotation=status.rotation,
                  blackbox=blackbox.status(),roles=status.roles,nav=status.nav,recovery=status.recovery,main=status.main,mainCommand=status.mainCommand,mainDemand=status.mainDemand,armed=status.armed,deadzone=status.deadzone,sensor={name=(status.diagnostic or {}).sensor,present=(status.diagnostic or {}).present,ok=(status.diagnostic or {}).sensorOK,
                    time=(status.diagnostic or {}).sensorTime,error=(status.diagnostic or {}).sensorError}}})
            end
          end
        end
      end
      sleep(0.25)
    end
  end
  local function keyboard()
    local actionKeys={[keys.a]='ARM',[keys.w]='MAIN_UP',[keys.s]='MAIN_DOWN',[keys.r]='RECHECK',
      [keys.j]='LEFT_DOWN',[keys.l]='LEFT_UP',[keys.k]='RIGHT_DOWN',[keys.i]='RIGHT_UP',[keys.n]='VECTOR_ZERO'}
    while true do
      local _,k,held=os.pullEvent('key')
      if k==keys.space then pilot('STOP')
      elseif k==keys.q then off();return
      elseif not held and k==keys.t then pilot(rotation.enabled and 'VECTOR_OFF' or 'VECTOR_ON')
      elseif not held and actionKeys[k] then pilot(actionKeys[k]) end
    end
  end
  local ok,err=pcall(function() parallel.waitForAny(receiver,relayReader,heartbeat,display,keyboard,radioLoop,remote,managedStop,gpsReader,velocityReader,roleWorker,blackbox.worker,blackboxRadio) end)
  blackbox.event('SYSTEM','BLACKBOX_STOP',{reason='SENSOR_UI stopped'},true);pcall(blackbox.flush)
  off();stopWire()
  for side in pairs(logOwned)do pcall(peripheral.call,side,'close',LOG_CHANNEL)end
  for side in pairs(radioOwned) do pcall(peripheral.call,side,'close',UI_CHANNEL) end
  if not ok then
    if FLEET_RUN then os.queueEvent('fleet_run_error',os.getComputerID(),tostring(err),FLEET_RUN) end
    print(tostring(err))
  end
end
local id=ROLE.slot
if id==10 then controller()
elseif id==11 then ui()
elseif SIDES[id] or FINE[id] then node(id)
else print('Supported IDs: 10,11,12,13,14,16,17,18,19; ID 15: fleet_view') end
