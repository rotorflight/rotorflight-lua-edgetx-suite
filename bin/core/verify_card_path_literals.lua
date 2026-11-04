-- Fails on a card root spelled in code anywhere but the few files allowed to name it
-- (docs/reference/module-loader.md, "Card paths"). Every other module builds its paths from
-- rfsuite.paths, so that moving the install stays a change of those files and the packager.
--
--   lua5.3 bin/core/verify_card_path_literals.lua
--
-- A comment may name a path; code may not. Run from the repository root.
-- Exit status: 0 green, 1 a literal found, 2 the file list came back empty.

local ALLOWED = {
  ["src/rfsuite/lib/paths.lua"] = true,
  ["src/rfsuite/lib/require.lua"] = true,
  ["src/main.lua"] = true,
  ["src/widgets/rfsuite/main.lua"] = true,
  ["src/widgets/rfsuitesvc/main.lua"] = true,
  ["src/functions/rfsbg.lua"] = true,
  ["src/templates/5.Rotorflight/Rotorflight.lua"] = true,
}

local PATTERNS = { "/SCRIPTS/RFSUITE", "SCRIPTS:/RFSUITE", "/SCRIPTS/TOOLS/rfsuite", "SCRIPTS:/TOOLS/rfsuite" }

local function hasLiteral(line)
  if string.match(line, "^%s*%-%-") then return false end
  local code = string.gsub(line, "%s%-%-%s.*$", "")
  for i = 1, #PATTERNS do
    if string.find(code, PATTERNS[i], 1, true) then return true end
  end
  return false
end

local pipe = assert(io.popen("find src -name '*.lua' | sort"))
local files, hits = 0, 0
for path in pipe:lines() do
  files = files + 1
  if not ALLOWED[path] then
    local n = 0
    for line in io.lines(path) do
      n = n + 1
      if hasLiteral(line) then
        hits = hits + 1
        print(string.format("FAIL %s:%d names a card root: build it from rfsuite.paths", path, n))
      end
    end
  end
end
pipe:close()

if files == 0 then
  print("FAIL no source files found: run from the repository root")
  os.exit(2)
end
if hits > 0 then os.exit(1) end
print(string.format("card path literals: %d files read, none outside the allowed list", files))
