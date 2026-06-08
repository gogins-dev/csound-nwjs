cmake_minimum_required(VERSION 3.21)
cmake_policy(SET CMP0091 NEW)
cmake_policy(SET CMP0042 NEW)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(APPLE AND NOT DEFINED CMAKE_OSX_ARCHITECTURES)
  set(CMAKE_OSX_ARCHITECTURES "${CMAKE_HOST_SYSTEM_PROCESSOR}" CACHE STRING "" FORCE)
endif()

project(csound VERSION 1.0.1 LANGUAGES CXX)

set(CSOUND_NWJS_SOURCE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}"
    CACHE PATH "csound-nwjs source directory."
)

message(STATUS "CMAKE_HOST_SYSTEM_NAME: ${CMAKE_HOST_SYSTEM_NAME}")

# -----------------------------------------------------------------------------
# FindCsoundHomeFirst.cmake: canonical source is csound-ac (master). A vendored
# copy under cmake/ is kept in this repo as an offline fallback. On configure,
# we try to download csound-ac head and replace that copy when the download
# succeeds.
#
# CsoundAC composition (ChordSpace, scores, etc.) is wasm-only (csound-wasm).
# csound.node uses only header-only csound-ac helpers under vendor/csound-ac/;
# those headers are vendored in git and refreshed from csound-ac master on every
# configure and before each build.
# -----------------------------------------------------------------------------
set(_find_csound_home_first_cmake "${CSOUND_NWJS_SOURCE_DIR}/cmake/FindCsoundHomeFirst.cmake")

file(MAKE_DIRECTORY "${CSOUND_NWJS_SOURCE_DIR}/cmake")

set(csound_ac_refresh_dir "${CMAKE_BINARY_DIR}/csound-ac-refresh")
file(MAKE_DIRECTORY "${csound_ac_refresh_dir}")

message(STATUS "Refreshing FindCsoundHomeFirst.cmake from csound-ac GitHub head...")

file(DOWNLOAD
    "https://raw.githubusercontent.com/gogins-dev/csound-ac/refs/heads/master/cmake/FindCsoundHomeFirst.cmake"
    "${csound_ac_refresh_dir}/FindCsoundHomeFirst.cmake"
    STATUS find_csound_download_status
    SHOW_PROGRESS
)

list(GET find_csound_download_status 0 find_csound_download_code)

if(find_csound_download_code EQUAL 0)
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E copy
      "${csound_ac_refresh_dir}/FindCsoundHomeFirst.cmake"
      "${_find_csound_home_first_cmake}"
  )
  message(STATUS "Replaced ${_find_csound_home_first_cmake} with csound-ac head.")
else()
  list(GET find_csound_download_status 1 find_csound_download_message)
  if(EXISTS "${_find_csound_home_first_cmake}")
    message(WARNING
      "Failed to refresh FindCsoundHomeFirst.cmake from csound-ac head: "
      "${find_csound_download_message}. Using vendored copy in cmake/."
    )
  else()
    message(FATAL_ERROR
      "Failed to download FindCsoundHomeFirst.cmake from csound-ac head: "
      "${find_csound_download_message}. No vendored fallback at "
      "${_find_csound_home_first_cmake}."
    )
  endif()
endif()

# -----------------------------------------------------------------------------
# Csound (home-first finder; optional CSOUND_ROOT_HINT / env CSOUND_ROOT)
# -----------------------------------------------------------------------------
if(DEFINED ENV{CSOUND_ROOT} AND NOT DEFINED CSOUND_ROOT_HINT)
  set(CSOUND_ROOT_HINT "$ENV{CSOUND_ROOT}" CACHE PATH "Prefix where Csound 7 is installed (bin, lib, include)." FORCE)
endif()

set(CSOUND_ROOT_HINT "" CACHE PATH "Prefix where Csound 7 is installed (overrides env CSOUND_ROOT).")

list(APPEND CMAKE_MODULE_PATH "${CSOUND_NWJS_SOURCE_DIR}/cmake")
set(FIND_CSOUND_HOME_FIRST_REQUIRED ON)
include("${_find_csound_home_first_cmake}")

if(NOT CSOUND_FOUND)
  message(FATAL_ERROR "Csound 7 was not found. Set CSOUND_ROOT or -DCSOUND_ROOT_HINT=... to your install prefix.")
endif()

if(CSOUND_INCLUDE_DIR AND EXISTS "${CSOUND_INCLUDE_DIR}/csound/csound.hpp")
  list(APPEND CSOUND_INCLUDE_DIRS "${CSOUND_INCLUDE_DIR}/csound")
endif()

# -----------------------------------------------------------------------------
# csound-ac header-only helpers for csound.node (no libCsoundAC)
# -----------------------------------------------------------------------------
set(CSOUND_AC_HEADERS_DIR "${CSOUND_NWJS_SOURCE_DIR}/vendor/csound-ac")
set(CSOUND_AC_GITHUB_RAW "https://raw.githubusercontent.com/gogins-dev/csound-ac/refs/heads/master/CsoundAC")
file(MAKE_DIRECTORY "${CSOUND_AC_HEADERS_DIR}")

function(csound_nwjs_fetch_csound_ac_header header_name)
  set(_dst "${CSOUND_AC_HEADERS_DIR}/${header_name}")
  set(_url "${CSOUND_AC_GITHUB_RAW}/${header_name}")
  string(CONCAT _url_arg "-DURL=" "${_url}")
  string(CONCAT _dst_arg "-DDST=" "${_dst}")
  execute_process(
    COMMAND "${CMAKE_COMMAND}" "${_url_arg}" "${_dst_arg}"
            -P "${CSOUND_NWJS_SOURCE_DIR}/cmake/FetchCsoundACHeader.cmake"
  )
  if(NOT EXISTS "${_dst}")
    message(FATAL_ERROR "Missing csound-ac header (download failed and no vendored fallback): ${_dst}")
  endif()
endfunction()

csound_nwjs_fetch_csound_ac_header(csound_threaded.hpp)
csound_nwjs_fetch_csound_ac_header(CsoundProducer.hpp)
message(STATUS "Using csound-ac headers: ${CSOUND_AC_HEADERS_DIR}")

# -----------------------------------------------------------------------------
# Node / N-API: cmake-js sets CMAKE_JS_INC to Node's include/node only; napi.h is in node-addon-api.
# -----------------------------------------------------------------------------
set(_napi_include "")
if(DEFINED ENV{NODE_ADDON_API_INCLUDE} AND NOT "$ENV{NODE_ADDON_API_INCLUDE}" STREQUAL "")
  set(_napi_include "$ENV{NODE_ADDON_API_INCLUDE}")
elseif(NODE_ADDON_API_DIR)
  set(_napi_include "${NODE_ADDON_API_DIR}")
elseif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/native/node_modules/node-addon-api/napi.h")
  set(_napi_include "${CMAKE_CURRENT_SOURCE_DIR}/native/node_modules/node-addon-api")
endif()

# Strip wrapping double quotes if NODE_ADDON_API_INCLUDE used node-addon-api's deprecated .include value.
string(STRIP "${_napi_include}" _napi_include)
string(REGEX REPLACE "^\"(.*)\"$" "\\1" _napi_include "${_napi_include}")

if(NOT DEFINED CMAKE_JS_INC OR CMAKE_JS_INC STREQUAL "")
  if(_napi_include)
    set(CMAKE_JS_INC "${_napi_include}")
  else()
    message(
      FATAL_ERROR
        "Node headers not found (CMAKE_JS_INC). Use cmake-js, or set NODE_ADDON_API_INCLUDE / NODE_ADDON_API_DIR, "
        "or add native/package.json and run (cd native && npm install)."
    )
  endif()
endif()

if(NOT _napi_include)
  message(
    FATAL_ERROR
      "node-addon-api not found (napi.h). Export NODE_ADDON_API_INCLUDE=/path/to/node-addon-api, "
      "pass -DNODE_ADDON_API_DIR=..., or run (cd native && npm install) so native/node_modules/node-addon-api exists."
  )
endif()

set(_cmake_js_src "")
if(DEFINED CMAKE_JS_SRC)
  set(_cmake_js_src ${CMAKE_JS_SRC})
endif()

file(GLOB SOURCE_FILES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.cpp")

add_library(${PROJECT_NAME} SHARED ${SOURCE_FILES} ${_cmake_js_src})
set_target_properties(${PROJECT_NAME} PROPERTIES PREFIX "" SUFFIX ".node")

string(CONCAT _csound_threaded_url_arg "-DURL=" "${CSOUND_AC_GITHUB_RAW}/csound_threaded.hpp")
string(CONCAT _csound_threaded_dst_arg "-DDST=" "${CSOUND_AC_HEADERS_DIR}/csound_threaded.hpp")
string(CONCAT _csound_producer_url_arg "-DURL=" "${CSOUND_AC_GITHUB_RAW}/CsoundProducer.hpp")
string(CONCAT _csound_producer_dst_arg "-DDST=" "${CSOUND_AC_HEADERS_DIR}/CsoundProducer.hpp")
add_custom_target(
  csound_ac_fetch_headers
  COMMAND "${CMAKE_COMMAND}" "${_csound_threaded_url_arg}" "${_csound_threaded_dst_arg}"
          -P "${CSOUND_NWJS_SOURCE_DIR}/cmake/FetchCsoundACHeader.cmake"
  COMMAND "${CMAKE_COMMAND}" "${_csound_producer_url_arg}" "${_csound_producer_dst_arg}"
          -P "${CSOUND_NWJS_SOURCE_DIR}/cmake/FetchCsoundACHeader.cmake"
  COMMENT "Refresh csound-ac headers from GitHub head"
  VERBATIM
)
add_dependencies(${PROJECT_NAME} csound_ac_fetch_headers)

target_include_directories(
  ${PROJECT_NAME}
  PRIVATE
    "${CMAKE_JS_INC}"
    "${_napi_include}"
    "${CSOUND_AC_HEADERS_DIR}"
    ${CSOUND_INCLUDE_DIRS}
)

if(NOT CSOUND_VERSION_MAJOR)
  set(CSOUND_VERSION_MAJOR 7)
endif()

target_compile_definitions(
  ${PROJECT_NAME}
  PRIVATE
    NAPI_VERSION=4
    CSOUND_VERSION_MAJOR=${CSOUND_VERSION_MAJOR}
)

if(APPLE)
  target_link_libraries(
    ${PROJECT_NAME}
    PRIVATE
      ${CMAKE_JS_LIB}
      ${CSOUND_LIBRARIES}
      pthread
  )
  target_link_options(
    ${PROJECT_NAME}
    PRIVATE
      "LINKER:-rpath,@loader_path"
      "LINKER:-rpath,/Library/Frameworks"
      "LINKER:-rpath,/usr/local/lib"
  )
  if(CSOUND_FRAMEWORK_DIR)
    get_filename_component(_csound_fw_parent "${CSOUND_FRAMEWORK_DIR}" DIRECTORY)
    target_link_options(${PROJECT_NAME} PRIVATE "LINKER:-F${_csound_fw_parent}")
  endif()
elseif(UNIX AND NOT APPLE)
  target_link_libraries(
    ${PROJECT_NAME}
    PRIVATE
      ${CMAKE_JS_LIB}
      ${CSOUND_LIBRARIES}
      pthread
  )
elseif(WIN32)
  if(MSVC AND DEFINED CMAKE_JS_NODELIB_DEF AND DEFINED CMAKE_JS_NODELIB_TARGET)
    execute_process(
      COMMAND ${CMAKE_AR} /def:${CMAKE_JS_NODELIB_DEF} /out:${CMAKE_JS_NODELIB_TARGET} ${CMAKE_STATIC_LINKER_FLAGS}
    )
  endif()
  target_link_libraries(
    ${PROJECT_NAME}
    PRIVATE
      ${CMAKE_JS_LIB}
      ${CSOUND_LIBRARIES}
  )
endif()
