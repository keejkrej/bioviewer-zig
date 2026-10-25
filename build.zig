const std = @import("std");
const native_sdk = @import("native_sdk");

pub fn build(b: *std.Build) void {
    const native_dep = b.dependency("native_sdk", .{});
    const artifacts = native_sdk.addAppArtifacts(b, native_dep, .{
        .name = "bioviewer",
        .manifest = "app.zon",
    });

    wireMicroscopyModules(b, artifacts.exe.root_module);
    if (artifacts.tests.root_module != artifacts.exe.root_module) {
        wireMicroscopyModules(b, artifacts.tests.root_module);
    }
}

fn wireMicroscopyModules(b: *std.Build, mod: *std.Build.Module) void {
    const czi_dep = b.dependency("czi", .{
        .target = mod.resolved_target,
        .optimize = mod.optimize,
    });
    const nd2_dep = b.dependency("nd2", .{
        .target = mod.resolved_target,
        .optimize = mod.optimize,
    });
    mod.addImport("czi", czi_dep.module("czi"));
    mod.addImport("nd2", nd2_dep.module("nd2"));
}
