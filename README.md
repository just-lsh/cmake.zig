# cmake.zig

Build CMake projects from the Zig build system. `cmake.zig` configures, builds
and installs a fetched CMake source package in one cached build step, compiling
C and C++ with `zig cc` and `zig c++`. Your `build.zig` then consumes the
installed libraries and headers like any other generated file.

It is meant for controlled, remotely fetched CMake dependencies, not for CMake
projects you are editing. Read [Cache contracts](#cache-contracts) before using
it.

## Requirements

- Zig 0.17.0 to 0.17.1. Other versions fail at build time with a version error.
- One of these hosts: Linux, Windows or macOS, each on x86_64 or aarch64.
- Nothing else. CMake 4.4.5 and Ninja 1.13.2 are fetched for the host on first
  use, unless you [supply your own](#using-a-different-cmake-or-ninja).

Projects are built for the `target` you pass, including its CPU model and
features. When its OS or architecture differs from the host, CMake is told the
target system and configures as a cross build, so it does not try to run target
binaries. The target's `dynamic_linker` and `ofmt` overrides are not forwarded.

## Install

Add `cmake.zig` and the CMake project you want to build to your
`build.zig.zon`:

```sh
zig fetch --save git+https://github.com/just-lsh/cmake.zig
zig fetch --save=hello https://example.com/hello-1.0.0.tar.gz
```

The first command adds a dependency named `cmake`. The second stands for any
CMake source package; give it the name you will use in `build.zig`.

## Usage

```zig
const std = @import("std");
const cmake = @import("cmake");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cmake_dep = b.dependency("cmake", .{});
    const hello_src = b.dependency("hello", .{});

    const hello = cmake.addProject(b, cmake_dep, .{
        .src_dir = hello_src.path("."),
        .target = target,
        .optimize = optimize,
        .defines = &.{
            .{ .name = "HELLO_LOUD", .value = "ON" },
        },
    });

    // Translate the installed header into a Zig module.
    const hello_c = b.addTranslateC(.{
        .root_source_file = hello.install_dir.path(b, "include/hello.h"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hello", .module = hello_c.createModule() },
            },
        }),
    });
    // The library file name depends on the project and the platform.
    exe.root_module.addObjectFile(hello.install_dir.path(b, "lib/libhello.a"));
    b.installArtifact(exe);
}
```

`@import("cmake")` loads the `cmake.zig` build script; `b.dependency("cmake", ...)`
gives `addProject` the tools it runs. Anything taken from `install_dir` depends
on the CMake step automatically, so there is no step to wire up by hand.

### `addProject(b, dep, options) Project`

| Option       | Type                       | Meaning                                                             |
| ------------ | -------------------------- | ------------------------------------------------------------------- |
| `src_dir`    | `std.Build.LazyPath`       | Root of the CMake source package, holding `CMakeLists.txt`          |
| `target`     | `std.Build.ResolvedTarget` | Target and CPU the project is compiled and linked for               |
| `optimize`   | `std.lang.Optimize`        | Selects the CMake build type, see below                             |
| `defines`    | `[]const Define`           | Passed as `-D<name>=<value>`, in order. Default: none               |
| `extra_args` | `[]const []const u8`       | Appended verbatim to the configure command. Default: none           |

The returned `Project` has:

- `install_dir`: the CMake install prefix, a generated `LazyPath`. Installed
  file paths below it (`lib/`, `include/`, `bin/`, the library file names)
  are set by the project and the platform.
- `run`: the `std.Build.Step.Run` that does the work, if you need to depend on
  it directly.

`optimize` maps to CMake as follows:

| Zig            | `CMAKE_BUILD_TYPE` | C and C++ flags    | Linker flags |
| -------------- | ------------------ | ------------------ | ------------ |
| `Debug`        | `Debug`            | `-O0 -g`           |              |
| `ReleaseSafe`  | `RelWithDebInfo`   | `-O2 -g`           |              |
| `ReleaseFast`  | `Release`          | `-O3 -g0 -DNDEBUG` | `-s`         |
| `ReleaseSmall` | `MinSizeRel`       | `-Os -g0 -DNDEBUG` | `-s`         |

## Cache contracts

Each `addProject` call is one Zig `Run` step with one output directory. When
its inputs match a previous run, Zig reuses that output and CMake is not run
at all. The inputs Zig sees are listed below; anything else that affects the
build is not seen, and the following contracts are what keep a cache hit
correct.

### Sources are immutable

Only the **path** of `src_dir` is part of the cache key, not the contents of
the files in it. A fetched package lives in a directory named after its hash,
so a new version means a new path and a new cache entry.

Editing files in a source directory therefore does not invalidate the cache:
the next build reuses the old result. Point `src_dir` only at fetched packages
that nothing modifies. Editable local source directories are not supported.

### External dependencies are your responsibility

The build inherits your environment and can find SDKs, system libraries, and
other tools on your machine. None of that is part of the cache key. If a
change outside the declared inputs affects the build (an environment
variable, an updated SDK, a system library found by `find_package`), Zig still
sees the same inputs and gives you the old result.

Represent anything that matters in the configuration, for example as a
define holding a version or a path, so that a change to it changes the key.
Do not modify a cached output after the fact.

### What is in the cache key

- The `cmake-driver` and `ninja-wrapper` tools and the `zig cc`, `zig c++`,
  `zig ar`, `zig rc` and `zig ranlib` wrappers that `cmake.zig` compiles
- The CMake and Ninja executables
- The path of `src_dir`
- The target triple and CPU, unless the target is the native default.
- The configure arguments: the build type and flags from `optimize`, then
  `defines`, then `extra_args`

The configure arguments are compared as an ordered list. The same defines in
a different order are a different key, so a cache miss and a full rebuild.
Keep the order stable, for example by writing defines as a literal list rather
than building them from an unordered map.

## Tradeoffs

- **Progress is hidden.** CMake and Ninja output is captured, so configure and
  build progress is not shown. When the step fails, Zig reports the failing
  command and the captured diagnostics. On success, only what is written to
  stderr (such as CMake warnings) is shown.
- **Every cache miss is a cold build.** There is no incremental build state
  between configurations: changing any input reconfigures and rebuilds the
  whole project from scratch. Each configuration (optimization mode, set of
  defines) keeps its own copy in the cache, including CMake's intermediate
  build files.
- **Installed artifacts are not relocatable.** They may contain absolute paths
  into the Zig cache (for example in generated CMake or pkg-config files).
  Consume them in place; copying them elsewhere is not guaranteed to work.
- **Long paths on Windows.** The project is built deep inside the Zig cache.
  If your project sits in a deep directory, CMake may warn about object file
  paths approaching its length limit.

## Using a different CMake or Ninja

`cmake.zig` has two build options, `cmake` and `ninja`, each a path to an
executable that replaces the fetched one. The fetched tool is then not
downloaded. Set them as arguments of the dependency, here forwarded from your
own `-Dcmake` and `-Dninja` options:

```zig
const cmake_dep = b.dependency("cmake", .{
    .cmake = b.option(std.Build.LazyPath, "cmake", "CMake executable to use"),
    .ninja = b.option(std.Build.LazyPath, "ninja", "Ninja executable to use"),
});
```

```sh
zig build -Dcmake=/usr/bin/cmake -Dninja=/usr/bin/ninja
```

The executables you supply are part of the cache key, so switching to a
different one is a cache miss.

## License

MIT, see [LICENSE](LICENSE).
