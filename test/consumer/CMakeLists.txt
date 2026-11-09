# A C++ program using the installed hello library, found with find_package()
# and checked with pkg-config. CONSUMER_SOURCES adds sources (a Windows
# resource file for Windows targets).
cmake_minimum_required(VERSION 3.24)
project(consumer LANGUAGES CXX)

find_package(hello CONFIG REQUIRED)
find_package(PkgConfig REQUIRED)
pkg_check_modules(HELLO_PC REQUIRED hello)

add_executable(consumer consumer.cpp ${CONSUMER_SOURCES})
target_link_libraries(consumer PRIVATE hello::hello)
target_compile_definitions(consumer PRIVATE HELLO_PC_VERSION="${HELLO_PC_VERSION}")
install(TARGETS consumer)
