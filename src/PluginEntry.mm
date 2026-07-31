// LuaScript.macos — macOS port of the LuaScript plug-in for Notepad++
// (original Windows plugin by Justin Dailey, https://github.com/dail8859/LuaScript
// — GPL-2; this port is a rewrite against the Nextpad++ macOS plugin API,
// reusing the platform-neutral SciTE Lua extension engine and vanilla Lua 5.3.5).
//
// PluginEntry.mm — plugin contract: menu items (mirroring the Windows menu),
// notification routing, lifecycle. The console panel, Lua engine wiring and
// startup-script handling land in later phases.

#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#include <string>
#include <cstring>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#define PLUGIN_NAME    "LuaScript"
#define PLUGIN_VERSION "0.1.0"
static const int NB_FUNC = 6;

static NppData  nppData;
static FuncItem funcItem[NB_FUNC];

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

static void notImplemented(const char *what) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = @PLUGIN_NAME;
        a.informativeText = [NSString stringWithFormat:
            @"\"%s\" arrives in a later phase of this port.", what];
        [a runModal];
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  Menu commands (stubs — phases 3-5 wire the real implementations)
// ═══════════════════════════════════════════════════════════════════════════

static void cmdShowConsole()        { notImplemented("Show Console"); }
static void cmdEditStartupScript()  { notImplemented("Edit Startup Script"); }
static void cmdExecuteCurrentFile() { notImplemented("Execute Current File"); }

static void cmdDocumentation() {
    // Same URL as the Windows plugin's Documentation menu item.
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://dail8859.github.io/LuaScript/"]];
}

static void cmdAbout() {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Skeleton proof-of-life: report the embedded Lua version through a
        // real Lua state, so loading the dylib exercises the vendored VM.
        lua_State *L = luaL_newstate();
        NSString *luaVersion = @"Lua (unavailable)";
        if (L) {
            luaL_openlibs(L);
            if (luaL_dostring(L, "return _VERSION") == LUA_OK && lua_isstring(L, -1))
                luaVersion = [NSString stringWithUTF8String:lua_tostring(L, -1)];
            lua_close(L);
        }
        NSAlert *a = [NSAlert new];
        a.messageText = @"LuaScript v" @PLUGIN_VERSION;
        a.informativeText = [NSString stringWithFormat:
            @"LuaScript plug-in — %@ scripting for Nextpad++.\n\n"
            @"Original Windows plugin by Justin Dailey (dail8859).\n"
            @"macOS port for Nextpad++.\n\n"
            @"License: GPL-2.0", luaVersion];
        [a addButtonWithTitle:@"OK"];
        [a addButtonWithTitle:@"Visit GitHub"];
        if ([a runModal] == NSAlertSecondButtonReturn)
            [[NSWorkspace sharedWorkspace] openURL:
                [NSURL URLWithString:@"https://github.com/dail8859/LuaScript"]];
    });
}

// ═══════════════════════════════════════════════════════════════════════════
//  Plugin contract
// ═══════════════════════════════════════════════════════════════════════════

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;

    int idx = 0;
    auto addItem = [&](const char *name, PFUNCPLUGINCMD func) {
        strlcpy(funcItem[idx]._itemName, name, NPP_MENU_ITEM_SIZE);
        funcItem[idx]._pFunc = func;
        funcItem[idx]._init2Check = false;
        funcItem[idx]._pShKey = nullptr;
        idx++;
    };
    auto addSep = [&]() { addItem("", nullptr); };

    // 1:1 with the Windows plugin's static menu (LuaScript.cpp). The dynamic
    // Lua-registered shortcut section (startup.lua AddShortcut) lands with
    // phase 4 — it must run BEFORE getFuncsArray, same contract as Windows.
    addItem("Show Console",         cmdShowConsole);         // 0
    addItem("Edit Startup Script",  cmdEditStartupScript);   // 1
    addItem("Execute Current File", cmdExecuteCurrentFile);  // 2
    addSep();                                                // 3
    addItem("Documentation...",     cmdDocumentation);       // 4
    addItem("About...",             cmdAbout);               // 5
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = NB_FUNC;
    return funcItem;
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_SHUTDOWN:
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t, uintptr_t, intptr_t) {
    return 1;
}
