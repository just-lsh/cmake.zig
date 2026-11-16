# Fails to configure or build unless the C and C++ compilers target a CPU with
# AVX2, such as x86_64_v3: the configure checks, which compile and link a
# program, and the build itself must all see the requested CPU.
cmake_minimum_required(VERSION 3.24)
project(cpu_probe LANGUAGES C CXX)

include(CheckSourceCompiles)
foreach(lang IN ITEMS C CXX)
  check_source_compiles(${lang} [[
#ifndef __AVX2__
#error __AVX2__ is not defined
#endif
int main(void) { return 0; }
]] ${lang}_TARGETS_AVX2)
  if(NOT ${lang}_TARGETS_AVX2)
    message(FATAL_ERROR "${lang} configure checks do not target the requested CPU")
  endif()
endforeach()

add_library(probe STATIC probe.c probe.cpp)
install(TARGETS probe)
