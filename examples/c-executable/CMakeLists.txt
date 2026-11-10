cmake_minimum_required(VERSION 3.24)
project(hello LANGUAGES C)

add_executable(hello main.c)
install(TARGETS hello)
