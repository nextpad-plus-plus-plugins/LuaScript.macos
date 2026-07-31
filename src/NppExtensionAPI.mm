// This file is part of LuaScript (macOS port). GPL-2; see LICENSE.
// macOS rewrite of NppExtensionAPI.cpp — Windows-parity semantics, with
// SendMessage replaced by the host _sendMessage dispatch (via GUIMac) and
// the console routed through LuaConsoleSink.

#import <Foundation/Foundation.h>
#include "NppExtensionAPI.h"
#include "Scintilla.h"
#include <cstdarg>
#include <cstdio>
#include <cstring>

NppExtensionAPI::~NppExtensionAPI() {}

NppExtensionAPI::Pane NppExtensionAPI::getCurrentPane() {
    int which = 0;
    m_nppData->_sendMessage(m_nppData->_nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    // Host index matches the scis array: 0 or 1.
    return static_cast<NppExtensionAPI::Pane>(which);
}

sptr_t NppExtensionAPI::Send(NppExtensionAPI::Pane p, unsigned int msg, uptr_t wParam, sptr_t lParam) {
    if (p == NppExtensionAPI::application)
        return m_nppData->_sendMessage(m_nppData->_nppHandle, msg, wParam, lParam);
    else
        return scis[p].Call(msg, wParam, lParam);
}

char *NppExtensionAPI::Range(NppExtensionAPI::Pane p, intptr_t start, intptr_t end) {
    if (end <= start) return nullptr;
    char *dest = new char[end - start + 1];
    // SCI_GETTEXTRANGEFULL (the host forwards the FULL variants; the classic
    // struct is 32-bit-position limited).
    Sci_TextRangeFull tr;
    tr.chrg.cpMin = start;
    tr.chrg.cpMax = end;
    tr.lpstrText = dest;
    this->Send(p, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&tr));
    return dest;
}

void NppExtensionAPI::Remove(NppExtensionAPI::Pane p, intptr_t start, intptr_t end) {
    if (end <= start) return;
    intptr_t deleteLength = end - start;
    this->Send(p, SCI_DELETERANGE, start, deleteLength);
}

void NppExtensionAPI::Insert(NppExtensionAPI::Pane p, intptr_t pos, const char *s) {
    this->Send(p, SCI_INSERTTEXT, pos, reinterpret_cast<sptr_t>(s));
}

void NppExtensionAPI::SetTextDirection(NppExtensionAPI::Pane p, bool rtl) {
    // Windows flips WS_EX_LAYOUTRTL; Scintilla Cocoa has SCI_SETBIDIRECTIONAL.
    this->Send(p, SCI_SETBIDIRECTIONAL, rtl ? SC_BIDIRECTIONAL_R2L : SC_BIDIRECTIONAL_DISABLED);
    // Wrap-mode toggle to refresh mirrored characters (Windows-parity trick).
    bool isWrapped = this->Send(p, SCI_GETWRAPMODE) == SC_WRAP_WORD;
    this->Send(p, SCI_SETWRAPMODE, !isWrapped);
    this->Send(p, SCI_SETWRAPMODE, isWrapped);
}

void NppExtensionAPI::Trace(const char *s) {
    if (cd) cd->writeText(strlen(s), s);
    else fprintf(stderr, "[LuaScript] %s", s);
}

void NppExtensionAPI::TraceError(const char *s) {
    if (cd) cd->writeError(strlen(s), s);
    else fprintf(stderr, "[LuaScript ERROR] %s", s);
}

void NppExtensionAPI::Tracef(const char *fmt, ...) {
    char buffer[512];
    va_list arg;
    va_start(arg, fmt);
    vsnprintf(buffer, 512, fmt, arg);
    va_end(arg);
    Trace(buffer);
}

void NppExtensionAPI::ClearConsole() {
    if (cd) cd->clearText();
}

std::string NppExtensionAPI::Property(const char *key) {
    // Windows-parity: only the traceback flag is real; the rest are TODOs
    // upstream too.
    if (strcmp(key, "ext.lua.debug.traceback") == 0) return std::string("1");
    this->Tracef("TODO: NppExtensionAPI::Property(%s)\r\n", key);
    return std::string("NppExtensionAPI::Property");
}

void NppExtensionAPI::SetProperty(const char *key, const char *val) {
    this->Tracef("TODO: NppExtensionAPI::SetProperty(%s, %s)\r\n", key, val);
}

void NppExtensionAPI::UnsetProperty(const char *key) {
    this->Tracef("TODO: NppExtensionAPI::UnsetProperty(%s)\r\n", key);
}

uptr_t NppExtensionAPI::GetInstance() {
    // Windows returns the module HINSTANCE; nothing needs it on macOS.
    return 0;
}

void NppExtensionAPI::ShutDown() {
    // Windows-parity: unused hook.
}

void NppExtensionAPI::DoMenuCommand(int cmdID) {
    m_nppData->_sendMessage(m_nppData->_nppHandle, NPPM_MENUCOMMAND, 0, cmdID);
}
