# Copyright 2022-2023 Mitchell. See LICENSE.

cmake_minimum_required(VERSION 3.16)

set(src ${CMAKE_SOURCE_DIR})

# Dependencies.
include(FetchContent)
set(FETCHCONTENT_QUIET OFF)
set(deps_dir ${CMAKE_BINARY_DIR}/_deps)
set(dkjson_tgz dkjson-2.5.tar.gz)
set(dkjson_url file://${deps_dir}/${dkjson_tgz})
if(NOT EXISTS ${deps_dir}/${dkjson_tgz})
  set(dkjson_url https://dkolf.de/src/dkjson-lua.fsl/tarball/${dkjson_tgz})
endif()
FetchContent_Declare(dkjson URL ${dkjson_url})
FetchContent_MakeAvailable(dkjson)
set(penlight_zip 1.13.1.zip)
FetchContent_Declare(penlight
  URL https://github.com/lunarmodules/Penlight/archive/refs/tags/${penlight_zip})
FetchContent_MakeAvailable(penlight)
set(ldoc_zip 1.4.6.zip)
FetchContent_Declare(ldoc URL https://github.com/lunarmodules/LDoc/archive/refs/tags/${ldoc_zip})
FetchContent_MakeAvailable(ldoc)

# Install.
project(lsp)
install(FILES ${dkjson_SOURCE_DIR}/dkjson.lua ${ldoc_SOURCE_DIR}/ldoc.lua DESTINATION ${src})
install(DIRECTORY ${penlight_SOURCE_DIR}/lua/pl ${ldoc_SOURCE_DIR}/ldoc DESTINATION ${src})
if(NOT (WIN32 OR APPLE))
  include(GNUInstallDirs)
  set(module_dir ${CMAKE_INSTALL_FULL_DATADIR}/textadept/modules/lsp)
  install(CODE "file(MAKE_DIRECTORY ${module_dir})")
  install(FILES init.lua server.lua tadoc.lua dkjson.lua ldoc.lua DESTINATION ${module_dir})
  install(DIRECTORY lua pl ldoc DESTINATION ${module_dir})
endif()

# Documentation.
get_filename_component(ta_dir ${src}/../../ ABSOLUTE)
add_custom_target(docs DEPENDS README.md)
add_custom_command(OUTPUT ${src}/README.md
  COMMAND ldoc --filter markdowndoc.ldoc ${src}/init.lua > ${src}/README.md
  COMMAND sed -i -e "1,+4d" -e "6c# Language Server Protocol" -e "7d" -e "s/^##/#/;"
    ${src}/README.md
  DEPENDS init.lua
  WORKING_DIRECTORY ${ta_dir}/scripts
  VERBATIM)