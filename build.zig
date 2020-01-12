const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("softrenderlib", "src/main.zig");
    exe.setBuildMode(mode);
    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("sdl2");
    exe.addPackagePath("sdl2", "SDL.zig/src/lib.zig");
    exe.addPackagePath("zgl", "zig-gamedev-lib/src/lib.zig");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
