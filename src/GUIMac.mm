// This file is part of LuaScript (macOS port). GPL-2; see LICENSE.
// GUIMac.mm — macOS implementation of the GUI.h facilities the LuaScript
// engine uses (Windows: GUIWin.cpp). Strings are UTF-8 pass-through on
// __APPLE__; MacSciSend dispatches Scintilla calls either through the host's
// _sendMessage (stable editor pane handles — routed to the CURRENT tab) or
// directly to a plugin-owned ScintillaView (console panes).

#import <Cocoa/Cocoa.h>
#include <string>
#include "Scintilla.h"
#include "GUI.h"
#include "NppPluginInterfaceMac.h"
#include <cstdio>

// Registered by the plugin at setInfo time.
static NppData      sGuiNppData;
static bool         sGuiNppDataSet = false;

extern "C" void GUIMacInit(const NppData *nppData) {
    sGuiNppData = *nppData;
    sGuiNppDataSet = true;
}

@interface NSObject (NppScintillaViewMessage)
- (sptr_t)message:(unsigned int)msg wParam:(uptr_t)wParam lParam:(sptr_t)lParam;
@end

namespace GUI {

sptr_t MacSciSend(WindowID wid, unsigned int msg, uptr_t wParam, sptr_t lParam) {
    if (!wid) return 0;
    if (sGuiNppDataSet &&
        ((uintptr_t)wid == (uintptr_t)sGuiNppData._scintillaMainHandle ||
         (uintptr_t)wid == (uintptr_t)sGuiNppData._scintillaSecondHandle)) {
        return sGuiNppData._sendMessage((NppHandle)(uintptr_t)wid, msg, wParam, lParam);
    }
    // Plugin-owned ScintillaView (console panes): direct ObjC call.
    id view = (__bridge id)wid;
    if ([view respondsToSelector:@selector(message:wParam:lParam:)])
        return [view message:msg wParam:wParam lParam:lParam];
    return 0;
}

// ── Strings: UTF-8 identity on macOS ─────────────────────────────────────────

gui_string StringFromUTF8(const char *s) { return gui_string(s ? s : ""); }
gui_string StringFromUTF8(const std::string &s) { return s; }
std::string UTF8FromString(const gui_string &s) { return s; }

gui_string StringFromInteger(long i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%ld", i);
    return gui_string(buf);
}

gui_string HexStringFromInteger(long i) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lX", i);
    return gui_string(buf);
}

// ── Window (minimal — the engine only ever uses ScintillaWindow) ────────────

void Window::Destroy() {}
bool Window::HasFocus() { return false; }
Rectangle Window::GetPosition() { return Rectangle(); }
void Window::SetPosition(Rectangle) {}
Rectangle Window::GetClientPosition() { return Rectangle(); }
void Window::Show(bool) {}
void Window::InvalidateAll() {}
void Window::SetTitle(const gui_char *) {}

// ── ScintillaWindow out-of-line senders ─────────────────────────────────────

sptr_t ScintillaWindow::Send(unsigned int msg, uptr_t wParam, sptr_t lParam) {
    return MacSciSend(GetID(), msg, wParam, lParam);
}

sptr_t ScintillaWindow::SendPointer(unsigned int msg, uptr_t wParam, void *lParam) {
    return MacSciSend(GetID(), msg, wParam, reinterpret_cast<sptr_t>(lParam));
}

bool IsDBCSLeadByte(int codePage, char ch) {
    // Documents are UTF-8 in this host; no DBCS lead bytes.
    (void)codePage; (void)ch;
    return false;
}

}

// ── Windows-timer parity (winport.h) ────────────────────────────────────────
// npp.StartTimer/StopTimer: repeating main-thread timers with process-unique
// integer ids, mirroring SetTimer/KillTimer semantics.

typedef void (*MacTimerProc)(void *, unsigned int, uintptr_t, unsigned long);

static NSMutableDictionary<NSNumber *, NSTimer *> *sLuaTimers;
static uintptr_t sNextTimerId = 1;

extern "C" uintptr_t MacSetTimer(int milliseconds, MacTimerProc proc) {
    if (milliseconds <= 0 || !proc) return 0;
    if (!sLuaTimers) sLuaTimers = [NSMutableDictionary dictionary];
    uintptr_t timerId = sNextTimerId++;
    MacTimerProc cb = proc;
    NSTimer *t = [NSTimer scheduledTimerWithTimeInterval:milliseconds / 1000.0
                                                 repeats:YES
                                                   block:^(NSTimer *timer) {
        cb(nullptr, 0, timerId, 0);
    }];
    sLuaTimers[@(timerId)] = t;
    return timerId;
}

extern "C" void MacKillTimer(uintptr_t timerId) {
    NSTimer *t = sLuaTimers[@(timerId)];
    if (t) {
        [t invalidate];
        [sLuaTimers removeObjectForKey:@(timerId)];
    }
}
