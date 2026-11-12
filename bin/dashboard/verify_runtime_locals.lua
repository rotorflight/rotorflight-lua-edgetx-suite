-- widgets/dashboard/runtime.lua is one main chunk of several thousand lines, and Lua allows at most
-- 200 locals to be active at once in a function, the main chunk included (MAXVARS in lparser.c).
-- Two pull requests that each add a top-level local can both compile on their own and still merge
-- into a file that does not. This check compiles the file, and compiles it again with MIN_FREE
-- extra locals declared ahead of everything else, so it goes red while there is still room left
-- rather than on the merge that runs out of it.
--
-- A local declared first stays active to the end of the chunk, so the locals added at the top
-- measure the tightest point of the file, wherever that is: a local inside a do ... end block
-- stops counting at the block's end, and the peak can sit inside one.
--
-- Nothing is run: load() only compiles. From the repository root:
--   lua5.3 bin/dashboard/verify_runtime_locals.lua

local PATH = "src/rfsuite/widgets/dashboard/runtime.lua"

-- Room a pull request may use before this check asks for the file to be split further. New helpers
-- belong in the module that owns the feature, or inside the function or block that uses them.
local MIN_FREE = 10

local failures = 0

local function fail(label, detail)
  failures = failures + 1
  print("FAIL " .. label .. (detail and (": " .. tostring(detail)) or ""))
end

local file = io.open(PATH, "rb")
if not file then
  print("FAIL cannot open " .. PATH .. " (run from the repository root)")
  os.exit(1)
end
local source = file:read("a")
file:close()

local function compiles(extra)
  local chunk, err = load(string.rep("local _ = 0\n", extra) .. source, "=" .. PATH)
  return chunk ~= nil, err
end

-- The control: far more locals than any function may hold has to be refused, or a green below
-- would say nothing about the limit.
local overOk, overErr = compiles(201)
if overOk then
  fail("control: 201 extra locals compiled, so this Lua does not enforce the limit")
elseif not string.find(tostring(overErr), "too many local variables", 1, true) then
  fail("control: 201 extra locals were refused for another reason", overErr)
end

local ok, err = compiles(0)
if not ok then
  fail(PATH .. " does not compile", err)
else
  local free = 0
  while free <= 200 and compiles(free + 1) do
    free = free + 1
  end
  print(string.format("%s: room for %d more top-level locals (minimum %d)", PATH, free, MIN_FREE))
  if free < MIN_FREE then
    fail(PATH .. " is close to Lua's limit of 200 locals in its main chunk",
      string.format("%d free, %d wanted; move helpers into the function or a do ... end block that uses them", free, MIN_FREE))
  end
end

if failures > 0 then
  print(string.format("%d failure(s)", failures))
  os.exit(1)
end
print("OK")
