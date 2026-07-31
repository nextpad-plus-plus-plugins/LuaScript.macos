// This file is part of LuaScript (macOS port).
// Original Windows plugin Copyright (C)2016 Justin Dailey <dail8859@yahoo.com>
// GPL-2; see LICENSE.
//
// macOS rewrite of NppExtensionAPI.h: same public surface consumed by the
// SciTE LuaExtension engine, with the Win32 ConsoleDialog dependency replaced
// by a small console-sink interface the phase-3 AppKit console implements.
// The four Scintilla panes keep Windows semantics: main/secondary editors are
// the HOST's stable pane handles (every call routed live via _sendMessage —
// never cached direct pointers), output/input are the plugin-owned console
// ScintillaViews once the console exists.

#pragma once

#include <string>
#include "Scintilla.h"          // sptr_t/uptr_t/SciFnDirect for GUI.h
#include "GUI.h"
#include "NppPluginInterfaceMac.h"

inline sptr_t SptrFromPointer(void *p) {
    return reinterpret_cast<sptr_t>(p);
}

inline sptr_t SptrFromString(const char *cp) {
    return reinterpret_cast<sptr_t>(cp);
}

inline uptr_t UptrFromString(const char *cp) {
    return reinterpret_cast<uptr_t>(cp);
}

/// What NppExtensionAPI needs from the console (phase 3 implements this on
/// the AppKit panel; until then a stderr-logging fallback is installed).
class LuaConsoleSink {
public:
    virtual ~LuaConsoleSink() {}
    virtual void writeText(size_t len, const char *s) = 0;
    virtual void writeError(size_t len, const char *s) = 0;
    virtual void clearText() = 0;
};

class NppExtensionAPI final {
public:
    enum Pane {
        paneEditorMain,
        paneEditorSecondary,
        paneOutput,
        paneInput,
        application
    };

    GUI::ScintillaWindow scis[4];

    NppExtensionAPI(LuaConsoleSink *cd_, const NppData *nppData) : cd(cd_) {
        m_nppData = nppData;
        scis[paneEditorMain].SetID((GUI::WindowID)(uintptr_t)m_nppData->_scintillaMainHandle);
        scis[paneEditorSecondary].SetID((GUI::WindowID)(uintptr_t)m_nppData->_scintillaSecondHandle);
        // paneOutput / paneInput stay unset until the console panel exists
        // (phase 3 calls setConsolePanes).
    }

    ~NppExtensionAPI();

    void setConsoleSink(LuaConsoleSink *cd_) { cd = cd_; }
    void setConsolePanes(GUI::WindowID outputView, GUI::WindowID inputView) {
        scis[paneOutput].SetID(outputView);
        scis[paneInput].SetID(inputView);
    }

    Pane getCurrentPane();

    sptr_t Send(Pane p, unsigned int msg, uptr_t wParam = 0, sptr_t lParam = 0);
    char *Range(Pane p, intptr_t start, intptr_t end);
    void Remove(Pane p, intptr_t start, intptr_t end);
    void Insert(Pane p, intptr_t pos, const char *s);
    void SetTextDirection(Pane p, bool rtl);
    void Trace(const char *s);
    void TraceError(const char *s);
    void Tracef(const char *fmt, ...);
    void ClearConsole();
    std::string Property(const char *key);
    void SetProperty(const char *key, const char *val);
    void UnsetProperty(const char *key);
    uptr_t GetInstance();
    void ShutDown();
    void DoMenuCommand(int cmdID);

private:
    LuaConsoleSink *cd;
    const NppData *m_nppData;
};
