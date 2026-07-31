/* macOS port: winfile is a Windows-file-API Lua module (FindFirstFile etc.).
 * Ported scripts rarely need it on macOS (Lua's io/os + LuaFileSystem-style
 * needs can be added later). This stub registers an empty module so
 * `require "winfile"` and the engine's luaL_requiref succeed; every function
 * lookup returns nil, which scripts can feature-detect. */
#include "lua.h"
#include "lauxlib.h"

LUAMOD_API int luaopen_winfile(lua_State *L) {
    lua_newtable(L);
    return 1;
}
