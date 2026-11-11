cmake_minimum_required(VERSION 3.24)
project(01_example_minimal LANGUAGES C)

add_executable(01_example_minimal main.c)
install(TARGETS 01_example_minimal)
