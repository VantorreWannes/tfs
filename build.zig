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
    // Options
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Modules
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

    // Libraries
    const root_lib = b.addLibrary(.{
        .name = "tfs",
        .linkage = .dynamic,
        .root_module = root_mod,
        .use_llvm = true,
    });

    // Directories
    const docs_dir = b.addInstallDirectory(.{
        .source_dir = root_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    // Binaries
    const main_bin = b.addExecutable(.{
        .name = "tfs",
        .root_module = main_mod,
        .use_llvm = true,
    });

    // Commands
    const run_cmd = b.addRunArtifact(main_bin);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    // Steps - Run
    b.step("run", "Run the app").dependOn(&run_cmd.step);

    // Steps - Tests
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "root_tests",
        .root_module = root_mod,
        .use_llvm = true,
    })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "main_tests",
        .root_module = main_mod,
        .use_llvm = true,
    })).step);

    // Steps - Docs
    b.step("docs", "Install docs into zig-out/docs").dependOn(&docs_dir.step);

    // Steps - Dist
    const dist_step = b.step("dist", "Cross-compile release binaries into zig-out/dist");
    for (dist_targets) |item| {
        const dist_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = b.resolveTargetQuery(item.query),
            .optimize = .ReleaseFast,
            .link_libc = true,
        });

        const dist_bin = b.addExecutable(.{
            .name = "tfs",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(item.query),
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "tfs", .module = dist_mod },
                },
            }),
            .use_llvm = true,
        });

        dist_step.dependOn(&b.addInstallFileWithDir(
            dist_bin.getEmittedBin(),
            .{ .custom = "dist" },
            item.output,
        ).step);
    }

    // Install
    b.installArtifact(main_bin);
    b.installArtifact(root_lib);
}
