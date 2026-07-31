// LuaScript.macos — macOS port of the LuaScript plug-in for Notepad++
// (original Windows plugin by Justin Dailey, https://github.com/dail8859/LuaScript
// — GPL-2; this port is a rewrite against the Nextpad++ macOS plugin API,
// reusing the platform-neutral SciTE Lua extension engine and vanilla Lua 5.3.5).
//
// PluginEntry.mm — plugin contract: menu (static items + Lua-registered
// shortcuts from startup.lua), notification routing into the engine,
// Execute Current File, inter-plugin messages, lifecycle.

#import <Cocoa/Cocoa.h>
#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#include <string>
#include <vector>
#include <cstring>
#include <cstdio>
#include <sys/stat.h>

extern "C" {
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

#include "NppExtensionAPI.h"
#include "LuaExtension.h"
#include "LuaConsolePanel.h"
#include "StyleWriter.h"
#include "NppLuaScript.h"
#include "SciLexer.h"

// LangType index of L_LUA in Notepad_plus_msgs.h (the vendored header clashes
// with NppPluginInterfaceMac.h typedefs, so mirror just this one value — the
// enum order is ABI-frozen upstream).
static const int kLangLua = 23;

static NppExtensionAPI *sExtensionAPI = nullptr;
extern "C" void GUIMacInit(const NppData *nppData);

#define PLUGIN_NAME    "LuaScript"
#define PLUGIN_VERSION "0.1.0"

static NppData nppData;
static std::vector<FuncItem> funcItems;
static bool isReady = false;
static bool sStartupFailed = false;

static intptr_t npp(uint32_t msg, uintptr_t w = 0, intptr_t l = 0) {
    return nppData._sendMessage(nppData._nppHandle, msg, w, l);
}

// Windows parity: 100 fixed thunks map Lua-registered shortcuts to menu items.
static PFUNCPLUGINCMD LuaShortcutWrappers[] = {
#define LSW(n) []() { LuaExtension::Instance().CallShortcut(n); }
    LSW(1), LSW(2), LSW(3), LSW(4), LSW(5), LSW(6), LSW(7), LSW(8), LSW(9), LSW(10),
    LSW(11), LSW(12), LSW(13), LSW(14), LSW(15), LSW(16), LSW(17), LSW(18), LSW(19), LSW(20),
    LSW(21), LSW(22), LSW(23), LSW(24), LSW(25), LSW(26), LSW(27), LSW(28), LSW(29), LSW(30),
    LSW(31), LSW(32), LSW(33), LSW(34), LSW(35), LSW(36), LSW(37), LSW(38), LSW(39), LSW(40),
    LSW(41), LSW(42), LSW(43), LSW(44), LSW(45), LSW(46), LSW(47), LSW(48), LSW(49), LSW(50),
    LSW(51), LSW(52), LSW(53), LSW(54), LSW(55), LSW(56), LSW(57), LSW(58), LSW(59), LSW(60),
    LSW(61), LSW(62), LSW(63), LSW(64), LSW(65), LSW(66), LSW(67), LSW(68), LSW(69), LSW(70),
    LSW(71), LSW(72), LSW(73), LSW(74), LSW(75), LSW(76), LSW(77), LSW(78), LSW(79), LSW(80),
    LSW(81), LSW(82), LSW(83), LSW(84), LSW(85), LSW(86), LSW(87), LSW(88), LSW(89), LSW(90),
    LSW(91), LSW(92), LSW(93), LSW(94), LSW(95), LSW(96), LSW(97), LSW(98), LSW(99), LSW(100),
#undef LSW
};

// The scintilla view that currently has the caret (Windows updateScintilla()).
static uintptr_t currentScintilla() {
    int which = 0;
    npp(NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle : nppData._scintillaSecondHandle;
}

static sptr_t sciSend(uint32_t msg, uptr_t w = 0, sptr_t l = 0) {
    return nppData._sendMessage(currentScintilla(), msg, w, l);
}

static const char *getStartupScriptFilePath() {
    static char path[1024];
    path[0] = '\0';
    npp(NPPM_GETPLUGINSCONFIGDIR, sizeof(path), (intptr_t)path);
    strlcat(path, "/startup.lua", sizeof(path));
    return path;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Menu commands
// ═══════════════════════════════════════════════════════════════════════════

static uint64_t sConsolePanelHandle = 0;
static NSView  *sConsoleView = nil;

static bool consoleShown() {
    return sConsoleView && sConsoleView.window != nil && !sConsoleView.hiddenOrHasHiddenAncestor;
}

// Returns false if the console could not be created (ScintillaView class or
// the docking manager unavailable — should not happen in a healthy host).
static bool consoleEnsureCreated() {
    if (!sConsoleView) {
        sConsoleView = luaConsoleCreate(&nppData, sExtensionAPI);
        if (!sConsoleView) return false;
        // Keep the menu checkmark honest however the panel is hidden (menu
        // toggle, title-bar close button, dock changes) — Windows DMN_CLOSE parity.
        luaConsoleSetVisibilityCallback(^(bool visible) {
            npp(NPPM_SETMENUITEMCHECK, (uintptr_t)funcItems[0]._cmdID, visible ? 1 : 0);
        });
    }
    if (sConsolePanelHandle == 0) {
        intptr_t h = npp(NPPM_DMM_REGISTERPANEL,
                         (uintptr_t)(__bridge void *)sConsoleView,
                         (intptr_t)"LuaScript");
        if (h > 0) sConsolePanelHandle = (uint64_t)h;
    }
    return sConsolePanelHandle != 0;
}

static void consoleShow(bool focusInput) {
    if (!consoleEnsureCreated()) return;
    npp(NPPM_DMM_SHOWPANEL, (uintptr_t)sConsolePanelHandle, 0);
    // Windows parity: only the menu command gives the input line focus.
    if (focusInput) luaConsoleFocusInput();
}

static void cmdShowConsole() {
    if (!consoleEnsureCreated()) return;
    if (consoleShown())
        npp(NPPM_DMM_HIDEPANEL, (uintptr_t)sConsolePanelHandle, 0);
    else
        consoleShow(isReady);
}

static void cmdEditStartupScript() {
    const char *path = getStartupScriptFilePath();
    struct stat st;
    if (stat(path, &st) != 0) {
        // Same template text the Windows plugin seeds the file with.
        FILE *f = fopen(path, "wb");
        if (f) {
            const char *s = "-- Startup script\r\n"
                            "-- Changes will take effect once Nextpad++ is restarted\r\n\r\n";
            fwrite(s, 1, strlen(s), f);
            fclose(f);
        }
    }
    npp(NPPM_DOOPEN, 0, (intptr_t)path);
}

static void cmdExecuteCurrentFile() {
    // Windows parity: runs the CONTENT of the active buffer (saved or not)
    // via the document's character pointer — we are in-process, so the
    // pointer is directly readable.
    const char *doc = (const char *)sciSend(SCI_GETCHARACTERPOINTER);
    if (!doc) return;
    if (!LuaExtension::Instance().RunString(doc))
        consoleShow(false);
}

static void cmdDocumentation() {
    // Same URL as the Windows plugin's Documentation menu item.
    [[NSWorkspace sharedWorkspace] openURL:
        [NSURL URLWithString:@"https://dail8859.github.io/LuaScript/"]];
}

static void cmdAbout() {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = @"LuaScript v" @PLUGIN_VERSION;
        a.informativeText = [NSString stringWithFormat:
            @"LuaScript plug-in — %s scripting for Nextpad++.\n\n"
            @"Original Windows plugin by Justin Dailey (dail8859).\n"
            @"macOS port for Nextpad++.\n\n"
            @"License: GPL-2.0", LUA_RELEASE];
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

static void addItem(const char *name, PFUNCPLUGINCMD func, ShortcutKey *sk = nullptr) {
    funcItems.emplace_back();
    FuncItem &fi = funcItems.back();
    memset(&fi, 0, sizeof(fi));
    strlcpy(fi._itemName, name, NPP_MENU_ITEM_SIZE);
    fi._pFunc = func;
    fi._pShKey = sk;
}

extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;

    // Initialise the Lua engine BEFORE building the menu — Windows contract:
    // startup.lua registers shortcuts that become menu items.
    GUIMacInit(&nppData);
    sExtensionAPI = new NppExtensionAPI(nullptr, &nppData);
    // Wire the console sink NOW — output produced before the console panel
    // exists (startup.lua prints, the banner) is buffered inside the sink and
    // flushed when the panel is first created.
    sExtensionAPI->setConsoleSink(luaConsoleSink());
    LuaExtension::Instance().Initialise(sExtensionAPI);

    addItem("Show Console",         cmdShowConsole);
    addItem("Edit Startup Script",  cmdEditStartupScript);
    addItem("Execute Current File", cmdExecuteCurrentFile);

    // Run the startup script (a missing file is fine — RunFile returns true).
    if (LuaExtension::Instance().RunFile(getStartupScriptFilePath())) {
        if (!luaShortcuts.empty()) addItem("", nullptr);

        const size_t maxShortcuts = sizeof(LuaShortcutWrappers) / sizeof(LuaShortcutWrappers[0]);
        if (luaShortcuts.size() > maxShortcuts) {
            luaShortcuts.resize(maxShortcuts);
            dispatch_async(dispatch_get_main_queue(), ^{
                NSAlert *a = [NSAlert new];
                a.messageText = @PLUGIN_NAME;
                a.informativeText = @"Too many Lua shortcuts have been registered.\n"
                                    @"This is an arbitrary limit and can be increased if you ask nicely on Github.";
                [a runModal];
            });
        }
        for (size_t i = 0; i < luaShortcuts.size(); ++i)
            addItem(luaShortcuts[i]._itemName, LuaShortcutWrappers[i], luaShortcuts[i]._pShKey);
        luaShortcuts.clear();
    } else {
        // The Lua error text itself already went through the sink (buffered
        // until the console exists); pop the console at NPPN_READY.
        sStartupFailed = true;
        const char *c = "Error occurred while loading startup script\r\n";
        luaConsoleSink()->writeError(strlen(c), c);
    }

    addItem("", nullptr);
    addItem("Documentation...", cmdDocumentation);
    addItem("About...",         cmdAbout);
}

extern "C" NPP_EXPORT const char *getName() {
    return PLUGIN_NAME;
}

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) {
    *nbF = (int)funcItems.size();
    return funcItems.data();
}

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    char fname[1024] = {0};
    Sci_NotifyHeader nh = n->nmhdr;
    LuaExtension &ext = LuaExtension::Instance();

    // Buffer-id based notifications first (Windows handles these before the
    // hwndFrom filter — their hwndFrom carries other data).
    switch (nh.code) {
        case NPPN_READONLYCHANGED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, (uintptr_t)nh.hwndFrom, (intptr_t)fname);
            ext.OnReadOnlyChanged(fname, (uptr_t)nh.hwndFrom, (int)nh.idFrom);
            return;
        case NPPN_DOCORDERCHANGED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnDocOrderChanged(fname, nh.idFrom, (int)(intptr_t)nh.hwndFrom);
            return;
        case NPPN_SNAPSHOTDIRTYFILELOADED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnSnapshotDirtyFileLoaded(fname, (uptr_t)nh.idFrom);
            return;
    }

    // Only notifications from the host and its two scintilla views.
    uintptr_t from = (uintptr_t)nh.hwndFrom;
    if (from != nppData._nppHandle &&
        from != nppData._scintillaMainHandle &&
        from != nppData._scintillaSecondHandle)
        return;

    switch (nh.code) {
        // ── Scintilla ──────────────────────────────────────────────────────
        case SCN_STYLENEEDED: {
            // Copied from SciTE (container-lexed buffers only).
            GUI::ScintillaWindow wEditor;
            wEditor.SetID((GUI::WindowID)currentScintilla());
            intptr_t lineEndStyled = wEditor.Call(SCI_LINEFROMPOSITION, wEditor.Call(SCI_GETENDSTYLED));
            intptr_t endStyled = wEditor.Call(SCI_POSITIONFROMLINE, lineEndStyled);
            StyleWriter styler(wEditor);
            int styleStart = 0;
            if (endStyled > 0) styleStart = styler.StyleAt(endStyled - 1);
            styler.SetCodePage(static_cast<int>(wEditor.Call(SCI_GETCODEPAGE)));
            ext.OnStyle(endStyled, n->position - endStyled, styleStart, &styler);
            styler.Flush();
            break;
        }
        case SCN_CHARADDED:            ext.OnChar(n); break;
        case SCN_SAVEPOINTREACHED:     ext.OnSavePointReached(n); break;
        case SCN_SAVEPOINTLEFT:        ext.OnSavePointLeft(n); break;
        case SCN_MODIFYATTEMPTRO:      ext.OnModifyAttemptRO(n); break;
        case SCN_DOUBLECLICK:          ext.OnDoubleClick(n); break;
        case SCN_UPDATEUI:             ext.OnUpdateUI(n); break;
        case SCN_MODIFIED:
            if (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))
                ext.OnModification(n);
            break;
        case SCN_MACRORECORD:
            // NOTE: do not call! (Windows comment preserved)
            break;
        case SCN_MARGINCLICK:          ext.OnMarginClick(n); break;
        case SCN_NEEDSHOWN:            ext.OnNeedShown(n); break;
        case SCN_PAINTED:              ext.OnPainted(n); break;
        case SCN_USERLISTSELECTION:    ext.OnUserListSelection(n); break;
        case SCN_DWELLSTART:           ext.OnDwellStart(n); break;
        case SCN_DWELLEND:             ext.OnDwellEnd(n); break;
        case SCN_ZOOM:                 ext.OnZoom(n); break;
        case SCN_HOTSPOTCLICK:         ext.OnHotSpotClick(n); break;
        case SCN_HOTSPOTDOUBLECLICK:   ext.OnHotSpotDoubleClick(n); break;
        case SCN_HOTSPOTRELEASECLICK:  ext.OnHotSpotReleaseClick(n); break;
        case SCN_INDICATORCLICK:       ext.OnIndicatorClick(n); break;
        case SCN_INDICATORRELEASE:     ext.OnIndicatorRelease(n); break;
        case SCN_CALLTIPCLICK:         ext.OnCallTipClick(n); break;
        case SCN_AUTOCSELECTION:       ext.OnAutoCSelection(n); break;
        case SCN_AUTOCCANCELLED:       ext.OnAutoCCancelled(n); break;
        case SCN_AUTOCCHARDELETED:     ext.OnAutoCCharDeleted(n); break;
        case SCN_FOCUSIN:              ext.OnFocusIn(n); break;
        case SCN_FOCUSOUT:             ext.OnFocusOut(n); break;

        // ── Nextpad++ ──────────────────────────────────────────────────────
        case NPPN_READY:
            luaConsoleBanner();
            if (sStartupFailed) {
                // NPPN_READY fires while the host still has its side-panel
                // collapse + restore blocks queued on the main queue — showing
                // now would be undone by them. Defer past the restore ladder
                // (runs at +0.5s).
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ consoleShow(false); });
            }
            isReady = true;
            ext.OnReady();
            break;
        case NPPN_TBMODIFICATION:
            // Lua-logo toolbar button for Show Console (Windows: IDI_LUABMP).
            // Host loads <plugindir>/LuaScript.png (+_dark) at 32x32.
            npp(NPPM_ADDTOOLBARICON_FORDARKMODE,
                (uintptr_t)funcItems[0]._cmdID, (intptr_t)"LuaScript.png");
            ext.OnToolBarModification();
            break;
        case NPPN_FILEBEFORECLOSE:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnBeforeClose(fname, nh.idFrom);
            break;
        case NPPN_FILEOPENED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnOpen(fname, nh.idFrom);
            break;
        case NPPN_FILECLOSED:
            ext.OnClose();
            break;
        case NPPN_FILEBEFOREOPEN:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnBeforeOpen(fname, nh.idFrom);
            break;
        case NPPN_FILEBEFORESAVE:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnBeforeSave(fname, nh.idFrom);
            break;
        case NPPN_FILESAVED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnSave(fname, nh.idFrom);
            break;
        case NPPN_SHUTDOWN:
            ext.OnShutdown();
            ext.Finalise();
            if (sConsolePanelHandle > 0) {
                npp(NPPM_DMM_UNREGISTERPANEL, (uintptr_t)sConsolePanelHandle, 0);
                sConsolePanelHandle = 0;
            }
            break;
        case NPPN_BUFFERACTIVATED: {
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            // If opening the startup.lua file add the constants to a keyword
            // list (Windows parity: bolds the Sci/Npp defines while editing).
            char configDir[1024] = {0};
            npp(NPPM_GETPLUGINSCONFIGDIR, sizeof(configDir), (intptr_t)configDir);
            if (npp(NPPM_GETBUFFERLANGTYPE, nh.idFrom) == kLangLua &&
                strncasecmp(fname, configDir, strlen(configDir)) == 0) {
                sciSend(SCI_SETKEYWORDS, 4, (sptr_t)luaConsoleGlobalConstants());
                sciSend(SCI_STYLESETFORE, SCE_LUA_WORD5,
                        sciSend(SCI_STYLEGETFORE, SCE_LUA_PREPROCESSOR));
                sciSend(SCI_STYLESETBOLD, SCE_LUA_WORD5, true);
            }
            ext.OnSwitchFile(fname, nh.idFrom);
            break;
        }
        case NPPN_LANGCHANGED:         ext.OnLangChange(); break;
        case NPPN_FILEBEFORELOAD:      ext.OnFileBeforeLoad(); break;
        case NPPN_FILELOADFAILED:      ext.OnFileLoadFailed(); break;
        case NPPN_BEFORESHUTDOWN:      ext.OnBeforeShutdown(); break;
        case NPPN_CANCELSHUTDOWN:      ext.OnCancelShutdown(); break;
        case NPPN_FILEBEFORERENAME:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnFileBeforeRename(fname, nh.idFrom);
            break;
        case NPPN_FILERENAMECANCEL:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnFileRenameCancel(fname, nh.idFrom);
            break;
        case NPPN_FILERENAMED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnFileRenamed(fname, nh.idFrom);
            break;
        case NPPN_FILEBEFOREDELETE:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnFileBeforeDelete(fname, nh.idFrom);
            break;
        case NPPN_FILEDELETEFAILED:
            npp(NPPM_GETFULLPATHFROMBUFFERID, nh.idFrom, (intptr_t)fname);
            ext.OnFileDeleteFailed(fname, nh.idFrom);
            break;
        case NPPN_FILEDELETED:         ext.OnFileDeleted(); break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t message, uintptr_t, intptr_t lParam) {
    // Inter-plugin API, Windows parity (NppLuaScript.h).
    if (message == NPPM_MSGTOPLUGIN) {
        auto ci = reinterpret_cast<const CommunicationInfo *>(lParam);
        auto lsi = ci ? reinterpret_cast<const LuaScriptInfo *>(ci->info) : nullptr;
        if (lsi && lsi->structVersion == 1 && lsi->script != nullptr) {
            if (ci->internalMsg == LS_EXECUTE_SCRIPT)
                LuaExtension::Instance().RunFile(lsi->script);
            else if (ci->internalMsg == LS_EXECUTE_STATEMENT)
                LuaExtension::Instance().RunString(lsi->script);
        }
    }
    return 1;
}
