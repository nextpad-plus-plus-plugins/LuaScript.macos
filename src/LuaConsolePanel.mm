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
#include "Scintilla.h"
#include <string>
#include <vector>

extern "C" {
#include "lua.h"   // LUA_COPYRIGHT
}

@interface NSObject (NppSciView)
- (sptr_t)message:(unsigned int)msg wParam:(uptr_t)wParam lParam:(sptr_t)lParam;
@end

static NSView *sPanel = nil;
static id      sOut = nil;      // ScintillaView (output)
static id      sIn  = nil;      // ScintillaView (input)
static id      sKeyMonitor = nil;
static std::vector<std::string> sHistory;
static size_t  sHistoryPos = 0;
static bool    sBannerShown = false;

static sptr_t outSend(unsigned int m, uptr_t w = 0, sptr_t l = 0) {
    return [sOut message:m wParam:w lParam:l];
}
static sptr_t inSend(unsigned int m, uptr_t w = 0, sptr_t l = 0) {
    return [sIn message:m wParam:w lParam:l];
}

// ── Sink ────────────────────────────────────────────────────────────────────

static void appendStyled(const char *text, size_t len, int style) {
    if (!sOut) { fprintf(stderr, "[LuaScript] %.*s", (int)len, text); return; }
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
        if (!sOut) return;
        outSend(SCI_SETREADONLY, 0);
        outSend(SCI_CLEARALL);
        outSend(SCI_SETREADONLY, 1);
    }
};
static MacConsoleSink sSink;

LuaConsoleSink *luaConsoleSink(void) { return &sSink; }

void luaConsoleBanner(void) {
    if (sBannerShown || !sOut) return;
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
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self reportVisibility]; }
@end

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

    // Output: read-only, no line-number margin, text margin for '>' echoes,
    // error style 39 red (Windows BGR value kept — Scintilla colors are BGR).
    outSend(SCI_SETMARGINWIDTHN, 0, 0);
    outSend(SCI_SETMARGINWIDTHN, 1, 16);
    outSend(SCI_SETMARGINTYPEN, 1, SC_MARGIN_TEXT);
    outSend(SCI_SETMARGINWIDTHN, 2, 0);
    outSend(SCI_STYLESETFORE, 39, 0x0000FF);
    outSend(SCI_SETREADONLY, 1);
    outSend(SCI_SETWRAPMODE, SC_WRAP_WORD);

    // Input: single visible line, '>' prompt margin, no line numbers.
    inSend(SCI_SETMARGINWIDTHN, 0, 0);
    inSend(SCI_SETMARGINWIDTHN, 1, 16);
    inSend(SCI_SETMARGINTYPEN, 1, SC_MARGIN_TEXT);
    inSend(SCI_SETMARGINWIDTHN, 2, 0);
    inSend(SCI_SETHSCROLLBAR, 0);
    inputPrompt();

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
        [[sIn heightAnchor] constraintEqualToConstant:23],
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

    api->setConsoleSink(&sSink);
    api->setConsolePanes((__bridge GUI::WindowID)sOut, (__bridge GUI::WindowID)sIn);
    return sPanel;
}
