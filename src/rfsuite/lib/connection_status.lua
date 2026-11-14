-- What the connection is doing, in words: for the tool's header button and for the header of the
-- dashboard's rolling menu. Two situations look identical from the outside while a connection comes
-- up -- the flight controller has not answered at all, and it has answered and its configuration is
-- still being read -- and they are the two a pilot most needs to tell apart.
--
-- Everything here is worked out when it is asked for, from what the session and the connect runner
-- already hold. `i18n` is whichever translator the caller has.

local M = {}

--- What the start is waiting for, by the onconnect runner's own task name. An id with no entry falls
--- back to the generic notice rather than putting an internal name on screen.
M.ONCONNECT_TEXT = {
  apiversion        = "@i18n(app.onconnect.apiversion)@",
  uid               = "@i18n(app.onconnect.uid)@",
  rtc               = "@i18n(app.onconnect.rtc)@",
  status            = "@i18n(app.onconnect.status)@",
  battery_config    = "@i18n(app.onconnect.battery_config)@",
  governor_config   = "@i18n(app.onconnect.governor_config)@",
  esc_sensor_config = "@i18n(app.onconnect.esc_sensor_config)@",
  smartfuel_config  = "@i18n(app.onconnect.smartfuel_config)@",
  name              = "@i18n(app.onconnect.name)@",
  telemetry         = "@i18n(app.onconnect.telemetry)@",
  flight_stats      = "@i18n(app.onconnect.flight_stats)@",
  dataflash_summary = "@i18n(app.onconnect.dataflash_summary)@"
}

local function appendPart(parts, value, format)
  if type(value) == "string" and value ~= "" then
    parts[#parts + 1] = string.format(format, value)
  end
end

--- Why the handshake has not completed, where the session already carries a reason. It is resolved
--- into a value of its own rather than read where the notice is composed, because it decides the
--- state as well as the wording -- the API version read fails on a backoff that grows, so the reason
--- usually arrives well after the state was first shown.
function M.handshakeDetail(session)
  if type(session) ~= "table" then return nil end
  if session.apiSupported == false then return "api" end
  if type(session.mspLastError) == "string" and session.mspLastError ~= "" then return "noreply" end
  return nil
end

--- Which of the four states this is. Two of them share one: waiting for the handshake and reading the
--- configuration are both "working" from outside, and a reason for the handshake not completing, or a
--- connect step that was given up on, is what turns either into an error.
function M.stateKey(status, detail, failed)
  if status == "nolink" then return "nolink" end
  if status == "handshake" then
    return detail and "error" or "handshake"
  end
  if status == "chain" then return "handshake" end
  return (failed or 0) > 0 and "error" or "ready"
end

--- The state's name, as the notice's title reads.
function M.title(i18n, key)
  if key == "nolink" then return i18n and i18n.t and i18n.t("app.home_status.title_no_link") or "Not connected" end
  if key == "error" then return i18n and i18n.t and i18n.t("app.home_status.title_error") or "Connection error" end
  if key == "handshake" then return i18n and i18n.t and i18n.t("app.home_status.title_connecting") or "Connecting" end
  return i18n and i18n.t and i18n.t("app.home_status.title_connected") or "Connected"
end

--- The title and the message of the notice for a state.
--
-- Every message here is two lines at most, so it never fills the room the notice box gives it.
-- ui/loading_overlay.lua grows the box by exactly the lines that do not fit
-- (`messageShift = max(0, lines * lineH - messageRoom)`) and puts nothing under the text, so a
-- message that uses all of its room ends with its descenders against the acknowledging button.
-- That box is not this change's to alter, and a caller can stay inside it: the third thing
-- worth saying is always somewhere the pilot can already read it.
function M.notice(i18n, session, status, detail, taskName, done, total, failed)
  failed = failed or 0
  local key = M.stateKey(status, detail, failed)
  local title = M.title(i18n, key)

  if status == "nolink" then
    return title, i18n and i18n.t and i18n.t("app.home_status.no_link")
      or "The radio is not receiving telemetry from this model."
  end

  if status == "handshake" then
    if detail == "api" then
      return title, i18n and i18n.t and i18n.t("app.home_status.api_unsupported")
        or "The flight controller answered with an MSP API version the suite does not support."
    end
    if detail == "noreply" then
      return title, i18n and i18n.t and i18n.t("app.home_status.no_reply")
        or "Telemetry is arriving, but the flight controller is not answering."
    end
    return title, i18n and i18n.t and i18n.t("app.home_status.handshake")
      or "Telemetry is arriving. Waiting for the flight controller to answer."
  end

  if status == "chain" then
    -- The same table the start screen names its step from, so the wording a pilot reads before
    -- the menu appears and the wording he reads behind the button are one string rather than two.
    local taskText = M.ONCONNECT_TEXT[taskName or ""] or
      (i18n and i18n.t and i18n.t("app.home_status.reading") or "Reading the configuration")
    local message = taskText
    if total > 0 then
      message = string.format(i18n and i18n.t and i18n.t("app.home_status.step") or "%s (%d/%d)", taskText, done, total)
    end
    return title, message
  end

  local lines = {}
  local craft = nil
  if type(session) == "table" and type(session.modelName) == "string" and session.modelName ~= "" then
    craft = session.modelName
  end

  if failed > 0 then
    -- A task that gave up counts towards the chain being through, because the chain has moved
    -- past it -- so a bare "connected" would cover a connect that is missing part of its
    -- configuration. That is what the pilot opened this for, so it takes the first line and the
    -- firmware versions give up theirs to it: the versions are on the diagnostics info page
    -- whatever happens here, and the count is nowhere else.
    lines[#lines + 1] = string.format(
      i18n and i18n.t and i18n.t("app.home_status.steps_failed") or "Connect steps not completed: %d", failed)
    if craft then
      lines[#lines + 1] = craft
    end
  else
    if craft then
      lines[#lines + 1] = craft
    end
    local versions = {}
    if type(session) == "table" then
      appendPart(versions, session.rfVersion, i18n and i18n.t and i18n.t("app.home_status.rf_version") or "Rotorflight %s")
      appendPart(versions, session.apiVersion, i18n and i18n.t and i18n.t("app.home_status.api_version") or "MSP API %s")
    end
    if #versions > 0 then
      lines[#lines + 1] = table.concat(versions, " - ")
    end
  end

  if #lines == 0 then
    return title, i18n and i18n.t and i18n.t("app.home_status.ready") or "Connected."
  end
  return title, table.concat(lines, "\n")
end

--- The connection as it stands, for a surface with no state of its own to keep it in: the status, the
--- reason, and the connect runner's progress. `linkUp` and `fblConnected` are the caller's readings,
--- `events` the event runtime.
function M.read(session, linkUp, fblConnected, events)
  if not linkUp then return "nolink", nil, nil, 0, 0, 0 end
  if not fblConnected then return "handshake", M.handshakeDetail(session), nil, 0, 0, 0 end
  local progress = (events and type(events.getOnconnectProgress) == "function") and events.getOnconnectProgress() or nil
  local done, total, failed, taskName = 0, 0, 0, nil
  if type(progress) == "table" then
    done, total, failed, taskName = progress.done or 0, progress.total or 0, progress.failed or 0, progress.pending
  end
  -- `total` is zero until the runner has read its manifest, and zero of zero is not a finished chain.
  if total > 0 and done >= total then return "ready", nil, nil, done, total, failed end
  return "chain", nil, taskName, done, total, failed
end

return M
