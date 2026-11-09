# cmake.zig

Build CMake projects from the Zig build system, with Zig (`zig cc` / `zig c++`)
as CMake's C/C++ toolchain. The official prebuilt CMake, Ninja and Python
binaries are fetched lazily for the host, so the only requirement is Zig.

Status: early, extracted from [sdl-experimentation](https://github.com/just-lsh/sdl-experimentation).
Requires Zig 0.17.1.

See the doc comment at the top of [build.zig](build.zig) for usage.
