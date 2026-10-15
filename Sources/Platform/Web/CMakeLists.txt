# HIP Toolkit — Web (WebAssembly) build.
# Configure with emcmake; Scripts/build-web.sh does this for you.

cmake_minimum_required(VERSION 3.20)
project(HIPToolkitWeb C CXX)

if(NOT EMSCRIPTEN)
    message(FATAL_ERROR "Configure with emcmake (see Scripts/build-web.sh)")
endif()

# Bundled package: web,worker. Tests under Node: -DHIP_WEB_ENV=web,worker,node
set(HIP_WEB_ENV "web,worker" CACHE STRING "Emscripten -sENVIRONMENT value")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(ROOT   ${CMAKE_CURRENT_SOURCE_DIR}/../../..)
set(CORE   ${ROOT}/Sources/Core)
set(VENDOR ${ROOT}/Vendor)

# All of Core, as in HIP.Core.vcxproj
file(GLOB CORE_SOURCES ${CORE}/*.cpp)

# Lua (same set as HIP.Core.vcxproj: everything except the standalone tools)
file(GLOB LUA_SOURCES ${VENDOR}/lua/*.c)
list(FILTER LUA_SOURCES EXCLUDE REGEX "/(print|lua|luac)\\.c$")

# Minimal ffmpeg (Bink demuxer + decoder + swscale), built by
# Scripts/build-web-ffmpeg.sh into build/ffmpeg/out.
set(FFMPEG_PREFIX ${ROOT}/build/ffmpeg/out CACHE PATH "Emscripten ffmpeg install prefix")
if(NOT EXISTS ${FFMPEG_PREFIX}/lib/libavcodec.a)
    message(FATAL_ERROR "ffmpeg for WebAssembly not found in ${FFMPEG_PREFIX} — run Scripts/build-web-ffmpeg.sh")
endif()

# luadec sources (Scripts/build-web-luadec.sh), built against Vendor/lua.
set(LUADEC_DIR ${ROOT}/build/luadec/src/luadec CACHE PATH "luadec source directory")
if(NOT EXISTS ${LUADEC_DIR}/luadec.c)
    message(FATAL_ERROR "luadec sources not found in ${LUADEC_DIR} — run Scripts/build-web-luadec.sh")
endif()
set(LUADEC_SOURCES
    ${LUADEC_DIR}/guess.c ${LUADEC_DIR}/luadec.c ${LUADEC_DIR}/decompile.c
    ${LUADEC_DIR}/disassemble.c ${LUADEC_DIR}/proto.c ${LUADEC_DIR}/StringBuffer.c
    ${LUADEC_DIR}/structs.c ${LUADEC_DIR}/statement.c ${LUADEC_DIR}/macro-array.c
    ${LUADEC_DIR}/expression.c)
set_source_files_properties(${LUADEC_SOURCES} PROPERTIES
    COMPILE_OPTIONS "-w"
    COMPILE_DEFINITIONS "SRCVERSION=\"895d923\";main=luadec_main;exit=hip_luadec_exit")

add_executable(hip
    HIPWeb.cpp
    BIKDecoder.cpp
    LuaDecompiler.cpp
    ${LUADEC_SOURCES}
    ${CORE_SOURCES}
    ${LUA_SOURCES}
    ${VENDOR}/stb_vorbis.c
    ${VENDOR}/libvorbis/src/vorbis_compile.c
    ${VENDOR}/libshine/src/shine_compile.c
    ${VENDOR}/stb_image_impl.c
    ${VENDOR}/stb_image_write_impl.c
)

target_include_directories(hip PRIVATE
    ${CORE}
    ${VENDOR}
    ${VENDOR}/lua
    ${VENDOR}/libogg/include
    ${VENDOR}/libvorbis/include
    ${VENDOR}/libvorbis/src
    ${VENDOR}/libshine/src
    ${FFMPEG_PREFIX}/include
)

target_link_libraries(hip PRIVATE
    ${FFMPEG_PREFIX}/lib/libavformat.a
    ${FFMPEG_PREFIX}/lib/libavcodec.a
    ${FFMPEG_PREFIX}/lib/libswscale.a
    ${FFMPEG_PREFIX}/lib/libavutil.a
)

# Third-party C is noisy; keep our own sources warning-clean.
set_source_files_properties(${LUA_SOURCES}
    ${VENDOR}/stb_vorbis.c
    ${VENDOR}/libvorbis/src/vorbis_compile.c
    ${VENDOR}/libshine/src/shine_compile.c
    ${VENDOR}/stb_image_impl.c
    ${VENDOR}/stb_image_write_impl.c
    PROPERTIES COMPILE_OPTIONS "-w")

target_compile_options(hip PRIVATE -O3 -fwasm-exceptions -sSUPPORT_LONGJMP=wasm)

target_link_options(hip PRIVATE
    -O3
    -fwasm-exceptions
    -sSUPPORT_LONGJMP=wasm
    --bind
    -sMODULARIZE=1
    -sEXPORT_ES6=1
    -sEXPORT_NAME=createHIPModule
    -sENVIRONMENT=${HIP_WEB_ENV}
    -sALLOW_MEMORY_GROWTH=1
    -sMAXIMUM_MEMORY=4GB
    -sFILESYSTEM=1
    -sEXPORTED_RUNTIME_METHODS=FS
    # Embed the wasm in hip.mjs: bundlers (Turbopack, webpack) rewrite asset
    # URLs inside workers differently, and a single file sidesteps all of it.
    -sSINGLE_FILE=1
)

set_target_properties(hip PROPERTIES SUFFIX ".mjs")
