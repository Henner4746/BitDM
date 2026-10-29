# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(bitdm LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "bitdm")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)

# Microsofts C++-Laufzeit neben bitdm.exe. bitdm.exe und die Plugin-DLLs
# importieren MSVCP140.dll, VCRUNTIME140.dll und VCRUNTIME140_1.dll, und die
# bringt ein frisches Windows nicht mit (anders als die UCRT, api-ms-win-crt-*,
# die seit Windows 10 zum System gehoert). Ohne sie endet bitdm.exe sofort mit
# 0xC0000135 STATUS_DLL_NOT_FOUND — so am 17.10.2026 in der winget-Pruefung auf
# einer sauberen Windows-Sandbox (microsoft/winget-pkgs#453011). winget kann
# die Laufzeit als Abhaengigkeit nachinstallieren, Installer und Zip von
# bitdm.net und GitHub koennen das nicht. Also liegen die drei DLLs app-lokal
# im Bau-Ausgang, und bitdm.iss und das Zip nehmen sie mit dem Ordner mit.
#
# Quelle ist der Redist-Ordner des Visual Studio, das auch baut
# (VC\Redist\MSVC\<fassung>\x64\Microsoft.VC143.CRT), nicht System32 und nicht
# das Netz: so passt die Laufzeit zum Compiler, und genau diese Dateien erlaubt
# Microsoft weiterzugeben (redist.txt). Wer die Liste aendert, prueft vorher mit
# `dumpbin /dependents` ueber bitdm.exe und alle DLLs im Release-Ordner, was
# wirklich importiert wird. Fehlt eine der drei, bricht der Bau ab, statt still
# eine App zu bauen, die auf frischen Rechnern nicht startet.
#
# Der Preis: app-lokal kommen Sicherheitsupdates der Laufzeit nur mit einem
# neuen Bau auf aktuellem Visual Studio an, nicht ueber Windows Update — wie bei
# sqlite3 und libsignal, die ebenfalls in diesem Ordner liegen.
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
include(InstallRequiredSystemLibraries)
set(BITDM_VC_LAUFZEIT ${CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS})
list(FILTER BITDM_VC_LAUFZEIT INCLUDE
  REGEX "/(msvcp140|vcruntime140|vcruntime140_1)\\.dll$")
list(LENGTH BITDM_VC_LAUFZEIT BITDM_VC_LAUFZEIT_ANZAHL)
if(NOT BITDM_VC_LAUFZEIT_ANZAHL EQUAL 3)
  message(FATAL_ERROR "VC++-Laufzeit (msvcp140, vcruntime140, vcruntime140_1) "
    "nicht vollstaendig im Redist-Ordner '${MSVC_REDIST_DIR}' gefunden: "
    "${BITDM_VC_LAUFZEIT}")
endif()
install(FILES ${BITDM_VC_LAUFZEIT} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
