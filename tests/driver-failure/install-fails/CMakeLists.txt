cmake_minimum_required(VERSION 3.20)
project(install_fails NONE)

install(CODE [[message(FATAL_ERROR "driver-failure: install-fails marker")]])
