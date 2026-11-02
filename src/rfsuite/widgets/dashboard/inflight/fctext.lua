-- Sentences shared by the suggested-functions plan and its result.
local M = {}

local SLOT_LINES_SHOWN = 6

--- Why the flight controller cannot be read or written, in words.
--
-- Every reason the writer can answer with is named. A reason with no sentence of its own still
-- reaches the screen, appended to the general one, because a code the pilot can read out is worth
-- more than a polished sentence that hides which of eight things went wrong.
function M.refusalText(reason, t)
  if reason == "armed" then
    return t("widgets.dashboard.inflight_fc_armed", "The model is armed.")
  elseif reason == "arm_unknown" then
    return t("widgets.dashboard.inflight_fc_arm_unknown", "The arming state cannot be read, so nothing is written.")
  elseif reason == "rotor_running" then
    return t("widgets.dashboard.inflight_fc_rotor_running", "The rotor is running. Stop it before setting up the flight controller.")
  elseif reason == "no_link" then
    return t("widgets.dashboard.inflight_fc_no_link", "No link to the flight controller.")
  elseif reason == "no_sensors" or reason == "no_api" then
    return t("widgets.dashboard.inflight_fc_unavailable", "This build cannot reach the flight controller.")
  elseif reason == "old_api" then
    return t("widgets.dashboard.inflight_fc_old_api", "This flight controller does not answer the paged reads.")
  elseif reason == "same_channel" then
    return t("widgets.dashboard.inflight_plan_same_channel", "The two channels have to be different.")
  elseif reason == "ena_channel" or reason == "adj_channel" then
    return t("widgets.dashboard.inflight_fc_channel", "No receiver channel of the flight controller reaches that channel.")
  elseif reason == "rxmap" then
    return t("widgets.dashboard.inflight_fc_rxmap", "The receiver channel map could not be read.")
  elseif reason == "functionIds" or reason == "no_function_ids" then
    return t("widgets.dashboard.inflight_fc_ids_failed", "The adjustment function list could not be read.")
  elseif reason == "verify" then
    return t("widgets.dashboard.inflight_fc_verify_failed", "The written adjustment slots could not be read back.")
  elseif reason == "commit" then
    return t("widgets.dashboard.inflight_fc_commit_failed", "The flight controller could not save the adjustment slots.")
  elseif reason == "encode" or reason == "no_set" or reason == "no_plan" then
    return t("widgets.dashboard.inflight_fc_plan_failed", "The suggested adjustment functions could not be prepared.")
  elseif reason == "store" or reason == "missing_mcu_id" then
    return t("widgets.dashboard.inflight_fc_store_failed", "The selected steps could not be saved to this model.")
  elseif string.match(tostring(reason), "^slot_%d+$") then
    return string.format(t("widgets.dashboard.inflight_fc_slot_failed", "Adjustment slot %s could not be written."),
      string.match(reason, "%d+"))
  end
  if reason == "board_changed" then
    return t("widgets.dashboard.inflight_fc_board_changed", "The flight controller changed. Read the board again.")
  elseif reason == "verify_differs" then
    return t("widgets.dashboard.inflight_fc_verify_differs", "Written, but the read-back does not match")
  elseif reason == "verify_step_only" then
    return t("widgets.dashboard.inflight_fc_verify_step_only", "Written, but the flight controller kept another step")
  end
  return t("widgets.dashboard.inflight_fc_failed", "The flight controller write failed") .. ": " .. tostring(reason)
end

--- What the board carries today, held against the standard set.
--
-- The verdict comes from the function-id reply and from nothing else, so what it can say is which
-- slots name the right FUNCTION. "Already carries this set" would overstate that -- a slot naming
-- the right function can still watch the wrong channel through the wrong window -- so the matching
-- case is worded at the level it was actually measured at.
local function compareText(compare, t)
  local verdict = (type(compare) == "table") and compare.verdict or nil
  if verdict == "match" then
    return t("widgets.dashboard.inflight_fc_board_functions_match",
      "Every slot of this set already names the function it should.")
  elseif verdict == "empty" then
    return t("widgets.dashboard.inflight_fc_board_empty", "The flight controller carries none of this set.")
  elseif verdict == "differ" then
    return string.format("%s %d", t("widgets.dashboard.inflight_fc_board_differs", "Slots differing from this set:"),
      compare.count)
  end
  return t("widgets.dashboard.inflight_fc_board_unknown", "The flight controller has not been compared.")
end

--- The question the pilot answers, built from the plan and not from what the page intended.
--
-- The counts come first because they are what cannot be taken back, and the overwrites get a list
-- of their own rather than a number in a row: a slot being overwritten is a parameter moving
-- somewhere else on the screen, or a control the pilot flies with that stops working, and the
-- function each of them holds today is the only thing on this screen he can recognise it by.
--
-- Each entry remains a separate block so the surface can page between complete sentences.
function M.question(plan, t)
  local lines = {}
  lines[#lines + 1] = string.format("%s %d (%d..%d)",
    t("widgets.dashboard.inflight_fc_write_slots", "Adjustment slots written:"), plan.writes,
    plan.slots[1].slot0 + 1, plan.slots[#plan.slots].slot0 + 1)
  lines[#lines + 1] = string.format("%s %d",
    t("widgets.dashboard.inflight_fc_overwritten", "Of them already in use:"), plan.overwritten)

  -- Slots are numbered from 1, the way the Adjustments page counts its ranges; the wire index
  -- (slot0) starts at 0.
  if plan.overwritten > 0 then
    lines[#lines + 1] = t("widgets.dashboard.inflight_fc_overwrite_head", "Slot: now -> new")
  end
  local shown = 0
  for i = 1, #plan.slots do
    local entry = plan.slots[i]
    if entry.overwritten then
      if shown >= SLOT_LINES_SHOWN then
        lines[#lines + 1] = string.format("  ... %d", plan.overwritten - shown)
        break
      end
      shown = shown + 1
      lines[#lines + 1] = string.format("  %d: %s -> %s", entry.slot0 + 1,
        tostring(entry.heldName), tostring(entry.name))
    end
  end

  if plan.overwritten > 0 then
    lines[#lines + 1] = t("widgets.dashboard.inflight_fc_overwritten_note",
      "Slots holding another function are overwritten, whichever switch they belong to.")
  end

  lines[#lines + 1] = compareText(plan.compare, t)
  local kept = {}
  for i = 1, #plan.keep do kept[#kept + 1] = tostring(plan.keep[i].slot0 + 1) end
  lines[#lines + 1] = string.format("%s %s",
    t("widgets.dashboard.inflight_fc_kept", "Left alone:"), table.concat(kept, ", "))

  return lines
end


return M
