# Zig (zig cc / zig c++) as the C/C++ toolchain on Windows hosts.
# cmake.zig picks this file and sets everything else on the command line.
# ZIG_TARGET_ARGS holds the compiler's target arguments (empty for native).
set(CMAKE_C_COMPILER "${CMAKE_CURRENT_LIST_DIR}/zig/cc.cmd" ${ZIG_TARGET_ARGS})
set(CMAKE_CXX_COMPILER "${CMAKE_CURRENT_LIST_DIR}/zig/c++.cmd" ${ZIG_TARGET_ARGS})
set(CMAKE_AR "${CMAKE_CURRENT_LIST_DIR}/zig/ar.cmd" CACHE FILEPATH "")
set(CMAKE_RANLIB "${CMAKE_CURRENT_LIST_DIR}/zig/ranlib.cmd" CACHE FILEPATH "")
# try_compile() projects re-read this file, so they need ZIG_TARGET_ARGS too.
set(CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ZIG_TARGET_ARGS)
