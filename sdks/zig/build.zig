// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("gtty", .{
        .root_source_file = b.path("src/gtty.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = mod });
    const step = b.step("test", "Run the SDK's tests and compile the example");
    step.dependOn(&b.addRunArtifact(tests).step);
    const example = b.createModule(.{
        .root_source_file = b.path("examples/hosts.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example.addImport("gtty", mod);
    // The example as a program gtty can start: zig-out/bin/hosts.
    b.installArtifact(b.addExecutable(.{ .name = "hosts", .root_module = example }));
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = example })).step);
}
