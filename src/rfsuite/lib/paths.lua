-- lib/paths.lua
-- Where the suite sits on the card: its code, and the pilot's own data beside it.
--
-- Every module builds its card paths from these two roots rather than spelling them. The few
-- files that still name the code root are listed in docs/reference/module-loader.md; moving the
-- install changes them, this file and the packager. legacyUser is where an earlier install kept
-- the pilot's data, read only by the move at startup (lib/user_move.lua). lib/require.lua
-- publishes the table as
-- _G.rfsuite.paths in every Lua state of the suite before any other module is loaded. Neither
-- root ends in a slash; a path is built as `_G.rfsuite.paths.core .. "/lib/log.lua"`.
--
-- Pure data, and nothing else, so a desktop test can read it as it is:
-- `_G.rfsuite.paths = dofile("src/rfsuite/lib/paths.lua")`.

return {
  core = "/SCRIPTS/RFSUITE/core",
  user = "/SCRIPTS/RFSUITE/user",
  legacyUser = "/SCRIPTS/TOOLS/rfsuite.user",
}
