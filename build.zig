const std = @import("std");

// Dwa portable warianty:
//  - armhf: ARMv7 + VFPv3-D16, BEZ NEON (dziala i na CPU bez NEON, czesc ARM STB)
//  - mipsel: MIPS32 r1 (starsze Broadcomy, starsze MIPS STB; r2 daje SIGILL)
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
