# plasma-glass's Liquid Glass effect for KWin, a plugin of its own (see liquidglass.cpp). Built and swapped
# into the running KWin by tools/kwin-effect.sh. KWin knows it by its file's name, liquidglass.so (a link in
# KWin's plugin folder), and Qt's plugin loader follows the link, keeps a library it has loaded and loads
# another only from another file, whose name gives the effect's (the metadata's Id doesn't count). So each
# build is a liquidglass.so in a folder of its own: PLASMA_GLASS_BUILD_ID names that and its shaders'
# resource prefix, and Build() on D-Bus says which one runs.
cmake_minimum_required(VERSION 3.22)
project(plasma-glass-liquidglass LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_VISIBILITY_INLINES_HIDDEN ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON) # the generated liquidglassconfig.h

find_package(ECM 6 REQUIRED NO_MODULE)
list(APPEND CMAKE_MODULE_PATH ${ECM_MODULE_PATH})
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Gui DBus)
find_package(KF6 6.0 REQUIRED COMPONENTS Config ConfigWidgets CoreAddons)
find_package(KWin REQUIRED)
find_package(KDecoration3 REQUIRED)
find_package(XCB REQUIRED COMPONENTS XCB) # the X11 blur property, as the built-in blur reads it

set(PLASMA_GLASS_BUILD_ID "dev" CACHE STRING "names this build's library and its shaders' resource prefix")

file(GLOB shaders RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/shaders/*)
set(SHADER_FILES "")
foreach(shader ${shaders})
    string(APPEND SHADER_FILES "  <file alias=\"${shader}\">${CMAKE_CURRENT_SOURCE_DIR}/${shader}</file>\n")
endforeach()
configure_file(liquidglass.qrc.in ${CMAKE_CURRENT_BINARY_DIR}/liquidglass.qrc @ONLY)
qt_add_resources(resources ${CMAKE_CURRENT_BINARY_DIR}/liquidglass.qrc)

set(effect_sources liquidglass.cpp main.cpp ${resources})
kconfig_add_kcfg_files(effect_sources liquidglassconfig.kcfgc)

add_library(liquidglass MODULE ${effect_sources})
set_target_properties(liquidglass PROPERTIES PREFIX "" LIBRARY_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/${PLASMA_GLASS_BUILD_ID})
target_compile_definitions(liquidglass PRIVATE
    PLASMA_GLASS_SHADERS=":/plasma-glass/${PLASMA_GLASS_BUILD_ID}/shaders/"
    PLASMA_GLASS_BUILD_ID="${PLASMA_GLASS_BUILD_ID}"
    QT_NO_KEYWORDS)
target_link_options(liquidglass PRIVATE -Wl,--no-undefined)
target_link_libraries(liquidglass PRIVATE
    KWin::kwin
    KF6::ConfigCore
    KF6::ConfigGui
    KF6::CoreAddons
    KDecoration3::KDecoration
    XCB::XCB
    Qt6::Core
    Qt6::Gui
    Qt6::DBus)
