-- Ground selections must be silent in the general announcer as well as the overlay.
debug.getmetatable("").__index = nil
local tick, checked, files, numbers = 1000, 0, {}, {}
local function check(value, message) checked=checked+1; assert(value, message) end
getTime=function() return tick end
playFile=function(path) files[#files+1]=path end
playNumber=function(value) numbers[#numbers+1]=value end
getValue=function() return 0 end
getGeneralSettings=function() return {language="en"} end
io={open=function() return {} end, close=function() end}
local cache={}
rfsuite={session={}, preferences={audio_events={adjustment_events=true}}}
loadScript=function(path)
  return loadfile(string.gsub(path, "^/SCRIPTS/TOOLS/rfsuite%-core/", "src/rfsuite/"))
end
rfsuite.require=function(path)
  if path=="lib/log.lua" then return {wanted=function() return false end, emit=function() end} end
  if not cache[path] then cache[path]=assert(loadfile("src/rfsuite/"..path))() end
  return cache[path]
end
local Audio=rfsuite.require("lib/audio.lua")
local Teller=rfsuite.require("tasks/events/telemetry_bg/adjustments.lua")
local owner={preferences={audio_events={governor_state=false, arming_flags=false,
  model_announcement=false, voltage_alert=false, pid_profile=true, rate_profile=true}},
  state={profile=1, rateProfile=2}, audioState={initialized=true}}
local function process()
  tick=tick+1000
  Audio.process(owner)
end
process()
files, numbers={}, {}
for _, mode in ipairs({"read", "restore"}) do
  rfsuite.inflightProfileJob={mode=mode, original={pid=1,rate=2}}
  for index=2,6 do
    owner.state.profile, owner.state.rateProfile=index,index
    process(); Teller.profile(owner,index)
  end
  check(#files==0 and #numbers==0, mode.." suppresses both announcers with the surface closed")
  check(owner.audioState.lastValues.pid_profile==1 and owner.audioState.lastValues.rate_profile==2,
    "general announcer remembers the original pair")
  rfsuite.inflightProfileJob=nil
  owner.state.profile, owner.state.rateProfile=1,2
  process()
  check(#files==0 and #numbers==0, "return pair is not announced after job completion")
end
owner.state.profile=3; process()
check(#files==1 and string.find(files[1], "evt/profile.wav",1,true) and numbers[1]==3,
  "ordinary profile change is still spoken")
files,numbers={},{}
Teller.profile(owner,4)
check(#files==1 and string.find(files[1], "evt/profile.wav",1,true) and numbers[1]==4,
  "in-flight overlay profile announcement is unchanged")

-- Drive profile edges share ownership with the general announcer's preferences.
do
  local pid, rate = 1, 2
  local Drive = rfsuite.require("widgets/dashboard/inflight/drive.lua")
  local radio = {now = function() return tick end, sensor = function(name)
    if name == "PID#" then return pid elseif name == "RTE#" then return rate end
  end, setGlobalVariable = function() return true end, flightMode = function() return 0 end}
  local drive = Drive.newDrive(radio, Drive.settings({inflight={enabled=true}}, {inflight={enabled=true}}))
  drive.open = true
  drive._radioSource = owner.preferences
  drive.profile, drive.rateProfile, drive.phase, drive.live = 1, 2, "live", true
  drive.sessionProfiles = {pid={[1]=true,[2]=true,[3]=true}, rate={[2]=true,[3]=true}}
  owner.state.profile, owner.state.rateProfile = 1, 2; process()
  files, numbers = {}, {}
  pid, owner.state.profile = 2, 2
  drive:watchProfiles(); process()
  local profileClips = 0
  for _, file in ipairs(files) do if string.find(file, "evt/profile.wav", 1, true) then profileClips = profileClips + 1 end end
  check(profileClips == 1 and #numbers == 1, "one in-flight profile edge with both announcers enabled speaks once")
  files, numbers = {}, {}
  rate, owner.state.rateProfile = 3, 3
  process(); drive:watchProfiles()
  check(#files == 1 and string.find(files[1], "evt/rates.wav", 1, true) and numbers[1] == 3,
    "rate event belongs to the general announcer regardless of caller order")
  drive.phase = "ground"; pid = 6; drive:watchProfiles()
  files, numbers = {}, {}
  pid = 5; drive:watchProfiles()
  check(#files == 0, "a ground profile edge never plays paused")
  pid = 1; drive:watchProfiles()
  check(#files == 0, "returning to a read profile on the ground never plays resumed")
  drive.phase = "live"; pid = 6; drive:watchProfiles()
  check(#files == 1 and string.find(files[1], "inflight/paused.wav", 1, true), "control: unread profile in flight plays paused")
  pid = 1; drive:watchProfiles()
  check(#files == 2 and string.find(files[2], "inflight/resumed.wav", 1, true), "control: returning in flight plays resumed")
  files, numbers = {}, {}
  owner.preferences.audio_events.pid_profile = false
  pid, owner.state.profile = 3, 3
  drive:watchProfiles(); process()
  check(#files == 1 and string.find(files[1], "evt/profile.wav", 1, true) and numbers[1] == 3,
    "control: overlay owns the profile edge when the general event is disabled")
end

print(checked.." shared profile-announcement checks passed; ordinary and overlay speech controls included")
