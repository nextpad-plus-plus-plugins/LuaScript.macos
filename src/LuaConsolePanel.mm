// LuaScript macOS port — docked console panel. GPL-2; see LICENSE.
//
// Windows-parity behaviours (Dialogs/ConsoleDialog.cpp):
//  * output + input are REAL Scintilla views (ExtensionAPI panes), created
//    from the host's own ScintillaView class via NSClassFromString — no host
//    changes;
//  * '>' prompts are margin text (SCI_MARGINSETTEXT) on the input line and on
//    lines echoed into the output;
//  * errors print in style 39, red (STYLESETFORE 0x0000FF — BGR);
//  * Return runs the statement, Up/Down walk the history (duplicates
//    collapsed, current index resets on run), Shift+Return inserts a newline;
//  * output is read-only outside writes and follows the tail.

#import <Cocoa/Cocoa.h>
#include "LuaConsolePanel.h"
#include "LuaExtension.h"
#include "LuaConsoleLogic.h"
#include "Scintilla.h"
#include <string>
#include <vector>
#include <algorithm>

extern "C" {
#include "lua.h"   // LUA_COPYRIGHT
}

@interface NSObject (NppSciView)
- (sptr_t)message:(unsigned int)msg wParam:(uptr_t)wParam lParam:(sptr_t)lParam;
- (NSScrollView *)scrollView;
@end

static NSView *sPanel = nil;
static id      sOut = nil;      // ScintillaView (output)
static id      sIn  = nil;      // ScintillaView (input)
static LuaConsole *sLogic = nullptr;              // vendored console smarts
static GUI::ScintillaWindow sWinOut, sWinIn;      // GUI wrappers over the views
static NSLayoutConstraint *sInputHeight = nil;
static id      sKeyMonitor = nil;
static std::vector<std::string> sHistory;
static size_t  sHistoryPos = 0;
static bool    sBannerShown = false;
// Text written before the panel exists (startup-script errors, banner) is
// held here and flushed on creation — the Windows console dialog exists from
// setInfo on, ours is created lazily.
static std::vector<std::pair<int, std::string>> sPending;

// Match the host editor's scroller treatment (EditorView.mm): legacy style
// with auto-hide, re-applied whenever the system resets it.
static void applyScrollerStyle(void) {
    for (id v in @[ sOut ?: (id)NSNull.null, sIn ?: (id)NSNull.null ]) {
        if (![v respondsToSelector:@selector(scrollView)]) continue;
        NSScrollView *sv = [v scrollView];
        sv.scrollerStyle = NSScrollerStyleLegacy;
        sv.autohidesScrollers = YES;
    }
}

static sptr_t outSend(unsigned int m, uptr_t w = 0, sptr_t l = 0) {
    return [sOut message:m wParam:w lParam:l];
}
static sptr_t inSend(unsigned int m, uptr_t w = 0, sptr_t l = 0) {
    return [sIn message:m wParam:w lParam:l];
}

// ── Sink ────────────────────────────────────────────────────────────────────

static void appendStyled(const char *text, size_t len, int style) {
    if (!sOut) {
        sPending.emplace_back(style, std::string(text, len));
        fprintf(stderr, "[LuaScript] %.*s", (int)len, text);
        return;
    }
    outSend(SCI_SETREADONLY, 0);
    outSend(SCI_DOCUMENTEND);
    sptr_t start = outSend(SCI_GETLENGTH);
    outSend(SCI_APPENDTEXT, len, (sptr_t)text);
    outSend(SCI_STARTSTYLING, start);
    outSend(SCI_SETSTYLING, len, style);
    outSend(SCI_SETREADONLY, 1);
    outSend(SCI_DOCUMENTEND);
    outSend(SCI_SCROLLCARET);
}

class MacConsoleSink final : public LuaConsoleSink {
public:
    void writeText(size_t len, const char *s) override { appendStyled(s, len, 0); }
    void writeError(size_t len, const char *s) override { appendStyled(s, len, 39); }
    void clearText() override {
        sPending.clear();
        if (!sOut) return;
        outSend(SCI_SETREADONLY, 0);
        outSend(SCI_CLEARALL);
        outSend(SCI_SETREADONLY, 1);
    }
};
static MacConsoleSink sSink;

LuaConsoleSink *luaConsoleSink(void) { return &sSink; }

const char *luaConsoleGlobalConstants(void) {
    static std::string cached;
    if (cached.empty()) {
        if (!sLogic) sLogic = new LuaConsole();
        cached = sLogic->getGlobalConstants();
    }
    return cached.c_str();
}

void luaConsoleFocusInput(void) {
    if (sIn && [sIn window])
        [[sIn window] makeFirstResponder:sIn];
}

void luaConsoleBanner(void) {
    if (sBannerShown) return;
    sBannerShown = true;
    const char *msg = LUA_COPYRIGHT "\r\n\r\n";
    sSink.writeText(strlen(msg), msg);
}

// ── Input actions ───────────────────────────────────────────────────────────

static void inputPrompt(void) {
    inSend(SCI_MARGINSETTEXT, 0, (sptr_t)">");
    inSend(SCI_MARGINSETSTYLE, 0, STYLE_LINENUMBER);
}

static void historyAdd(const std::string &line) {
    if (!line.empty() && (sHistory.empty() || line != sHistory.back()))
        sHistory.push_back(line);
    sHistoryPos = sHistory.size();
}

static void runStatement(void) {
    sptr_t len = inSend(SCI_GETLENGTH);
    std::string text((size_t)len, '\0');
    if (len) {
        Sci_TextRangeFull tr{{0, len}, &text[0]};
        inSend(SCI_GETTEXTRANGEFULL, 0, (sptr_t)&tr);
    }

    // Echo the statement into the output with '>' margin prompts (parity).
    sptr_t prevLast = outSend(SCI_GETLINECOUNT);
    appendStyled(text.c_str(), text.size(), 0);
    appendStyled("\r\n", 2, 0);
    sptr_t newLast = outSend(SCI_GETLINECOUNT);
    for (sptr_t i = prevLast; i < newLast; i++) {
        outSend(SCI_MARGINSETTEXT, i - 1, (sptr_t)">");
        outSend(SCI_MARGINSETSTYLE, i - 1, STYLE_LINENUMBER);
    }

    historyAdd(text);
    LuaExtension::Instance().OnExecute(text.c_str());
    inSend(SCI_CLEARALL);
    inSend(SCI_EMPTYUNDOBUFFER);
    inputPrompt();
}

static void historyShow(void) {
    if (sHistoryPos < sHistory.size())
        inSend(SCI_SETTEXT, 0, (sptr_t)sHistory[sHistoryPos].c_str());
    else
        inSend(SCI_CLEARALL);
    inSend(SCI_DOCUMENTEND);
    inputPrompt();
}

static void (^sVisibilityCB)(bool) = nil;
static bool sLastVisible = false;

void luaConsoleSetVisibilityCallback(void (^cb)(bool visible)) {
    sVisibilityCB = [cb copy];
}

/// Container that reports effective-visibility changes (the host hides or
/// re-parents the view when the panel is toggled, closed or docked).
@interface LuaConsoleContainerView : NSView
@end
@implementation LuaConsoleContainerView
- (void)reportVisibility {
    bool vis = (self.window != nil) && !self.hiddenOrHasHiddenAncestor;
    if (vis != sLastVisible) {
        sLastVisible = vis;
        if (sVisibilityCB) sVisibilityCB(vis);
    }
}
- (void)viewDidHide { [super viewDidHide]; [self reportVisibility]; }
- (void)viewDidUnhide { [super viewDidUnhide]; [self reportVisibility]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self reportVisibility];
    // The system may reset scrollerStyle when the view enters a window.
    if (self.window) applyScrollerStyle();
}
@end

@interface LuaConsoleInputDelegate : NSObject
- (void)notification:(SCNotification *)scn;
@end
@implementation LuaConsoleInputDelegate
- (void)notification:(SCNotification *)scn {
    if (sLogic) sLogic->processNotification(scn);
    if (scn->nmhdr.code == SCN_MODIFIED &&
        (scn->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))) {
        if (scn->linesAdded != 0) {
            // Windows parity: the input grows with its content, up to 8 lines.
            sptr_t lines = std::min<sptr_t>(inSend(SCI_GETLINECOUNT), 8);
            sptr_t lineH = inSend(SCI_TEXTHEIGHT, 1);
            if (sInputHeight) sInputHeight.constant = lines * lineH + 6;
            outSend(SCI_DOCUMENTEND);
        }
        // Not the most efficient way but by far the easiest to do it here
        // (ConsoleDialog.cpp) — every input line carries the '>' prompt.
        sptr_t endLine = inSend(SCI_GETLINECOUNT);
        for (sptr_t i = 0; i < endLine; ++i) {
            inSend(SCI_MARGINSETTEXT, i, (sptr_t)">");
            inSend(SCI_MARGINSETSTYLE, i, STYLE_LINENUMBER);
        }
    }
}
@end
static LuaConsoleInputDelegate *sInputDelegate = nil;

@interface LuaConsoleRunTarget : NSObject
- (void)runClicked:(id)sender;
@end
@implementation LuaConsoleRunTarget
- (void)runClicked:(id)sender { runStatement(); }
@end
static LuaConsoleRunTarget *sRunTarget = nil;

// ── Panel construction ──────────────────────────────────────────────────────

static id makeSciView(void) {
    Class cls = NSClassFromString(@"ScintillaView");
    if (!cls) return nil;
    id v = [[cls alloc] initWithFrame:NSMakeRect(0, 0, 100, 50)];
    [v setTranslatesAutoresizingMaskIntoConstraints:NO];
    return v;
}

NSView *luaConsoleCreate(const NppData *nppData, NppExtensionAPI *api) {
    if (sPanel) return sPanel;
    (void)nppData;

    sOut = makeSciView();
    sIn  = makeSciView();
    if (!sOut || !sIn) return nil;

    // Windows-parity console setup (vendored LuaConsole logic): Lua lexing +
    // styles + keywords + autocomplete config on the input, plain read-only
    // output. Style 39 = red error text (set after setStyles' STYLECLEARALL).
    sWinOut.SetID((GUI::WindowID)(__bridge void *)sOut);
    sWinIn.SetID((GUI::WindowID)(__bridge void *)sIn);
    if (!sLogic) sLogic = new LuaConsole();
    sLogic->setupOutput(sWinOut);
    sLogic->setupInput(sWinIn);
    outSend(SCI_STYLESETFORE, 39, 0x0000FF); // Red error message (BGR)

    // Chrome: output wraps (no horizontal bar or corner square), the input
    // never shows its own scrollers, and both use the host editor's
    // auto-hiding legacy scroller style.
    outSend(SCI_SETWRAPMODE, SC_WRAP_WORD);
    outSend(SCI_SETHSCROLLBAR, 0);
    inSend(SCI_SETVSCROLLBAR, 0);
    applyScrollerStyle();

    // '>' prompt margins (margin 1, text type, width from the glyph).
    sptr_t promptW = outSend(SCI_TEXTWIDTH, STYLE_DEFAULT, (sptr_t)">") * 2;
    outSend(SCI_SETMARGINTYPEN, 1, SC_MARGIN_TEXT);
    outSend(SCI_SETMARGINWIDTHN, 1, promptW);
    inSend(SCI_SETMARGINTYPEN, 1, SC_MARGIN_TEXT);
    inSend(SCI_SETMARGINWIDTHN, 1, promptW);
    inSend(SCI_SETHSCROLLBAR, 0);
    inputPrompt();

    sInputDelegate = [LuaConsoleInputDelegate new];
    [sIn performSelector:@selector(setDelegate:) withObject:sInputDelegate];

    sRunTarget = [LuaConsoleRunTarget new];
    NSButton *run = [NSButton buttonWithTitle:@"Run" target:sRunTarget
                                       action:@selector(runClicked:)];
    run.translatesAutoresizingMaskIntoConstraints = NO;
    run.bezelStyle = NSBezelStyleRounded;
    run.controlSize = NSControlSizeSmall;

    sPanel = [[LuaConsoleContainerView alloc] initWithFrame:NSMakeRect(0, 0, 600, 300)];
    [sPanel addSubview:sOut];
    [sPanel addSubview:sIn];
    [sPanel addSubview:run];
    [NSLayoutConstraint activateConstraints:@[
        [[sOut topAnchor] constraintEqualToAnchor:sPanel.topAnchor],
        [[sOut leadingAnchor] constraintEqualToAnchor:sPanel.leadingAnchor],
        [[sOut trailingAnchor] constraintEqualToAnchor:sPanel.trailingAnchor],
        [[sIn topAnchor] constraintEqualToAnchor:[sOut bottomAnchor] constant:2],
        [[sIn leadingAnchor] constraintEqualToAnchor:sPanel.leadingAnchor],
        [[sIn trailingAnchor] constraintEqualToAnchor:run.leadingAnchor constant:-4],
        (sInputHeight = [[sIn heightAnchor] constraintEqualToConstant:23]),
        [[sIn bottomAnchor] constraintEqualToAnchor:sPanel.bottomAnchor constant:-2],
        [run.trailingAnchor constraintEqualToAnchor:sPanel.trailingAnchor constant:-4],
        [run.centerYAnchor constraintEqualToAnchor:[sIn centerYAnchor]],
    ]];

    // Return runs, Up/Down walk history, Shift+Return inserts a newline —
    // intercepted with a local key monitor while focus is inside the input.
    sKeyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                        handler:^NSEvent *(NSEvent *ev) {
        NSView *fr = (NSView *)[[sIn window] firstResponder];
        if (![fr isKindOfClass:[NSView class]] || ![fr isDescendantOf:(NSView *)sIn])
            return ev;
        if (inSend(SCI_AUTOCACTIVE))
            return ev;   // the autocompletion list owns Return/Up/Down
        switch (ev.keyCode) {
            case 36:   // Return
                if (ev.modifierFlags & NSEventModifierFlagShift) return ev;
                runStatement();
                return nil;
            case 126:  // Up
                if (sHistoryPos > 0) { sHistoryPos--; historyShow(); return nil; }
                return nil;
            case 125:  // Down
                if (sHistoryPos < sHistory.size()) { sHistoryPos++; historyShow(); }
                return nil;
            default:
                return ev;
        }
    }];

    for (auto &p : sPending)
        appendStyled(p.second.c_str(), p.second.size(), p.first);
    sPending.clear();

    api->setConsoleSink(&sSink);
    api->setConsolePanes((__bridge GUI::WindowID)sOut, (__bridge GUI::WindowID)sIn);
    return sPanel;
}
