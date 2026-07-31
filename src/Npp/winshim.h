// macOS port shim: minimal Win32 type/constant definitions so the vendored
// Windows headers (Notepad_plus_msgs.h, menuCmdID.h — pure message/command
// constants) compile unchanged. Only what those headers reference.
#pragma once
#include <cstdint>

typedef char            TCHAR;
typedef void           *HWND;
typedef void           *HMENU;
typedef void           *HICON;
typedef void           *HBITMAP;
typedef int             BOOL;
typedef unsigned int    UINT;
typedef unsigned long   COLORREF;
typedef intptr_t        LRESULT;
typedef uintptr_t       WPARAM;
typedef intptr_t        LPARAM;
#ifndef WM_USER
#define WM_USER 0x0400
#endif
