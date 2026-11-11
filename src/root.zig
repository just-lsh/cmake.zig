const std = @import("std");

pub const Project = struct {
    configure: *std.Build.Step.Run,
    build: *std.Build.Step.Run,
    install: *std.Build.Step.Run,

    pub fn addConfigureArg(self: *Project, arg: []const u8) void {
        self.configure.addArg(arg);
    }
};

pub const AddProjectConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
};

pub fn addProject(b: *std.Build, dep: *std.Build.Dependency, config: AddProjectConfig) Project {
    const cmake = dep.namedLazyPath("cmake");
    const ninja = dep.namedLazyPath("ninja");

    const configure = b.addRunFile(cmake);

    const build = b.addRunFile(cmake);

    const install = b.addRunFile(cmake);

    return .{
        .configure = configure,
        .build = build,
        .install = install,
    };
}
