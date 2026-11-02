-- What the ground read leaves on an in-flight drive for a board written from the standard set.
-- The overlay derives its set from the board's own slots (widgets/dashboard/inflight/prime.lua,
-- applySet) and offers nothing before that read, so a test that needs cells reads a board first.
--
-- Usage: local readBoard = dofile("bin/dashboard/inflight_board_fixture.lua")(require)
--   where `require` loads suite modules by their path below src/rfsuite/.
return function(requireModule)
  local Functions = requireModule("widgets/dashboard/inflight/functions.lua")
  local Prime = requireModule("widgets/dashboard/inflight/prime.lua")
  return function(d, mutate)
    local ena = Functions.wireToAuxField(d.settings.bank_ch, nil)
    local adj = Functions.wireToAuxField(d.settings.value_ch, nil)
    local records = {}
    for _, slot in ipairs(Functions.standardSlots(ena, adj, { step = 5, step_headspeed = 50 })) do
      records[slot.slot0 + 1] = slot.record
    end
    if mutate then mutate(records) end
    local derived = Prime.deriveSet(records, nil, d.settings.bank_ch, d.settings.value_ch)
    assert(derived, "board fixture: the standard slots derived no set")
    d.bands, d.bankValues, d.set, d.rowValues = derived.bands, derived.bankValues, derived.set, derived.rowValues
    d.cellRecords, d.setSource = derived.records, "board"
    d:rebuildGroups(true)
    return d
  end
end
