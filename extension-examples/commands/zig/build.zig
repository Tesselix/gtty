// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gtty = b.dependency("gtty", .{ .target = target, .optimize = optimize }).module("gtty");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("gtty", gtty);
    // The rules' tests read the cases every language shares.
    mod.addAnonymousImport("cases", .{ .root_source_file = b.path("../cases.tsv") });
    // zig-out/bin/commands: the program gtty starts.
    b.installArtifact(b.addExecutable(.{ .name = "commands", .root_module = mod }));
    const step = b.step("test", "Run the tests");
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
}
