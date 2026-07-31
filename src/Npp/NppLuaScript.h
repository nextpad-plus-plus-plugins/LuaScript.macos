// Inter-plugin API of the LuaScript plugin (NPPM_MSGTOPLUGIN payloads).
// Vendored unchanged from the Windows plugin (dail8859/LuaScript, GPL-2);
// WM_USER comes from winshim.h on macOS.
#ifndef NPPLUASCRIPT_H
#define NPPLUASCRIPT_H

#define LS_START (WM_USER + 3500)

#define LS_EXECUTE_SCRIPT (LS_START + 0)
#define LS_EXECUTE_STATEMENT (LS_START + 1)

struct LuaScriptInfo
{
	// The structure's version. This must be 1.
	int structVersion;

	// Configurable flags
	int flags;

	// Script to run. This has different meaning based on the command.
	const char *script;
};

#endif
