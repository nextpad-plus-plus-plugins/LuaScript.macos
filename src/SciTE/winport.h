// macOS port shim for the small set of Win32 idioms LuaExtension.cpp uses.
// Everything here preserves Windows semantics; shortcut VK codes keep their
// Windows numeric values (translated to host keys where shortcuts are
// registered — phase 4).
#pragma once
#if !defined(_WIN32)

#include <cstdint>
#include <strings.h>

#define _stricmp  strcasecmp
#define _strnicmp strncasecmp

typedef void          *HWND;
typedef unsigned int   UINT;
typedef uintptr_t      UINT_PTR;
typedef unsigned long  DWORD;
#define CALLBACK

// Menu-name buffer length (Windows PluginInterface nbChar) = host item size.
#ifndef nbChar
#define nbChar NPP_MENU_ITEM_SIZE
#endif

// Repeating-timer parity for npp.StartTimer/StopTimer (implemented on
// NSTimer in GUIMac.mm; ids are process-unique, callback runs on the main
// thread like Windows WM_TIMER).
typedef void (*MacTimerProc)(HWND, UINT, UINT_PTR, DWORD);
extern "C" UINT_PTR MacSetTimer(int milliseconds, MacTimerProc proc);
extern "C" void     MacKillTimer(UINT_PTR timerId);
#define SetTimer(hwnd, id, ms, proc) MacSetTimer((int)(ms), (proc))
#define KillTimer(hwnd, id)          MacKillTimer((UINT_PTR)(id))

// Windows virtual-key codes referenced by the shortcut parser (numeric
// Windows values; phase 4 maps them to host ShortcutKey keys).
#define VK_BACK       0x08
#define VK_RETURN     0x0D
#define VK_ESCAPE     0x1B
#define VK_SPACE      0x20
#define VK_PRIOR      0x21
#define VK_NEXT       0x22
#define VK_LEFT       0x25
#define VK_UP         0x26
#define VK_RIGHT      0x27
#define VK_DOWN       0x28
#define VK_INSERT     0x2D
#define VK_DELETE     0x2E
#define VK_NUMPAD0    0x60
#define VK_OEM_PLUS   0xBB
#define VK_OEM_COMMA  0xBC
#define VK_OEM_MINUS  0xBD
#define VK_OEM_PERIOD 0xBE
#define VK_OEM_1      0xBA
#define VK_OEM_2      0xBF
#define VK_OEM_3      0xC0
#define VK_OEM_4      0xDB
#define VK_OEM_5      0xDC
#define VK_OEM_6      0xDD
#define VK_OEM_7      0xDE

#endif // !_WIN32

// Newer Scintilla removed the 32-bit-position find API; the FULL variants
// have identical field names.
#ifndef SCI_FINDTEXT
#define SCI_FINDTEXT SCI_FINDTEXTFULL
typedef struct Sci_TextToFindFull Sci_TextToFind;
#endif
#ifndef MAX_PATH
#define MAX_PATH 1024
#endif
#include <string>
typedef std::string tstring;   // TCHAR strings are UTF-8 on macOS
