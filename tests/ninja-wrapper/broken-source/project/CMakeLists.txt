cmake_minimum_required(VERSION 3.24)
project(broken LANGUAGES C)

add_executable(${PROJECT_NAME} broken.c)
install(TARGETS ${PROJECT_NAME})
