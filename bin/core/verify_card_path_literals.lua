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

-- git names the files on every system, where a plain `find` is another program on Windows. A tree
-- exported without its .git falls back on `find`.
local function sources()
  local list = {}
  for _, command in ipairs({ 'git ls-files "src/*.lua"', "find src -name '*.lua'" }) do
    local pipe = io.popen(command)
    if pipe then
      for path in pipe:lines() do
        list[#list + 1] = path
      end
      pipe:close()
    end
    if #list > 0 then break end
  end
  return list
end

local list = sources()
local files, hits = #list, 0
for i = 1, files do
  local path = list[i]
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

if files == 0 then
  print("FAIL no source files found: run from the repository root")
  os.exit(2)
end
if hits > 0 then os.exit(1) end
print(string.format("card path literals: %d files read, none outside the allowed list", files))
