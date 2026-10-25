cmake_minimum_required(VERSION 3.22)
project(ShodanHuskar LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 6.7 REQUIRED COMPONENTS Quick QuickControls2 Widgets Concurrent)
qt_standard_project_setup(REQUIRES 6.7)
include(FetchContent)
set(BUILD_HUSKARUI_GALLERY OFF CACHE BOOL "" FORCE)
set(INSTALL_HUSKARUI_IN_DEFAULT_LOCATION OFF CACHE BOOL "" FORCE)
FetchContent_Declare(huskar GIT_REPOSITORY https://github.com/mengps/HuskarUI.git GIT_TAG d760773ee0f440284965fe443f765caeb66d8114)
FetchContent_GetProperties(huskar)
if(NOT huskar_POPULATED)
 FetchContent_Populate(huskar)
endif()
# Strict OpenGL drivers require identical uniform blocks in both shader stages.
# Apply before qt_add_shaders so clean builds and local dependency overrides agree.
include(${CMAKE_CURRENT_SOURCE_DIR}/PatchShaderUniforms.cmake)
shodan_patch_shader_uniforms(${huskar_SOURCE_DIR}/src/shaders/husliquidglass)
shodan_patch_shader_uniforms(${huskar_SOURCE_DIR}/gallery/shaders/effect1)
shodan_patch_shader_uniforms(${huskar_SOURCE_DIR}/gallery/shaders/effect2)
add_subdirectory(${huskar_SOURCE_DIR} ${huskar_BINARY_DIR})
# Only the existing JSON/ZIP helpers are reused; no EUI renderer is linked.
FetchContent_Declare(eui_helpers GIT_REPOSITORY https://github.com/sudoevolve/EUI-NEO.git GIT_TAG 1647709068e36834ab26da5a97ef4ad98aa34c9d)
FetchContent_GetProperties(eui_helpers)
if(NOT eui_helpers_POPULATED)
 FetchContent_Populate(eui_helpers)
endif()
set(ZLIB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(${eui_helpers_SOURCE_DIR}/3rd/zlib-1.3.1 ${CMAKE_BINARY_DIR}/zlib EXCLUDE_FROM_ALL)
qt_add_executable(shodan_huskar main.cpp controller.cpp controller.h
 ../eui/bridge.cpp ../eui/mcp_server.cpp ../eui/release_update.cpp
 ../eui/mod_zip.cpp ../eui/patch_mods.cpp
 ${eui_helpers_SOURCE_DIR}/core/platform/json.cpp
 ${eui_helpers_SOURCE_DIR}/3rd/yyjson-0.12.0/src/yyjson.c)
configure_file(${huskar_SOURCE_DIR}/gallery/qml/Controls/GradientFlowEffect.qml ${CMAKE_CURRENT_BINARY_DIR}/GalleryFlow.qml COPYONLY)
set_source_files_properties(${CMAKE_CURRENT_BINARY_DIR}/GalleryFlow.qml PROPERTIES QT_RESOURCE_ALIAS GalleryFlow.qml)
qt_add_resources(shodan_huskar ui PREFIX "/shodan" FILES CatalogGroups.js GroupedCatalog.qml Main.qml Workspace.qml HomePage.qml CatalogPage.qml EditorPage.qml FieldEditor.qml MaterialCard.qml SmoothWheel.qml ArmorPage.qml SettingsPage.qml GameTweaksPage.qml QaRunner.qml ${CMAKE_CURRENT_BINARY_DIR}/GalleryFlow.qml)
qt_add_shaders(shodan_huskar gallery_flow PREFIX "/Gallery/shaders" BASE "${huskar_SOURCE_DIR}/gallery/shaders" FILES "${huskar_SOURCE_DIR}/gallery/shaders/effect2.vert" "${huskar_SOURCE_DIR}/gallery/shaders/effect2.frag")
target_include_directories(shodan_huskar PRIVATE ../eui ../eui/lua
 ${eui_helpers_SOURCE_DIR}/include ${eui_helpers_SOURCE_DIR}/3rd/yyjson-0.12.0/src
 ${eui_helpers_SOURCE_DIR}/3rd/zlib-1.3.1 ${CMAKE_BINARY_DIR}/zlib
 ${huskar_SOURCE_DIR}/src/cpp ${huskar_SOURCE_DIR}/src/cpp/theme)
get_filename_component(COMPILER_BIN ${CMAKE_CXX_COMPILER} DIRECTORY)
find_program(LUA_DLLTOOL dlltool HINTS ${COMPILER_BIN} REQUIRED)
execute_process(COMMAND ${LUA_DLLTOOL} -d ${CMAKE_CURRENT_SOURCE_DIR}/../eui/lua51.def -l ${CMAKE_CURRENT_BINARY_DIR}/liblua51.a COMMAND_ERROR_IS_FATAL ANY)
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/icon.rc "1 ICON \"${CMAKE_CURRENT_SOURCE_DIR}/../../offline/launcher/sseo.ico\"\n1 24 \"${CMAKE_CURRENT_SOURCE_DIR}/../eui/application.manifest\"\n")
target_sources(shodan_huskar PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/icon.rc)
target_link_libraries(shodan_huskar PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Widgets Qt6::Concurrent
 HuskarUIBasic ${CMAKE_CURRENT_BINARY_DIR}/liblua51.a zlibstatic ws2_32 bcrypt winhttp comdlg32)
target_compile_definitions(shodan_huskar PRIVATE NOMINMAX HUSKAR_IMPORT_PATH="${CMAKE_BINARY_DIR}/HuskarUI/qml")
set_target_properties(shodan_huskar PROPERTIES OUTPUT_NAME "SHODAN Huskar" WIN32_EXECUTABLE TRUE)
