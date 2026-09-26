const std = @import("std");

// Two portable flavours:
//  - armhf: ARMv7 + VFPv3-D16, NO NEON (some ARM STB SoCs lack it; this build runs on them too)
//  - mipsel: MIPS32 r1 (older Broadcom MIPS STBs; r2 instructions SIGILL there)
const targets = [_]struct { name: []const u8, triple: []const u8, cpu: []const u8 }{
    .{ .name = "satscan-armhf", .triple = "arm-linux-musleabihf", .cpu = "generic+v7a+vfp3d16-neon" },
    .{ .name = "satscan-mipsel", .triple = "mipsel-linux-musl", .cpu = "mips32" },
};

pub fn build(b: *std.Build) void {
    for (targets) |t| {
        const query = std.Target.Query.parse(.{
            .arch_os_abi = t.triple,
            .cpu_features = t.cpu,
        }) catch unreachable;
        const exe = b.addExecutable(.{
            .name = t.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = b.resolveTargetQuery(query),
                .optimize = .ReleaseSmall,
            }),
        });
        b.installArtifact(exe);
    }
}
