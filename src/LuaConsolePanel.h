// LuaScript macOS port — docked console panel (Windows: ConsoleDialog).
#pragma once
#import <Cocoa/Cocoa.h>
#include "NppExtensionAPI.h"

/// Create (once) and return the console container view. `nppData` for host
/// calls; `api` receives the sink + console panes.
NSView *luaConsoleCreate(const NppData *nppData, NppExtensionAPI *api);
/// The LuaConsoleSink bound to the panel (valid after luaConsoleCreate).
LuaConsoleSink *luaConsoleSink(void);
/// Print the Windows-parity startup banner (LUA_COPYRIGHT) once.
void luaConsoleBanner(void);
/// Called whenever the panel's effective visibility changes (host hide/show,
/// close button, dock/undock). Windows parity for DMN_CLOSE checkmark sync.
void luaConsoleSetVisibilityCallback(void (^cb)(bool visible));
