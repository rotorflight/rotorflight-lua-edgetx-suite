-- A small wireframe driven by decoded MSP_ATTITUDE, never by a native getter.
-- Body axes: forward, right, up. Positive pitch lowers the nose; positive roll
-- lowers the right side, matching the Board Alignment page's attitude labels.
local M = {}
-- The side silhouette of the other drawings, given width; vertex 1 is the nose and
-- vertex 17 the right edge of the rotor disc.
local vertices = {
  {1.125,0,-0.125},{0.9,-0.28,0.575},{0.375,-0.32,0.875},{-0.65,-0.3,0.775},{-1.05,-0.18,0},
  {-0.675,-0.4,-0.275},{0.725,-0.4,-0.275},{0.9,0.28,0.575},{0.375,0.32,0.875},{-0.65,0.3,0.775},
  {-1.05,0.18,0},{-0.675,0.4,-0.275},{0.725,0.4,-0.275},{2.9,0,1.375},{2.511,1.45,1.375},{1.45,2.511,1.375},
  {0,2.9,1.375},{-1.45,2.511,1.375},{-2.511,1.45,1.375},{-2.9,0,1.375},{-2.511,-1.45,1.375},
  {-1.45,-2.511,1.375},{-0,-2.9,1.375},{1.45,-2.511,1.375},{2.511,-1.45,1.375},{0,0,0.875},{0,0,1.375},
  {-0.85,0,0.425},{-3.075,0,0.725},{-3.225,0,0.5},{-1,0,0},{-3.15,0,0.675},{-3.15,0,1.275},{-3.475,0,0.6},
  {-3.3,0,0.15},{-3.15,0,0.5},{-3,-0.2,1.125},{-3.475,-0.2,0.25},{-2.875,-0.2,0.45},{-3.575,-0.2,0.925},
  {0.825,-0.36,0.55},{0.225,-0.36,0.625},{-0.075,-0.36,0.1},{1,-0.36,0.1},{1.25,-0.55,-0.55},{1.1,-0.55,-0.7},
  {0.75,-0.55,-0.7},{0.65,-0.55,-0.275},{-0.925,-0.55,-0.7},{-0.8,-0.55,-0.275},{-1.3,-0.55,-0.7},
  {1.25,0.55,-0.55},{1.1,0.55,-0.7},{0.75,0.55,-0.7},{0.65,0.55,-0.275},{-0.925,0.55,-0.7},{-0.8,0.55,-0.275},
  {-1.3,0.55,-0.7}
}
local paths = {
  {1,2,3,4,5,6,7,1},{1,8,9,10,11,12,13,1},{3,9},{6,12},{41,42,43,44,41},{28,29,30,31},{32,33,34,35,36},
  {37,38},{39,40},{26,27},{14,15,16,17,18,19,20,21,22,23,24,25,14},{45,46,47,48,47,49,50,49,51},
  {52,53,54,55,54,56,57,56,58}
}
local thick = {3,1,1,1,2,2,2,2,2,3,2,2,1}
local accent = {false,false,false,false,true,false,false,true,true,false,true,false,false}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<10000 end
function M.new(children,w,x,y,width,height)
  local s={projected={},valid=false,readout=w.L.attitudeWaiting}
  local cx,cy=x+width/2,y+(height-22)/2
  for i=1,#vertices do s.projected[i]={0,0} end
  local function project(roll,pitch)
    local r,p=roll*math.pi/180,pitch*math.pi/180
    local cr,sr,cp,sp=math.cos(r),math.sin(r),math.cos(p),math.sin(p)
    local minX,maxX,minY,maxY=math.huge,-math.huge,math.huge,-math.huge
    local projected=s.projected
    for i=1,#vertices do
      local v=vertices[i]
      local y,z=v[2],v[3]
      local yr,zr=y*cr+z*sr,-y*sr+z*cr
      local xp,zp=v[1]*cp+zr*sp,-v[1]*sp+zr*cp
      -- Seen from behind the left side and a little above: the nose points left,
      -- as in the other drawings, and a level rotor disc reads as a level ellipse.
      local px,py=-.766*xp+.643*yr,-.94*zp-.22*xp-.262*yr
      local out=projected[i]
      out[1],out[2]=px,py
      if px<minX then minX=px end
      if px>maxX then maxX=px end
      if py<minY then minY=py end
      if py>maxY then maxY=py end
    end
    -- Fit the complete helicopter, including steep tilts, into compact displays.
    local scale=math.min((width-12)/(maxX-minX),(height-28)/(maxY-minY))
    local ox,oy=cx-scale*(minX+maxX)/2+.5,cy-scale*(minY+maxY)/2+.5
    local floor=math.floor
    for i=1,#projected do
      local out=projected[i]
      out[1]=floor(ox+scale*out[1])
      out[2]=floor(oy+scale*out[2])
    end
  end
  function s:update(d,at,time,allowed)
    local valid=allowed and d and finite(d.roll) and finite(d.pitch) and at and time>=at and time-at<=200
    self.valid=valid==true
    if not self.valid then self.readout=w.L.attitudeWaiting;return end
    if self.roll~=d.roll or self.pitch~=d.pitch then
      self.roll,self.pitch=d.roll,d.pitch
      project(d.roll,d.pitch)
      self.readout=string.format("%s %.1f°   %s %.1f°",w.L.roll,d.roll,w.L.pitch,d.pitch)
    elseif self.readout==w.L.attitudeWaiting then
      self.readout=string.format("%s %.1f°   %s %.1f°",w.L.roll,d.roll,w.L.pitch,d.pitch)
    end
  end
  -- Even hidden/stale native lines always receive valid, fixed-size point tables.
  project(0,0)
  -- A line with a points getter has no native object before its first points pass, and EdgeTX
  -- evaluates visible first: hiding it then would flag a null object. It stays visible until drawn.
  for i,path in ipairs(paths) do
    local pts,drawn={},false
    for j,index in ipairs(path) do pts[j]=s.projected[index] end
    children[#children+1]={type="line",pts=function() drawn=true;return pts end,
      visible=function() return not drawn or s.valid end,thickness=thick[i],
      color=accent[i] and w.palette.accent or w.palette.text}
  end
  children[#children+1]={type="label",x=x,y=y+height-22,w=width,h=22,font=SMLSIZE,
    color=w.palette.text,text=function() return s.readout end}
  return s
end
return M
