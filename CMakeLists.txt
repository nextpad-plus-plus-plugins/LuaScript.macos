cmake_minimum_required(VERSION 3.20)
project(LuaScript VERSION 0.1.0 LANGUAGES C CXX OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

set(NPP_MACOS_DIR "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(SCINTILLA_INCLUDE "${NPP_MACOS_DIR}/scintilla/include")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")

# Vanilla Lua 5.3.5, vendored from the Windows plugin (src/lua) — library
# files only (no lua.c/luac.c standalone hosts in the vendored set).
file(GLOB LUA_SOURCES ${CMAKE_SOURCE_DIR}/src/lua/src/*.c)

add_library(LuaScript SHARED
    src/PluginEntry.mm
    ${LUA_SOURCES}
)
target_include_directories(LuaScript PRIVATE
    ${NPP_PLUGIN_INCLUDE}
    ${SCINTILLA_INCLUDE}
    src
    src/lua/src)
target_compile_definitions(LuaScript PRIVATE LUA_USE_MACOSX)
target_link_libraries(LuaScript PRIVATE
    "-framework Cocoa")
target_compile_options(LuaScript PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(LuaScript PROPERTIES PREFIX "" SUFFIX ".dylib")
# Stamp version into the dylib Mach-O current_version (Plugins Admin reads it).
target_link_options(LuaScript PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/LuaScript")
install(TARGETS LuaScript DESTINATION "${PLUGIN_INSTALL_DIR}")
