# Zig as the C/C++ toolchain. cmake.zig sets the ZIG_* variables on the
# command line: the zig cc/c++/ar/ranlib/rc launchers it builds and the
# compiler's target arguments (empty for the native target).
set(CMAKE_C_COMPILER "${ZIG_CC}" ${ZIG_TARGET_ARGS})
set(CMAKE_CXX_COMPILER "${ZIG_CXX}" ${ZIG_TARGET_ARGS})
set(CMAKE_AR "${ZIG_AR}" CACHE FILEPATH "")
set(CMAKE_RANLIB "${ZIG_RANLIB}" CACHE FILEPATH "")
set(CMAKE_RC_COMPILER "${ZIG_RC}" CACHE FILEPATH "")
# try_compile() projects re-read this file, so they need the variables too.
set(CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ZIG_CC ZIG_CXX ZIG_AR ZIG_RANLIB ZIG_RC ZIG_TARGET_ARGS)
