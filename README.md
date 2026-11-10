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
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // CMake and Ninja are always fetched; Python and pkgconf (built from
    // source) on request. All of it lazily, in one pass.
    const cmake_dep = b.dependency("cmake", .{
        .python = true,
        .pkg_config = true,
    });

    const lib = cmake.addProject(cmake_dep, .{
        .name = "lib",
        .src_dir = b.path("lib"),
        .target = target,
        .optimize = optimize,
        .defines = &.{.{ "BUILD_SHARED_LIBS", .{ .boolean = true } }},
    });

    // A second project, finding the first with find_package() or pkg-config.
    const app = cmake.addProject(cmake_dep, .{
        .name = "app",
        .src_dir = b.path("app"),
        .target = target,
        .optimize = optimize,
        .defines = &.{.{ "CMAKE_PREFIX_PATH", .{ .paths = &.{lib.install_dir} } }},
        .configure_args = &.{},
        .build_args = &.{ "--target", "app" },
        .install_args = &.{"--strip"},
    });

    // Everything app installs, into zig-out/bin, zig-out/lib, ...
    cmake.installArtifacts(b, app);
}
```

`addProject` adds three steps, each depending on the one before:
`configure` (`cmake -S -B`), `build` (`cmake --build`) and `install`
(`cmake --install --prefix`). `build_dir` is an output of `configure`,
`install_dir` of `install`; zig build runs only the steps that what you use
needs.

`cmake.installArtifacts(b, project)` copies everything a project installs into
zig's install prefix (`zig-out/`), keeping CMake's layout;
`cmake.addInstallArtifacts` returns that step without adding it to
`zig build install`. To use single artifacts, a project gives their paths for the
target, in the layout of `install(TARGETS)` without a `DESTINATION`:

```zig
b.getInstallStep().dependOn(&b.addInstallBinFile(app.executable("app"), "app").step);
const static = lib.library("foo", .static); // lib/libfoo.a
const shared = lib.library("foo", .shared); // lib/libfoo.so, .dylib, bin/libfoo.dll
const link = lib.importLibrary("foo");      // lib/libfoo.dll.a on Windows
const headers = lib.includeDir();           // include/
```

`cmake.tools(cmake_dep)` gives the CMake, Ninja and Python executables
for other uses, e.g. running a Python script in a `Run` step.

Dependency options: `python`, `pkg_config`, and `cmake_exe`, `ninja_exe`,
`python_exe` to use your own tools instead of the fetched ones. See the doc
comments in [build.zig](build.zig) for all project options.

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
  source, only searches `CMAKE_PREFIX_PATH`, and runs with `--define-prefix`.
  `CMAKE_INSTALL_LIBDIR` is `lib`.
  The aim is a build that does not depend on the host, not a bit-for-bit
  reproducible one.
- **Output.** Projects build in parallel. CMake's and Ninja's output goes to
  `cmake.zig-{configure,build,install}.log` in the build directory and is only
  shown when a step fails.
- **Caching.** The build and install directories are output directories under
  `.zig-cache/o/<hash>`, where the hash covers all inputs (target, optimize
  mode, defines, arguments, the values of `Options.env`, tools, toolchain, zig).
  Each configuration has its own, so switching between them is cheap, and they
  keep their location, as CMake needs. zig build caches the configure step: it
  runs only when an input changes. Build and install always run; Ninja and
  CMake decide what is out of date, and Ninja re-runs CMake when a
  `CMakeLists.txt` changes. Old configurations' directories stay until
  `.zig-cache` is deleted, and deleting one build directory alone needs
  `.zig-cache` deleted too, as zig build does not notice it.

## Limitations

- Prebuilt tools exist for Linux (glibc), macOS and Windows on x86_64 and
  aarch64. On other hosts, pass your own with the `cmake_exe`, `ninja_exe` and
  `python_exe` dependency options.
- The install prefix is only given to `cmake --install`, as the install step's
  directory is not known when configuring. Installed CMake package files are
  relocatable, and pkgconf derives a `.pc` file's prefix from its location, but
  other files that record `CMAKE_INSTALL_PREFIX` while configuring get CMake's
  default.
- Cross-compiling for macOS covers what zig ships (libc, libc++). Apple
  frameworks need an SDK, which this package does not provide.
- Windows targets use MinGW. The MSVC ABI would need the Windows SDK.

## Development

The Zig and ZLS releases used for development and CI are pinned in `zig/`. They
are not checked in, download them first:

```sh
./zig/download.sh && ./zig/zls/download.sh       # Linux, macOS
zig\download.cmd && zig\zls\download.cmd         # Windows
```

This installs `zig/zig` and `zig/zls/zls`; put `zig/` on your `PATH` (`shell.nix`
does that on NixOS). To
update a release, follow the steps at the top of `zig/download.sh` and
`zig/zls/download.sh`.

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
