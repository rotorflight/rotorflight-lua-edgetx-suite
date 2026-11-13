-- Whether widgets/dashboard/menu_list.lua is what bin/dashboard/make_menu_list.lua makes of the manifest today.
--   lua5.3 bin/dashboard/verify_menu_list.lua
-- Exit 0 current, 1 stale. The generator's --check carries the control and the message.

_G.arg = { [0] = "bin/dashboard/make_menu_list.lua", "--check" }
dofile("bin/dashboard/make_menu_list.lua")
