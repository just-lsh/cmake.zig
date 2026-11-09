# cmake.zig

Build CMake projects from the Zig build system, with Zig (`zig cc` / `zig c++`)
as CMake's C/C++ toolchain. CMake, Ninja and Python are the official prebuilt
binaries, fetched lazily for the host, so the only requirement is Zig, on Linux,
macOS and Windows (x86_64 and aarch64). The target can be anything zig can
target.

Requires Zig 0.17.1. Status: early.

## Usage

```sh
zig fetch --save git+https://github.com/just-lsh/cmake.zig
```

```zig
const cmake_zig = @import("cmake_zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("cmake_zig", .{});

    const lib = cmake_zig.addProject(b, dep, .{
        .source_dir = b.path("lib"),
        .target = target,
        .optimize = optimize,
        .defines = &.{.{ "BUILD_SHARED_LIBS", .{ .boolean = true } }},
    }) orelse return; // null until the host's tools are fetched

    // A second project, finding the first with find_package() or pkg-config.
    const app = cmake_zig.addProject(b, dep, .{
        .name = "app",
        .source_dir = b.path("app"),
        .target = target,
        .optimize = optimize,
        .pkg_config = true,
        .defines = &.{.{ "CMAKE_PREFIX_PATH", .{ .paths = &.{lib.install_dir.?} } }},
    }) orelse return;

    b.installDirectory(.{ .source_dir = app.install_dir.?, .install_dir = .prefix, .install_subdir = "" });
}
```

`addProject` returns one step that configures (when needed), builds
(`cmake --build`) and installs (`cmake --install`) the project. Its
`install_dir` and `build_dir` are ordinary `LazyPath`s that depend on that step.
See the doc comments in [build.zig](build.zig) for all options. `hostTools(dep)`
gives the CMake, Ninja and Python executables for other uses, e.g. running a
Python script in a `Run` step.

## How it works

- **Toolchain.** [toolchain/zig.cmake](toolchain/zig.cmake) sets the compilers to
  small launchers, built by zig for the host, which run `zig cc`, `zig c++`,
  `zig ar`, `zig ranlib` and `zig rc` with the zig that runs the build.
- **Targets.** A native target (no `-Dtarget`/`-Dcpu`) is a host build.
  Otherwise zig cc gets `-target` and `-mcpu`, and CMake gets
  `CMAKE_SYSTEM_NAME` and `CMAKE_SYSTEM_PROCESSOR` when the OS or CPU
  architecture differs from the host's (so `CMAKE_CROSSCOMPILING` is set).
  Windows targets use the GNU ABI (MinGW), with `zig rc` for resources.
- **Build types.** The optimize mode picks `CMAKE_BUILD_TYPE` and its flags:
  Debug and ReleaseSafe have debug info, ReleaseFast and ReleaseSmall have none.
  As in zig, Debug builds trap undefined behaviour (zig cc enables UBSan at
  `-O0`).
- **Isolation.** The environment is reduced to what the tools need to run
  (`Options.env` adds variables), and CMake's system search paths and package
  registries are turned off, unless the build is for the host or
  `Options.host_system` is set. With `.pkg_config = true`, pkgconf is built from
  source and only searches `CMAKE_PREFIX_PATH`. `CMAKE_INSTALL_LIBDIR` is `lib`.
  The aim is a build that does not depend on the host, not a bit-for-bit
  reproducible one.
- **Caching.** The build and install directories are output directories of the
  step, under `.zig-cache/o/<hash>`, where the hash covers all inputs (target,
  optimize mode, defines, tools, toolchain, zig). Each configuration has its own,
  so switching between them is cheap. The directories keep their location, as
  CMake needs. A stamp file in the build directory records how it was
  configured; configuring runs again only if the build directory is new or was
  deleted, or a variable in `Options.env` changed. After that, Ninja decides what
  is out of date. Old configurations' directories stay until `.zig-cache` is
  deleted.

## Limitations

- Prebuilt tools exist for Linux (glibc), macOS and Windows on x86_64 and
  aarch64. On other hosts, pass your own via `Options.tools`.
- Cross-compiling for macOS covers what zig ships (libc, libc++). Apple
  frameworks need an SDK, which this package does not provide.
- Windows targets use MinGW. The MSVC ABI would need the Windows SDK.

## Development

```sh
cd test && zig build test cross   # build the test projects, natively and cross
zig build update-tools -- cmake=4.4.5 ninja=1.13.2 python=3.13.18+20261026 pkgconf=3.0.10
```

`update-tools` rewrites the tool URLs and hashes in `build.zig.zon` and
`src/versions.zig`. It fetches with a temporary cache, as a tarball left in the
global cache would be unpacked into `zig-pkg/` even for lazy dependencies.

## License

MIT; see [LICENSE](LICENSE). CMake (BSD-3-Clause), Ninja (Apache-2.0), Python
(PSF) and pkgconf (ISC) are fetched from their upstream releases, not
redistributed.
