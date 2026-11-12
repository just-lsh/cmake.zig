cmake_minimum_required(VERSION 3.24)
project(minimal LANGUAGES C)

add_executable(${PROJECT_NAME} main.c)
install(TARGETS ${PROJECT_NAME})
