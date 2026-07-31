// LuaScript macOS port — console intelligence (autocomplete, brace matching,
// auto-indent, Lua lexing/styles). This is the platform-neutral half of the
// Windows plugin's LuaConsole class (LuaConsole.cpp) — everything it does
// runs through GUI::ScintillaWindow calls; only the owning dialog was Win32.
#pragma once

#include <string>
#include <vector>
#include "Scintilla.h"
#include "GUI.h"

class LuaConsole {
public:
	LuaConsole();

	void setupInput(GUI::ScintillaWindow &sci);
	void setupOutput(GUI::ScintillaWindow &sci);
	bool processNotification(const SCNotification *scn);
	std::string getGlobalConstants();

	void maintainIndentation();
	void braceMatch();
	void showAutoCompletion();

private:
	GUI::ScintillaWindow *m_sciInput = nullptr;
	std::string sciProperties;
	std::string sciFunctions;
	std::string nppProperties;
	std::string nppFunctions;
	std::vector<std::string> globalConsts;
};
