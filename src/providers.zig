// Platform table: where each line-up's SI lives and how its channel numbers are
// encoded. Parameters were derived from SatScanLcn (GPLv2) and then verified or
// corrected against live off-air captures.

const std = @import("std");
const dvb = @import("dvb.zig");
const si = @import("si.zig");

pub const Provider = struct {
    key: []const u8,
    name: []const u8,
    home: dvb.Tp,
    /// Spare entry transponders, tried when the home TP won't lock. A network's
    /// NIT/BAT rides on several of its transponders, so a home TP that goes weak
    /// or gets vacated should not sink the whole scan.
    alts: []const dvb.Tp = &.{},
    onid: u16,
    tsid: u16,
    pos: u32 = 130, // orbital position (130 = 13.0E, 192 = 19.2E)
    bat_bouquet_id: u16 = 0, // 0 = no BAT scan
    bat_lcn_desc: u8 = 0,
    bat_lcn_layout: si.LcnLayout = .none,
    bat_lcn_in_bouquet_loop: bool = false,
    bat_pid: u16 = 0x11, // DVB default; some platforms use a private PID
    nit_lcn_desc: u8 = 0,
    nit_lcn_layout: si.LcnLayout = .none,
    nit_pid: u16 = 0x10, // DVB default; M7 platforms use a private PID
    nit_table_id: u8 = 0x40, // DVB default; M7 uses private table 0xBC
    nit_other: bool = false, // also read NIT-other 0x41 (Tivusat keeps LCN there)
};

const S2_8PSK_27500 = struct {
    fn v(freq: u32, fec: u32) dvb.Tp {
        return .{ .freq = freq, .sr = 27500000, .pol_h = false, .fec = fec, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 };
    }
    fn h(freq: u32, fec: u32) dvb.Tp {
        return .{ .freq = freq, .sr = 27500000, .pol_h = true, .fec = fec, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 };
    }
};

// M7 group: one shared home transponder, each platform has its own private NIT
// pid and uses private table id 0xBC (LCN descriptor 0x83).
const M7_HOME = dvb.Tp{ .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = dvb.FEC_5_6, .sys = dvb.SYS_DVBS, .mod = dvb.QPSK };
fn m7(key: []const u8, name: []const u8, nit_pid: u16) Provider {
    return .{ .key = key, .name = name, .home = M7_HOME, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_lcn_layout = .sid_visible_lcn10, .nit_pid = nit_pid, .nit_table_id = 0xbc };
}

pub const PROVIDERS = [_]Provider{
    // --- Hot Bird 13.0E ------------------------------------------------------
    // Canal+ home 10719 V carries the full network NIT + bouquet 0x2020 BAT.
    // It is FEC 3/4 (the sibling muxes are 5/6) - this demod family will not lock
    // on the wrong code rate (FEC_AUTO fails on old MIPS tuners), so the value has
    // to be exact. `alts` gives spare 5/6 entry TPs if 10719 V ever goes dark.
    .{ .key = "canalplus", .name = "Platforma Canal+", .home = S2_8PSK_27500.v(10719000, dvb.FEC_3_4), .onid = 318, .tsid = 11000, .bat_bouquet_id = 0x2020, .bat_lcn_desc = 0x83, .bat_lcn_layout = .sid_visible_lcn10, .alts = &.{
        S2_8PSK_27500.h(11488000, dvb.FEC_5_6),
        S2_8PSK_27500.v(11278000, dvb.FEC_5_6),
    } },
    .{ .key = "polsat", .name = "Polsat Box", .home = S2_8PSK_27500.v(12188000, dvb.FEC_3_4), .onid = 113, .tsid = 7400, .nit_lcn_desc = 0x82, .nit_lcn_layout = .sid_lcn16 },
    .{ .key = "nova", .name = "Nova Greece", .home = S2_8PSK_27500.h(11823000, dvb.FEC_3_4), .onid = 318, .tsid = 5500, .bat_bouquet_id = 0x0001, .bat_lcn_desc = 0x93, .bat_lcn_layout = .sid_lcn16 },
    .{ .key = "skyitalia", .name = "Sky Italia", .home = .{ .freq = 11881000, .sr = 27500000, .pol_h = false, .fec = dvb.FEC_3_4, .sys = dvb.SYS_DVBS, .mod = dvb.QPSK }, .onid = 64511, .tsid = 5800, .bat_bouquet_id = 0x6250, .bat_lcn_desc = 0xb1, .bat_lcn_layout = .sky_b1 },
    .{ .key = "tivusat", .name = "Tivusat", .home = .{ .freq = 10992000, .sr = 27500000, .pol_h = false, .fec = dvb.FEC_2_3, .sys = dvb.SYS_DVBS, .mod = dvb.QPSK }, .onid = 318, .tsid = 12400, .nit_lcn_desc = 0x83, .nit_lcn_layout = .sid_visible_lcn10, .nit_other = true },
    .{ .key = "vivacom", .name = "Vivacom", .home = .{ .freq = 12713000, .sr = 30000000, .pol_h = false, .fec = dvb.FEC_5_6, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 }, .onid = 213, .tsid = 10000, .bat_bouquet_id = 0x6158, .bat_lcn_desc = 0xe2, .bat_lcn_layout = .sid_lcn10 },
    // BIS TV: SatScanLcn's listed home TP (11681 H) is off air; this live network
    // SI transponder (11900 H, ONID 0x013F) carries the BAT of bouquet 0x0132,
    // whose LCN descriptor sits in the bouquet-descriptor loop, fully addressed.
    .{ .key = "bistv", .name = "BIS TV (13E)", .home = S2_8PSK_27500.h(11900000, dvb.FEC_3_4), .onid = 0x013f, .tsid = 0x170c, .bat_bouquet_id = 0x0132, .bat_lcn_desc = 0x83, .bat_lcn_layout = .sid_visible_lcn10, .bat_lcn_in_bouquet_loop = true },

    // --- Astra 19.2E ---------------------------------------------------------
    m7("canaldigitaal", "Canal Digitaal", 0x385),
    m7("tvvlaanderen", "TV Vlaanderen", 0x38f),
    m7("telesat", "TeleSAT", 0x399),
    m7("austriasat", "Austriasat", 0x3b6),
    m7("diveo", "Diveo", 0x3c0),
    // Standalone 19.2E platforms (LCN in BAT, default descriptor 0x83)
    .{ .key = "tntsat", .name = "TNTSAT (French TNT)", .home = .{ .freq = 11856000, .sr = 29700000, .pol_h = false, .fec = dvb.FEC_2_3, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 }, .onid = 1, .tsid = 1072, .pos = 192, .bat_bouquet_id = 0xc00f, .bat_lcn_desc = 0x83, .bat_lcn_layout = .sid_visible_lcn10 },
    .{ .key = "movistar", .name = "Movistar+", .home = .{ .freq = 10758500, .sr = 22000000, .pol_h = false, .fec = dvb.FEC_2_3, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 }, .onid = 1, .tsid = 1052, .pos = 192, .bat_bouquet_id = 0x0021, .bat_lcn_desc = 0x83, .bat_lcn_layout = .sid_visible_lcn10 },
    .{ .key = "simplitv", .name = "simpliTV", .home = .{ .freq = 11273000, .sr = 22000000, .pol_h = true, .fec = dvb.FEC_2_3, .sys = dvb.SYS_DVBS2, .mod = dvb.PSK_8 }, .onid = 1, .tsid = 1005, .pos = 192, .bat_bouquet_id = 0x3700, .bat_lcn_desc = 0x83, .bat_lcn_layout = .sid_visible_lcn10 },
};

pub fn find(key: []const u8) ?Provider {
    for (PROVIDERS) |p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

/// Comma-separated provider keys for help and error messages — generated from
/// the table so it can never drift from what the binary accepts.
pub fn listKeys(buf: []u8) []const u8 {
    var n: usize = 0;
    for (PROVIDERS, 0..) |p, i| {
        const sep: []const u8 = if (i == 0) "" else "|";
        if (n + sep.len + p.key.len > buf.len) break;
        @memcpy(buf[n .. n + sep.len], sep);
        n += sep.len;
        @memcpy(buf[n .. n + p.key.len], p.key);
        n += p.key.len;
    }
    return buf[0..n];
}
