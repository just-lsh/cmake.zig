cmake_minimum_required(VERSION 3.24)
project(fixture LANGUAGES C)

add_library(fixture STATIC src/fixture.c)
target_include_directories(fixture PUBLIC
  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
  $<INSTALL_INTERFACE:include>
)

install(TARGETS fixture)
install(FILES include/fixture.h TYPE INCLUDE)
