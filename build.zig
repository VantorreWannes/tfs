const std = @import("std");

const DistTarget = struct {
    query: std.Target.Query,
    output: []const u8,
};

const dist_targets = [_]DistTarget{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .output = "tfs-windows-x86_64.exe" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .output = "tfs-windows-arm64.exe" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl }, .output = "tfs-linux-x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl }, .output = "tfs-linux-arm64" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .output = "tfs-macos-x86_64" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .output = "tfs-macos-arm64" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.addModule("tfs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tfs", .module = root_mod },
        },
    });

    const root_lib = b.addLibrary(.{
        .name = "tfs",
        .linkage = .dynamic,
        .root_module = root_mod,
        .use_llvm = true,
    });

    const docs_dir = b.addInstallDirectory(.{
        .source_dir = root_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const main_bin = b.addExecutable(.{
        .name = "tfs",
        .root_module = main_mod,
        .use_llvm = true,
    });

    const root_test_bin = b.addTest(.{
        .name = "root_tests",
        .root_module = root_mod,
        .use_llvm = true,
    });

    const main_test_bin = b.addTest(.{
        .name = "main_tests",
        .root_module = main_mod,
        .use_llvm = true,
    });

    const run_cmd = b.addRunArtifact(main_bin);
    const test_root_cmd = b.addRunArtifact(root_test_bin);
    const test_main_cmd = b.addRunArtifact(main_test_bin);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&test_main_cmd.step);
    test_step.dependOn(&test_root_cmd.step);

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&docs_dir.step);

    const dist_step = b.step("dist", "Cross-compile release binaries into zig-out/dist");

    for (dist_targets) |item| {
        const resolved = b.resolveTargetQuery(item.query);

        const dist_root_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = resolved,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });

        const exe = b.addExecutable(.{
            .name = "tfs",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "tfs", .module = dist_root_mod },
                },
            }),
            .use_llvm = true,
        });

        const install = b.addInstallFileWithDir(
            exe.getEmittedBin(),
            .{ .custom = "dist" },
            item.output,
        );

        dist_step.dependOn(&install.step);
    }

    b.installArtifact(main_bin);
    b.installArtifact(root_test_bin);
    b.installArtifact(root_lib);
}
