-- SPORE
-- stochastic generative sequencer, inspired by fungal spore propagation

engine.name = "PolyPerc"

-- =========================================
-- CONSTANTS
-- =========================================
local SCREEN_W = 128
local SCREEN_H = 64
local CX = SCREEN_W / 2
local CY = SCREEN_H / 2
local GRID_W = 16
local GRID_H = 8

local SCALE_NAMES = {
  "PentaMin","PentaMaj","Dorian",
  "Lydian","Mixolyd","WholeTn","Chromat"
}
local SCALE_IV = {
  {0,3,5,7,10}, {0,2,4,7,9},
  {0,2,3,5,7,9,10}, {0,2,4,6,7,9,11},
  {0,2,4,5,7,9,10}, {0,2,4,6,8,10},
  {0,1,2,3,4,5,6,7,8,9,10,11},
}
local ROOT_N = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

-- =========================================
-- STATE
-- =========================================
local spores  = {}
local myc     = {}        -- mycelium point list {x,y,b}
local MAX_MYC = 300
local g       = nil
local mdev    = nil
local step    = 0
local paused  = false
local off_q   = {}
local m_seq   = metro.init()
local m_draw  = metro.init()

-- =========================================
-- PARAMS (read via params:get each step)
-- =========================================
local function bpm()         return params:get("bpm") end
local function scale_idx()   return params:get("scale_idx") end
local function root()        return params:get("root") end
local function oct_base()    return params:get("oct_base") end
local function oct_range()   return params:get("oct_range") end
local function spawn_prob()  return params:get("spawn_prob")/100 end
local function branch_prob() return params:get("branch_prob")/100 end
local function max_spores()  return params:get("max_spores") end
local function lifetime()    return params:get("lifetime") end
local function myc_decay()   return params:get("myc_decay")/100 end
local function use_midi()    return params:get("use_midi") == 2 end
local function midi_ch()     return params:get("midi_ch") end

-- =========================================
-- HELPERS
-- =========================================
local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function midi_hz(n)     return 440*(2^((n-69)/12)) end

local function pick_note()
  local iv   = SCALE_IV[scale_idx()]
  local pool = {}
  for o=0,oct_range() do
    for _,i in ipairs(iv) do
      local n=(oct_base()+o)*12+root()+i
      if n>=0 and n<=127 then pool[#pool+1]=n end
    end
  end
  if #pool==0 then return 60 end
  return pool[math.random(#pool)]
end

-- =========================================
-- AUDIO / MIDI
-- =========================================
local function note_on(note,vel)
  engine.hz(midi_hz(note))
  engine.amp(clamp(vel/127,0,1)*0.8)
  if use_midi() and mdev then
    mdev:note_on(note,vel,midi_ch())
    off_q[#off_q+1]={note=note,t=2}
  end
end

local function note_off(note)
  if mdev then mdev:note_off(note,0,midi_ch()) end
end

local function flush_off_q()
  for i=#off_q,1,-1 do
    off_q[i].t=off_q[i].t-1
    if off_q[i].t<=0 then
      note_off(off_q[i].note)
      table.remove(off_q,i)
    end
  end
end

local function all_off()
  for _,q in ipairs(off_q) do note_off(q.note) end
  off_q={}
  if mdev then
    for ch=1,16 do for n=0,127 do mdev:note_off(n,0,ch) end end
  end
end

-- =========================================
-- SPORE SYSTEM
-- =========================================
local function new_spore(x,y,parent)
  local angle
  if parent then
    local sp=math.pi*(0.3+math.random()*0.5)
    angle=parent.angle+(math.random()>0.5 and sp or -sp)
  else
    angle=math.random()*math.pi*2
  end
  local spd=0.6+math.random()*0.6
  return {
    x=x or CX, y=y or CY,
    vx=math.cos(angle)*spd,
    vy=math.sin(angle)*spd,
    angle=angle, spd=spd,
    note=pick_note(),
    gen=parent and (parent.gen+1) or 0,
    age=0,
    max_age=math.max(4,lifetime()+math.random(6)-3),
    bri=15,
    tx={}, ty={},
  }
end

local function burst(x,y,n)
  x=x or CX; y=y or CY; n=n or 4
  local added=0
  while added<n and #spores<max_spores() do
    spores[#spores+1]=new_spore(x,y,nil)
    added=added+1
  end
end

-- =========================================
-- STEP
-- =========================================
local function do_step()
  if paused then return end
  flush_off_q()
  if #spores==0 then burst(CX,CY,3) end

  local born={}
  step=(step%64)+1

  for i=#spores,1,-1 do
    local sp=spores[i]
    sp.age=sp.age+1

    sp.vx=sp.vx+(math.random()-0.5)*0.1
    sp.vy=sp.vy+(math.random()-0.5)*0.1
    local mag=math.sqrt(sp.vx*sp.vx+sp.vy*sp.vy)
    if mag>0.01 then sp.vx=sp.vx/mag*sp.spd; sp.vy=sp.vy/mag*sp.spd end
    sp.angle=math.atan(sp.vy,sp.vx)
    sp.x=sp.x+sp.vx
    sp.y=sp.y+sp.vy

    -- trail shift (fixed 4-slot array)
    sp.tx[4]=sp.tx[3]; sp.ty[4]=sp.ty[3]
    sp.tx[3]=sp.tx[2]; sp.ty[3]=sp.ty[2]
    sp.tx[2]=sp.tx[1]; sp.ty[2]=sp.ty[1]
    sp.tx[1]=sp.x;     sp.ty[1]=sp.y

    local vel=clamp(math.floor(50+(1-sp.age/sp.max_age)*77),1,127)
    note_on(sp.note,vel)

    sp.bri=math.max(1,math.floor(15*(1-sp.age/sp.max_age)))

    -- deposit mycelium point
    if #myc<MAX_MYC then
      myc[#myc+1]={x=math.floor(sp.x),y=math.floor(sp.y),b=6}
    end

    if math.random()<branch_prob() and (#spores+#born)<max_spores() and sp.gen<4 then
      born[#born+1]=new_spore(sp.x,sp.y,sp)
    end

    if sp.age>=sp.max_age or math.random()<0.04*(sp.age/sp.max_age) then
      table.remove(spores,i)
    end
  end

  for _,ns in ipairs(born) do spores[#spores+1]=ns end

  if math.random()<spawn_prob()*0.08 and #spores<max_spores() then
    spores[#spores+1]=new_spore(CX+(math.random()-0.5)*4,CY+(math.random()-0.5)*4,nil)
  end

  -- mycelium decay every 8 steps
  if step%8==0 then
    local dec=myc_decay()
    for i=#myc,1,-1 do
      myc[i].b=myc[i].b*dec
      if myc[i].b<0.5 then table.remove(myc,i) end
    end
  end
end

-- =========================================
-- GRID
-- =========================================
local function refresh_grid()
  if not g then return end
  local L={}
  for y=1,GRID_H do
    L[y]={}
    for x=1,GRID_W do L[y][x]=0 end
  end

  for _,sp in ipairs(spores) do
    local gx=clamp(math.floor(sp.x/SCREEN_W*GRID_W)+1,1,GRID_W)
    local gy=clamp(math.floor(sp.y/SCREEN_H*(GRID_H-1))+1,1,GRID_H-1)
    if L[gy][gx]<sp.bri then L[gy][gx]=sp.bri end
    for k=1,4 do
      if sp.tx[k] then
        local tx=clamp(math.floor(sp.tx[k]/SCREEN_W*GRID_W)+1,1,GRID_W)
        local ty=clamp(math.floor(sp.ty[k]/SCREEN_H*(GRID_H-1))+1,1,GRID_H-1)
        local lv=5-k
        if L[ty][tx]<lv then L[ty][tx]=lv end
      end
    end
  end

  -- row 8: BURST / CLR / PAUSE / _ / ... / MIDI-toggle
  L[8][1]=paused and 2 or 10  -- burst
  L[8][2]=5                   -- clear
  L[8][3]=paused and 15 or 3  -- pause/play
  L[8][15]=use_midi() and 15 or 2  -- midi

  for y=1,GRID_H do
    for x=1,GRID_W do g:led(x,y,L[y][x]) end
  end
  g:refresh()
end

local function grid_key(x,y,z)
  if z~=1 then return end
  if y<GRID_H then
    if not paused and #spores<max_spores() then
      local sx=clamp(math.floor((x-0.5)/GRID_W*SCREEN_W),1,SCREEN_W)
      local sy=clamp(math.floor((y-0.5)/(GRID_H-1)*SCREEN_H),1,SCREEN_H)
      burst(sx,sy,3)
    end
  else
    if     x==1  then if not paused then burst(CX,CY,5) end
    elseif x==2  then all_off(); spores={}; myc={}
    elseif x==3  then paused=not paused; if paused then all_off() end
    elseif x==15 then
      local v=params:get("use_midi")
      params:set("use_midi", v==1 and 2 or 1)
    end
  end
end

-- =========================================
-- REDRAW
-- =========================================
function redraw()
  screen.clear()

  -- mycelium
  for _,p in ipairs(myc) do
    local lv=clamp(math.floor(p.b*0.5),0,3)
    if lv>0 then
      screen.level(lv)
      screen.pixel(p.x,p.y)
      screen.fill()
    end
  end

  -- spore + trail
  for _,sp in ipairs(spores) do
    for k=1,4 do
      if sp.tx[k] then
        local lv=math.floor((5-k)/4*sp.bri*0.4)
        if lv>0 then
          screen.level(lv)
          screen.pixel(math.floor(sp.tx[k]),math.floor(sp.ty[k]))
          screen.fill()
        end
      end
    end
    local sx=math.floor(sp.x)
    local sy=math.floor(sp.y)
    if sx>=1 and sx<=SCREEN_W and sy>=1 and sy<=SCREEN_H then
      screen.level(sp.bri)
      screen.pixel(sx,sy)
      screen.fill()
      if sp.age<=2 then
        screen.level(clamp(math.floor(sp.bri*0.3),1,15))
        screen.circle(sx,sy,2)
        screen.stroke()
      end
    end
  end

  -- origin point at center
  screen.level(2)
  screen.circle(CX,CY,1)
  screen.fill()

  screen.update()
end

-- =========================================
-- ENCODERS & KEYS
-- K1/E1 reserved by Norns (params menu / navigation)
-- K2 = Burst spores from center
-- K3 = Pause / Resume
-- E2/E3 unused (all controls in params menu)
-- =========================================
function enc(n,d)
  -- E2/E3 unassigned: handled by Norns
end

function key(n,z)
  if z~=1 then return end
  if n==2 then
    if not paused then burst(CX,CY,5) end
  elseif n==3 then
    paused=not paused
    if paused then all_off() end
  end
end

-- =========================================
-- PARAMS MENU
-- =========================================
local function init_params()
  -- TIMING
  params:add_separator("TIMING")
  params:add_number("bpm","BPM",40,240,90)
  params:set_action("bpm",function(v)
    m_seq.time=60/v/4
  end)

  -- SCALE
  params:add_separator("SCALE")
  params:add_number("scale_idx","Scale",1,#SCALE_NAMES,1)
  params:set_action("scale_idx",function() end)

  params:add_number("root","Root (semitones)",0,11,0)
  params:set_action("root",function() end)

  params:add_number("oct_base","Base octave",2,7,4)
  params:set_action("oct_base",function() end)

  params:add_number("oct_range","Octave range",1,4,2)
  params:set_action("oct_range",function() end)

  -- PROPAGATION
  params:add_separator("PROPAGATION")
  params:add_number("spawn_prob","Spawn prob %",0,100,50)
  params:set_action("spawn_prob",function() end)

  params:add_number("branch_prob","Branch prob %",0,100,30)
  params:set_action("branch_prob",function() end)

  params:add_number("max_spores","Max spores",4,48,12)
  params:set_action("max_spores",function() end)

  params:add_number("lifetime","Lifetime (step)",4,64,20)
  params:set_action("lifetime",function() end)

  params:add_number("myc_decay","Mycelium decay %",50,99,88)
  params:set_action("myc_decay",function() end)

  -- ENGINE
  params:add_separator("ENGINE")
  params:add_number("cutoff","Cutoff (Hz)",200,8000,800)
  params:set_action("cutoff",function(v) engine.cutoff(v) end)

  params:add_number("release","Release x10 (ms)",1,40,4)
  params:set_action("release",function(v) engine.release(v/10) end)

  params:add_number("pw","Pulse width %",1,99,50)
  params:set_action("pw",function(v) engine.pw(v/100) end)

  -- MIDI
  params:add_separator("MIDI")
  params:add_option("use_midi","MIDI out",{"off","on"},1)
  params:set_action("use_midi",function() end)

  params:add_number("midi_ch","MIDI channel",1,16,1)
  params:set_action("midi_ch",function() end)

  params:add_number("midi_dev","MIDI device",1,4,1)
  params:set_action("midi_dev",function(v)
    mdev=midi.connect(v)
  end)
end



-- =========================================
-- INIT
-- =========================================
function init()
  math.randomseed(os.time())

  init_params()

  engine.cutoff(800)
  engine.release(0.4)
  engine.pw(0.5)
  engine.amp(0.8)
  engine.gain(1.0)

  g=grid.connect()
  if g then g.key=grid_key; print("grid "..g.cols.."x"..g.rows) end

  mdev=midi.connect(1)

  burst(CX,CY,4)

  m_seq.time=60/params:get("bpm")/4
  m_seq.event=function()
    m_seq.time=60/params:get("bpm")/4
    do_step()
    refresh_grid()
  end
  m_seq:start()

  m_draw.time=1/15
  m_draw.event=function() redraw() end
  m_draw:start()

  print("SPORE v1.5 ready")
end

function cleanup()
  m_seq:stop()
  m_draw:stop()
  all_off()
end