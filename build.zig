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

fn makeModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    register_root: bool,
) struct { root: *std.Build.Module, main: *std.Build.Module } {
    const root_options: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    };
    const root_mod = if (register_root) b.addModule("tfs", root_options) else b.createModule(root_options);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "tfs", .module = root_mod },
        },
    });

    return .{ .root = root_mod, .main = main_mod };
}

fn addModuleTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    root_path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_mod: *std.Build.Module,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "tfs", .module = root_mod },
        },
    });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = name,
        .root_module = module,
        .use_llvm = true,
    })).step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modules = makeModules(b, target, optimize, true);
    const root_mod = modules.root;
    const main_mod = modules.main;

    const root_lib = b.addLibrary(.{
        .name = "tfs",
        .linkage = .dynamic,
        .root_module = root_mod,
        .use_llvm = true,
    });

    const main_bin = b.addExecutable(.{
        .name = "tfs",
        .root_module = main_mod,
        .use_llvm = true,
    });

    const docs_dir = b.addInstallDirectory(.{
        .source_dir = root_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const run_cmd = b.addRunArtifact(main_bin);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.step.dependOn(b.getInstallStep());

    b.step("run", "Run the app").dependOn(&run_cmd.step);

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

    addModuleTests(b, test_step, "fs_tests", "src/fs.zig", target, optimize, root_mod);
    addModuleTests(b, test_step, "namespace_tests", "src/namespace.zig", target, optimize, root_mod);
    addModuleTests(b, test_step, "vfs_tests", "src/vfs.zig", target, optimize, root_mod);

    b.step("docs", "Install docs into zig-out/docs").dependOn(&docs_dir.step);

    const dist_step = b.step("dist", "Cross-compile release binaries into zig-out/dist");
    for (dist_targets) |item| {
        const dist_target = b.resolveTargetQuery(item.query);
        const dist_modules = makeModules(b, dist_target, .ReleaseFast, false);

        const dist_bin = b.addExecutable(.{
            .name = "tfs",
            .root_module = dist_modules.main,
            .use_llvm = true,
        });

        dist_step.dependOn(&b.addInstallFileWithDir(
            dist_bin.getEmittedBin(),
            .{ .custom = "dist" },
            item.output,
        ).step);
    }

    b.installArtifact(main_bin);
    b.installArtifact(root_lib);
}
