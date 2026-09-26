// Tuner/dish configuration from /etc/enigma2/settings: which orbital positions
// each NIM reaches and how the signal path is selected (committed DiSEqC port,
// DiSEqC 1.1 uncommitted port, Unicable SCR). Nothing here touches hardware.

const std = @import("std");
const dvb = @import("dvb.zig");

pub const NimMode = enum { unknown, simple, advanced, nothing, equal, loopthrough, satposdepends };
pub const MAX_NIMS = 16;
// Positions per NIM. Real cascaded dishes reach 8 positions; the old limit of 8
// silently dropped the ninth and could lose the target depending on line order.
const MAX_SATS = 16;
const MAX_LNB = 33; // enigma numbers advanced LNB blocks 1..32

/// One tuner's dish setup.
pub const NimCfg = struct {
    seen: bool = false,
    mode: NimMode = .unknown,
    single: bool = false, // diseqcMode=single -> never send a switch command
    ab_only: bool = false, // diseqcMode=toneburst_a_b / diseqc_a_b -> only ports 0 and 1 exist
    positions: [MAX_SATS]u32 = [_]u32{0} ** MAX_SATS,
    ports: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS,
    has_port: [MAX_SATS]bool = [_]bool{false} ** MAX_SATS,
    /// From `advanced.sat.*` — these entries only count in advanced mode, see
    /// finalize(): images keep stale advanced blocks around while running simple.
    from_advanced: [MAX_SATS]bool = [_]bool{false} ** MAX_SATS,
    // Uncommitted DiSEqC (1.1) port per position, and, for advanced mode, the LNB
    // block each position maps to. In advanced dishes the DiSEqC commands live in
    // the LNB block (advanced.lnb.<N>.*), not the sat block, so we buffer them and
    // resolve position -> lnb -> {committed, uncommitted} in finalize().
    uports: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS,
    has_uport: [MAX_SATS]bool = [_]bool{false} ** MAX_SATS,
    lnb_of: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS, // 0 = unset
    lnb_comm: [MAX_LNB]i16 = [_]i16{-1} ** MAX_LNB,
    lnb_uncomm: [MAX_LNB]i16 = [_]i16{-1} ** MAX_LNB,
    nsat: usize = 0,
    dropped: bool = false, // MAX_SATS overflow happened
    unicable: bool = false, // from the advanced LNB block
    scr_slot: u8 = 0,
    scr_freq: u32 = 0,

    // The advanced LNB block (incl. unicable) only applies in advanced mode.
    pub fn usesUnicable(self: NimCfg) bool {
        return self.unicable and self.scr_freq != 0 and self.mode == .advanced;
    }

    fn find(self: NimCfg, pos: u32) ?usize {
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] == pos) return i;
        }
        return null;
    }

    fn addSat(self: *NimCfg, pos: u32, port: ?u8, advanced: bool) void {
        if (self.find(pos)) |i| {
            // First assignment wins: images keep stale duplicates (e.g.
            // diseqcA=130 alongside diseqcD=130), and letting the later one
            // through would move 13E onto port 3.
            if (port) |pt| {
                if (!self.has_port[i]) {
                    self.ports[i] = pt;
                    self.has_port[i] = true;
                }
            }
            if (!advanced) self.from_advanced[i] = false; // a simple-mode key confirms it
            return;
        }
        if (self.nsat >= MAX_SATS) {
            self.dropped = true;
            return;
        }
        self.positions[self.nsat] = pos;
        self.from_advanced[self.nsat] = advanced;
        if (port) |pt| {
            self.ports[self.nsat] = pt;
            self.has_port[self.nsat] = true;
        }
        self.nsat += 1;
    }

    fn setSatLnb(self: *NimCfg, pos: u32, lnb: u8) void {
        self.addSat(pos, null, true);
        if (self.find(pos)) |i| self.lnb_of[i] = lnb;
    }

    /// Resolve advanced position -> LNB block -> ports, and drop positions that
    /// exist only because of stale `advanced.sat.*` keys on a NIM that is not in
    /// advanced mode (otherwise a simple-mode dish would "reach" a satellite it
    /// has no port for and report NoLock instead of PositionNotConfigured).
    fn finalize(self: *NimCfg, idx: usize) void {
        if (self.dropped) std.debug.print("[satscan] NIM{d}: more than {d} positions in settings - extra ones ignored\n", .{ idx, MAX_SATS });
        if (self.mode != .advanced) {
            var i: usize = 0;
            while (i < self.nsat) {
                if (self.from_advanced[i]) {
                    self.nsat -= 1;
                    self.positions[i] = self.positions[self.nsat];
                    self.ports[i] = self.ports[self.nsat];
                    self.has_port[i] = self.has_port[self.nsat];
                    self.from_advanced[i] = self.from_advanced[self.nsat];
                    self.lnb_of[i] = self.lnb_of[self.nsat];
                } else i += 1;
            }
            return;
        }
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            const lnb = self.lnb_of[i];
            if (lnb == 0 or lnb >= MAX_LNB) continue;
            if (!self.has_port[i] and self.lnb_comm[lnb] >= 0) {
                self.ports[i] = @intCast(self.lnb_comm[lnb]);
                self.has_port[i] = true;
            }
            if (self.lnb_uncomm[lnb] > 0) { // 0 = no uncommitted switch
                self.uports[i] = @intCast(self.lnb_uncomm[lnb]);
                self.has_uport[i] = true;
            }
        }
    }

    pub fn uportFor(self: NimCfg, pos: u32) ?u8 {
        const i = self.find(pos) orelse return null;
        return if (self.has_uport[i]) self.uports[i] else null;
    }

    // An A/B switch only has ports 0 and 1; diseqcC/D are stale leftovers there.
    fn portUsable(self: NimCfg, i: usize) bool {
        return self.has_port[i] and !(self.ab_only and self.ports[i] > 1);
    }

    pub fn handles(self: NimCfg, pos: u32) bool {
        if (self.mode == .nothing) return false;
        const i = self.find(pos) orelse return false;
        // in A/B mode a position only reachable through port C/D is not reachable
        return !(self.ab_only and self.has_port[i] and self.ports[i] > 1);
    }

    /// committed DiSEqC port for this position, or null when no switch is used
    pub fn portFor(self: NimCfg, pos: u32) ?u8 {
        if (self.single) return null;
        const i = self.find(pos) orelse return null;
        return if (self.portUsable(i)) self.ports[i] else null;
    }

    /// The complete signal-path selection for `pos` (CLI overrides win).
    pub fn switchFor(self: NimCfg, pos: u32, cli_scr: ?dvb.Scr, cli_port: ?u8) dvb.Switch {
        return .{
            .scr = cli_scr orelse (if (self.usesUnicable()) dvb.Scr{ .slot = self.scr_slot, .freq_mhz = self.scr_freq } else null),
            .committed = cli_port orelse self.portFor(pos),
            .uncommitted = self.uportFor(pos),
        };
    }
};

// enigma stores committed commands as AA/AB/BA/BB (port 0..3)
fn parseCommitted(v: []const u8) ?u8 {
    if (v.len < 2) return null;
    const hi: u8 = switch (v[0]) {
        'A' => 0,
        'B' => 2,
        else => return null,
    };
    const lo: u8 = switch (v[1]) {
        'A' => 0,
        'B' => 1,
        else => return null,
    };
    return hi + lo;
}

fn valueAfterEq(kv: []const u8) []const u8 {
    const eq = std.mem.lastIndexOfScalar(u8, kv, '=') orelse return "";
    return kv[eq + 1 ..];
}

fn isKey(kv: []const u8, key: []const u8) bool {
    return std.mem.startsWith(u8, kv, key) and kv.len > key.len and kv[key.len] == '=';
}

pub fn parse(alloc: std.mem.Allocator, path: [*:0]const u8, nims: []NimCfg) bool {
    const file = dvb.readFile(alloc, path, 1024 * 1024) orelse return false;
    defer file.deinit(alloc);
    var lines = std.mem.splitScalar(u8, file.data, '\n');
    const prefix = "config.Nims.";
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
        const idx = std.fmt.parseInt(u8, rest[0..dot], 10) catch continue;
        if (idx >= nims.len) continue;
        const c = &nims[idx];
        c.seen = true;
        var kv = rest[dot + 1 ..];
        // newer images group keys per tuner type: config.Nims.0.dvbs.diseqcA=130
        if (std.mem.startsWith(u8, kv, "dvbs.")) kv = kv["dvbs.".len..];
        if (isKey(kv, "configMode")) {
            const v = valueAfterEq(kv);
            c.mode = std.meta.stringToEnum(NimMode, v) orelse .unknown;
        } else if (std.mem.startsWith(u8, kv, "diseqc") and kv.len > 7 and kv[7] == '=') {
            // simple mode: diseqcA..D = orbital position on committed port 0..3
            const port: u8 = switch (kv[6]) {
                'A' => 0,
                'B' => 1,
                'C' => 2,
                'D' => 3,
                else => continue,
            };
            if (std.fmt.parseInt(u32, valueAfterEq(kv), 10) catch null) |pos| c.addSat(pos, port, false);
        } else if (isKey(kv, "diseqcMode")) {
            const v = valueAfterEq(kv);
            if (std.mem.eql(u8, v, "single")) {
                c.single = true;
            } else if (std.mem.eql(u8, v, "toneburst_a_b") or std.mem.eql(u8, v, "diseqc_a_b")) {
                c.ab_only = true;
            }
        } else if (std.mem.startsWith(u8, kv, "advanced.sat.")) {
            // advanced mode: advanced.sat.<pos>.<key>=<value>
            const rest2 = kv["advanced.sat.".len..];
            const dot2 = std.mem.indexOfScalar(u8, rest2, '.') orelse continue;
            const pos = std.fmt.parseInt(u32, rest2[0..dot2], 10) catch continue;
            const sub = rest2[dot2 + 1 ..];
            if (isKey(sub, "commitedDiseqcCommand") or isKey(sub, "committedDiseqcCommand")) {
                c.addSat(pos, parseCommitted(valueAfterEq(sub)), true);
            } else if (isKey(sub, "lnb")) {
                c.setSatLnb(pos, std.fmt.parseInt(u8, valueAfterEq(sub), 10) catch 0);
            } else {
                c.addSat(pos, null, true);
            }
        } else if (std.mem.startsWith(u8, kv, "advanced.lnb.")) {
            // advanced.lnb.<N>.<key>=<value> — the DiSEqC commands for that block
            const rest2 = kv["advanced.lnb.".len..];
            const dot2 = std.mem.indexOfScalar(u8, rest2, '.') orelse continue;
            const n = std.fmt.parseInt(u8, rest2[0..dot2], 10) catch continue;
            if (n == 0 or n >= MAX_LNB) continue;
            const sub = rest2[dot2 + 1 ..];
            if (isKey(sub, "commitedDiseqcCommand") or isKey(sub, "committedDiseqcCommand")) {
                if (parseCommitted(valueAfterEq(sub))) |pt| c.lnb_comm[n] = pt;
            } else if (isKey(sub, "uncommittedDiseqcCommand")) {
                c.lnb_uncomm[n] = std.fmt.parseInt(i16, valueAfterEq(sub), 10) catch -1;
            } else if (std.mem.indexOf(u8, sub, "lof=unicable") != null) {
                c.unicable = true;
            } else if (isKey(sub, "scrfrequency")) {
                c.scr_freq = std.fmt.parseInt(u32, valueAfterEq(sub), 10) catch 0;
            } else if (isKey(sub, "scrList")) {
                const n2 = std.fmt.parseInt(u8, valueAfterEq(sub), 10) catch 0;
                c.scr_slot = if (n2 > 0) n2 - 1 else 0; // UB number (1-based) -> EN50494 index
            }
        }
    }
    for (nims, 0..) |*c, i| c.finalize(i);
    return true;
}

/// equal/loopthrough/satposdepends inherit the first fully configured NIM.
pub fn effectiveNim(nims: []const NimCfg, idx: usize, pos: u32) ?NimCfg {
    if (idx >= nims.len) return null;
    const c = nims[idx];
    switch (c.mode) {
        .nothing => return null,
        .equal, .loopthrough, .satposdepends => {
            for (nims) |donor| {
                if (donor.handles(pos) and donor.mode != .equal and donor.mode != .loopthrough and donor.mode != .satposdepends) return donor;
            }
            return null;
        },
        else => return if (c.handles(pos)) c else null,
    }
}
