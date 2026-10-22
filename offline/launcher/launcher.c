/* SHODAN Stat Editor Offline: starts app\host.lua (next to this program) in LuaJIT, without a console. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string.h>
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR command, int show)
{
    char path[MAX_PATH * 4];
    DWORD n = GetModuleFileNameA(NULL, path, sizeof(path) - 16);
    char *slash = strrchr(path, 92);   /* the last backslash */
    lua_State *L;
    if (n == 0 || slash == NULL) return 1;
    strcpy(slash + 1, "app/host.lua");
    L = luaL_newstate();
    if (L == NULL) return 1;
    luaL_openlibs(L);
    lua_createtable(L, 0, 1);
    lua_pushstring(L, path);
    lua_rawseti(L, -2, 0);
    lua_setglobal(L, "arg");
    if (luaL_loadfile(L, path) != 0 || lua_pcall(L, 0, 0, 0) != 0) {
        MessageBoxA(NULL, lua_tostring(L, -1), "SHODAN Stat Editor Offline", MB_ICONERROR);
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
