// satscan — standalone binary (Zig 0.16) scanning Polsat/Canal+ channel lists
// straight off a DVB-S2 tuner (13.0E).
//
// Automatic operation: reads /etc/enigma2/settings and picks a tuner by itself —
// skips NIMs not configured for 13.0E, recognises unicable (EN50494:
// scrList/scrfrequency) and a plain universal LNB (voltage + 22kHz tone, no
// DiSEqC), and tries successive frontends until LOCK (busy EBUSY or no signal
// -> next one). Reads SI sections from the demux: SDT actual+other (service
// names), NIT (transponders + Polsat LCN 0x82), BAT (Canal+ LCN 0x83,
// bouquet_id filtered). Output: plain text on stdout.
//
// Usage: satscan --provider canalplus|polsat
//   [--adapter N] [--frontend N] [--demux N] [--settings /etc/enigma2/settings]
//   [--scr-slot N --scr-freq MHz]  (force unicable instead of settings config)
//   [--lnb-lo kHz] [--lnb-hi kHz] [--lnb-sw kHz] [--secs S] [--scan-secs S]
//
// Output format (stdout):
//   # provider=<p> freq=<kHz> pol=<H|V> lock=1 frontend=<n>
//   T <tsid>:<onid> freq=<kHz> pol=<..> sr=<sym/s> fec=<n> sys=<S|S2> pos=<...> mod=<n>
//   S <sid>:<tsid>:<onid> type=<n> "<name>" "<provider>"
//   L <lcn> <sid>:<tsid>:<onid> visible=<0|1> src=<nit|bat>

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// ---------- ioctl (arch-aware: mips/ppc encode dir/size differently) ----------
const IOCTL = linux.IOCTL;

// ---------- DVB frontend (API v5) ----------
const FE_HAS_LOCK: u32 = 0x10;

const SEC_VOLTAGE_13: u32 = 0; // vertical (V)
const SEC_VOLTAGE_18: u32 = 1; // horizontal (H)
const SEC_TONE_ON: u32 = 0;
const SEC_TONE_OFF: u32 = 1;

// fe_delivery_system
const SYS_DVBS: u32 = 5;
const SYS_DVBS2: u32 = 6;
// fe_modulation
const QPSK: u32 = 0;
const PSK_8: u32 = 9;
// fe_code_rate
const FEC_NONE: u32 = 0;
const FEC_3_4: u32 = 3;
const FEC_5_6: u32 = 5;
const FEC_AUTO: u32 = 9;
// fe_spectral_inversion
const INVERSION_AUTO: u32 = 2;
// fe_rolloff / fe_pilot
const ROLLOFF_AUTO: u32 = 3;
const PILOT_AUTO: u32 = 2;

// DTV property commands
const DTV_CLEAR: u32 = 2;
const DTV_FREQUENCY: u32 = 3;
const DTV_MODULATION: u32 = 4;
const DTV_INVERSION: u32 = 6;
const DTV_SYMBOL_RATE: u32 = 8;
const DTV_INNER_FEC: u32 = 9;
const DTV_PILOT: u32 = 12;
const DTV_ROLLOFF: u32 = 13;
const DTV_DELIVERY_SYSTEM: u32 = 17;
const DTV_TUNE: u32 = 1;

const dtv_property = extern struct {
    cmd: u32,
    reserved: [3]u32 = .{ 0, 0, 0 },
    data: u32 = 0,
    pad: [48]u8 = [_]u8{0} ** 48, // rest of union u (on 32-bit: 52 bytes incl. data)
    result: i32 = 0,
};

const dtv_properties = extern struct {
    num: u32,
    props: [*]dtv_property,
};

const dvb_diseqc_master_cmd = extern struct { msg: [6]u8, msg_len: u8 };
const FE_DISEQC_SEND_MASTER_CMD = IOCTL.IOW('o', 63, dvb_diseqc_master_cmd);
const FE_SET_PROPERTY = IOCTL.IOW('o', 82, dtv_properties);
const FE_READ_STATUS = IOCTL.IOR('o', 69, u32);
const FE_SET_VOLTAGE = IOCTL.IO('o', 67);
const FE_DISEQC_SEND_BURST = IOCTL.IO('o', 65); // fe_sec_mini_cmd: 0=A, 1=B
const FE_SET_TONE = IOCTL.IO('o', 66);

// ---------- DVB demux ----------
const dmx_filter = extern struct {
    filter: [16]u8 = [_]u8{0} ** 16,
    mask: [16]u8 = [_]u8{0} ** 16,
    mode: [16]u8 = [_]u8{0} ** 16,
};
const dmx_sct_filter_params = extern struct {
    pid: u16,
    filter: dmx_filter,
    timeout: u32,
    flags: u32,
};
const DMX_CHECK_CRC: u32 = 1;
const DMX_IMMEDIATE_START: u32 = 4;
const DMX_SET_FILTER = IOCTL.IOW('o', 43, dmx_sct_filter_params);
const DMX_STOP = IOCTL.IO('o', 42);
// STB extension (all enigma boxes): route demux input to a given frontend.
const DMX_SET_SOURCE = IOCTL.IOW('o', 49, u32);

fn demuxOpenFor(dmx_path: [*:0]const u8, frontend: u32) ?i32 {
    const fd = sysOpen(dmx_path, true) orelse return null;
    // Only reroute when we are not on the demux's default input (frontend0):
    // some STB drivers disturb already-armed filters when re-sourced.
    if (frontend > 0) _ = linux.ioctl(fd, DMX_SET_SOURCE, @intFromPtr(&frontend));
    return fd;
}

// ---------- transponder queue & satellites.xml (full-satellite scan) ----------
const XmlTp = struct { freq: u32, sr: u32, pol: u8, fec: u32, sys: u32, mod: u32 };

const TpQueue = struct {
    items: [512]XmlTp = undefined,
    len: usize = 0,

    // dedupe by frequency window (2 MHz) + polarisation
    fn add(self: *TpQueue, tp: XmlTp) bool {
        for (self.items[0..self.len]) |have| {
            if (have.pol == tp.pol and absDiff(have.freq, tp.freq) < 2000) return false;
        }
        if (self.len >= self.items.len) return false;
        self.items[self.len] = tp;
        self.len += 1;
        return true;
    }
};

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

// enigma satellites.xml fec_inner -> Linux DVB API fe_code_rate
fn mapXmlFec(x: u32) u32 {
    return switch (x) {
        1 => 1, // 1/2
        2 => 2, // 2/3
        3 => FEC_3_4,
        4 => FEC_5_6,
        5 => 7, // 7/8
        6 => 8, // 8/9
        7 => 10, // 3/5
        8 => 4, // 4/5
        9 => 11, // 9/10
        else => FEC_AUTO,
    };
}

// DVB satellite_delivery descriptor fec -> Linux DVB API
fn mapDescFec(x: u32) u32 {
    return switch (x) {
        1 => 1,
        2 => 2,
        3 => FEC_3_4,
        4 => FEC_5_6,
        5 => 7,
        6 => 8,
        7 => 10,
        8 => 4,
        9 => 11,
        else => FEC_AUTO,
    };
}

fn xmlAttr(line: []const u8, name: []const u8) ?u32 {
    var buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const i = std.mem.indexOf(u8, line, pat) orelse return null;
    const rest = line[i + pat.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseInt(u32, rest[0..j], 10) catch null;
}

// Minimal satellites.xml reader: transponders of the <sat position="POS"> block.
fn parseSatellitesXml(path: [*:0]const u8, want_pos: u32, queue: *TpQueue) bool {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const buf = std.heap.page_allocator.alloc(u8, 2 * 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf.ptr + total, buf.len - total);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        total += n;
    }
    var in_sat = false;
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "<sat ") != null) {
            in_sat = (xmlAttr(line, "position") orelse 0xffff) == want_pos;
            continue;
        }
        if (std.mem.indexOf(u8, line, "</sat>") != null) {
            if (in_sat) break;
            in_sat = false;
            continue;
        }
        if (!in_sat or std.mem.indexOf(u8, line, "<transponder") == null) continue;
        const freq_khz = xmlAttr(line, "frequency") orelse continue; // xml value is already kHz
        const sr = xmlAttr(line, "symbol_rate") orelse continue;
        const pol: u8 = @intCast(xmlAttr(line, "polarization") orelse 0);
        const fec = mapXmlFec(xmlAttr(line, "fec_inner") orelse 0);
        const sys: u32 = if ((xmlAttr(line, "system") orelse 0) == 1) SYS_DVBS2 else SYS_DVBS;
        const xmod = xmlAttr(line, "modulation") orelse 0;
        const modl: u32 = if (xmod == 2) PSK_8 else QPSK;
        _ = queue.add(.{ .freq = freq_khz, .sr = sr, .pol = pol, .fec = fec, .sys = sys, .mod = modl });
    }
    return queue.len > 0;
}

// ---------- provider table ----------
// A network's NIT/BAT rides on several of its transponders, so a home TP that
// goes weak or gets vacated (e.g. Canal+ 2026 consolidation) should not sink the
// whole scan: `alts` lists spare entry transponders, tried when the primary
// won't lock.
const HomeTp = struct {
    freq: u32, // kHz
    sr: u32,
    pol_h: bool,
    fec: u32,
    sys: u32,
    mod: u32,
};

const Provider = struct {
    key: []const u8,
    name: []const u8,
    freq: u32, // kHz
    sr: u32, // symbols/s
    pol_h: bool, // true=H(18V), false=V(13V)
    fec: u32,
    sys: u32,
    mod: u32,
    onid: u16,
    tsid: u16,
    alts: []const HomeTp = &.{}, // spare home transponders, tried if primary won't lock
    pos: u32 = 130, // orbital position (130 = 13.0E, 192 = 19.2E)
    bat_bouquet_id: u16 = 0, // 0 = no BAT scan
    bat_lcn_desc: u8 = 0, // LCN descriptor in BAT (Canal+: 0x83)
    bat_pid: u16 = 0x11, // DVB default; some platforms use a private PID
    nit_lcn_desc: u8 = 0, // LCN descriptor in NIT (Polsat: 0x82)
    nit_pid: u16 = 0x10, // DVB default; M7 platforms use a private PID
    nit_table_id: u8 = 0x40, // DVB default; M7 uses private table 0xBC
    nit_other: bool = false, // also read NIT-other 0x41 (Tivusat keeps LCN there)
};

const FEC_2_3: u32 = 2;

const PROVIDERS = [_]Provider{
    // Canal+ home 10719 V carries the full network NIT + bouquet 0x2020 BAT.
    // It is FEC 3/4 (the sibling muxes are 5/6) - this demod family will not lock
    // on the wrong code rate (FEC_AUTO fails on old MIPS tuners), so the value has
    // to be exact. `alts` gives spare 5/6 entry TPs if 10719 V ever goes dark.
    .{ .key = "canalplus", .name = "Platforma Canal+", .freq = 10719000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 318, .tsid = 11000, .bat_bouquet_id = 0x2020, .bat_lcn_desc = 0x83, .alts = &.{
        .{ .freq = 11488000, .sr = 27500000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8 },
        .{ .freq = 11278000, .sr = 27500000, .pol_h = false, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8 },
    } },
    .{ .key = "polsat", .name = "Polsat Box", .freq = 12188000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 113, .tsid = 7400, .nit_lcn_desc = 0x82 },
    .{ .key = "nova", .name = "Nova Greece", .freq = 11823000, .sr = 27500000, .pol_h = true, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 318, .tsid = 5500, .bat_bouquet_id = 0x0001, .bat_lcn_desc = 0x93 },
    .{ .key = "skyitalia", .name = "Sky Italia", .freq = 11881000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS, .mod = QPSK, .onid = 64511, .tsid = 5800, .bat_bouquet_id = 0x6250, .bat_lcn_desc = 0xb1 },
    .{ .key = "tivusat", .name = "Tivusat", .freq = 10992000, .sr = 27500000, .pol_h = false, .fec = FEC_2_3, .sys = SYS_DVBS, .mod = QPSK, .onid = 318, .tsid = 12400, .nit_lcn_desc = 0x83, .nit_other = true },
    .{ .key = "vivacom", .name = "Vivacom", .freq = 12713000, .sr = 30000000, .pol_h = false, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 213, .tsid = 10000, .bat_bouquet_id = 0x6158, .bat_lcn_desc = 0xe2 },
    // BIS TV (13E). SatScanLcn's listed home TP (11681 H) is off air; this live
    // network SI transponder (11900 H, ONID 0x013F, from an off-air lamedb)
    // carries the BAT of bouquet 0x0132.
    .{ .key = "bistv", .name = "BIS TV (13E)", .freq = 11900000, .sr = 27500000, .pol_h = true, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 0x013f, .tsid = 0x170c, .bat_bouquet_id = 0x0132, .bat_lcn_desc = 0x83 },

    // --- Astra 19.2E ---------------------------------------------------------
    // M7 group: one shared home transponder, each platform has its own private
    // NIT pid and uses private table id 0xBC (LCN descriptor 0x83).
    .{ .key = "canaldigitaal", .name = "Canal Digitaal", .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS, .mod = QPSK, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_pid = 0x385, .nit_table_id = 0xbc },
    .{ .key = "tvvlaanderen", .name = "TV Vlaanderen", .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS, .mod = QPSK, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_pid = 0x38f, .nit_table_id = 0xbc },
    .{ .key = "telesat", .name = "TeleSAT", .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS, .mod = QPSK, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_pid = 0x399, .nit_table_id = 0xbc },
    .{ .key = "austriasat", .name = "Austriasat", .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS, .mod = QPSK, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_pid = 0x3b6, .nit_table_id = 0xbc },
    .{ .key = "diveo", .name = "Diveo", .freq = 12515000, .sr = 22000000, .pol_h = true, .fec = FEC_5_6, .sys = SYS_DVBS, .mod = QPSK, .onid = 0x0035, .tsid = 0x0451, .pos = 192, .nit_lcn_desc = 0x83, .nit_pid = 0x3c0, .nit_table_id = 0xbc },
    // Standalone 19.2E platforms (LCN in BAT, default descriptor 0x83)
    .{ .key = "tntsat", .name = "TNTSAT (French TNT)", .freq = 11856000, .sr = 29700000, .pol_h = false, .fec = FEC_2_3, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 1, .tsid = 1072, .pos = 192, .bat_bouquet_id = 0xc00f, .bat_lcn_desc = 0x83 },
    .{ .key = "movistar", .name = "Movistar+", .freq = 10758500, .sr = 22000000, .pol_h = false, .fec = FEC_2_3, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 1, .tsid = 1052, .pos = 192, .bat_bouquet_id = 0x0021, .bat_lcn_desc = 0x83 },
    .{ .key = "simplitv", .name = "simpliTV", .freq = 11273000, .sr = 22000000, .pol_h = true, .fec = FEC_2_3, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 1, .tsid = 1005, .pos = 192, .bat_bouquet_id = 0x3700, .bat_lcn_desc = 0x83 },
};

// ---------- I/O on raw syscalls (no libc) ----------
fn sysOpen(path: [*:0]const u8, nonblock: bool) ?i32 {
    var flags = linux.O{ .ACCMODE = .RDWR };
    flags.NONBLOCK = nonblock;
    const rc = linux.open(path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn sysWrite(fd: i32, s: []const u8) void {
    _ = linux.write(fd, s.ptr, s.len);
}

fn nowMs() i64 {
    // gettimeofday: ancient syscall, works on every kernel these boxes run
    // (clock_gettime via zig can hit vdso/time64 paths that old kernels lack).
    var tv: linux.timeval = .{ .sec = 0, .usec = 0 };
    _ = linux.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

fn sleepMs(ms: u32) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @as(isize, @intCast(ms % 1000)) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

// ---------- helpers ----------
fn ioctlChecked(fd: i32, request: u32, arg: usize, what: []const u8) !void {
    const rc = linux.ioctl(fd, request, arg);
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("[satscan] ioctl {s} failed: {t}\n", .{ what, linux.errno(rc) });
        return error.Ioctl;
    }
}

const Lnb = struct { lo: u32 = 9750000, hi: u32 = 10600000, sw: u32 = 11700000 };
const Scr = struct { slot: u8, freq_mhz: u32 }; // Unicable EN50494 user band

fn tune(fd: i32, p: Provider, lnb: Lnb, scr: ?Scr, diseqc_port: ?u8, uncommitted: ?u8) !void {
    const high = p.freq >= lnb.sw;
    var ifreq: u32 = if (high) p.freq - lnb.hi else p.freq - lnb.lo;

    if (scr) |u| {
        // Unicable EN50494: SCR command sent at 18V, reception on the slot IF
        const tp_if_mhz = ifreq / 1000;
        const t: u32 = (tp_if_mhz + u.freq_mhz + 2) / 4 - 350;
        // bit 4 selects the satellite position bank (committed port 0/1)
        const bank: u8 = if (diseqc_port) |pt| (pt & 1) else 0;
        var cmd = dvb_diseqc_master_cmd{ .msg = .{
            0xE0, 0x10, 0x5A,
            (@as(u8, u.slot & 0x07) << 5) | (bank << 4) | (@as(u8, @intFromBool(p.pol_h)) << 3) | (@as(u8, @intFromBool(high)) << 2) | @as(u8, @intCast((t >> 8) & 0x03)),
            @intCast(t & 0xff),
            0,
        }, .msg_len = 5 };
        try ioctlChecked(fd, FE_SET_TONE, SEC_TONE_OFF, "FE_SET_TONE");
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_13, "FE_SET_VOLTAGE");
        sleepMs(15);
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_18, "FE_SET_VOLTAGE(18)");
        sleepMs(10);
        try ioctlChecked(fd, FE_DISEQC_SEND_MASTER_CMD, @intFromPtr(&cmd), "FE_DISEQC_SEND_MASTER_CMD");
        sleepMs(10);
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_13, "FE_SET_VOLTAGE(13)");
        ifreq = u.freq_mhz * 1000; // receive on the user-band IF
    } else {
        const voltage: u32 = if (p.pol_h) SEC_VOLTAGE_18 else SEC_VOLTAGE_13;
        const tone: u32 = if (high) SEC_TONE_ON else SEC_TONE_OFF;
        if (diseqc_port != null or uncommitted != null) {
            // A committed and/or DiSEqC 1.1 uncommitted switch: tone off, 18V for
            // a reliable command, then send (order: committed, uncommitted, tone
            // burst - the "cut" order enigma uses for cascaded switches).
            try ioctlChecked(fd, FE_SET_TONE, SEC_TONE_OFF, "FE_SET_TONE");
            try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_18, "FE_SET_VOLTAGE(18)");
            sleepMs(15);
            if (diseqc_port) |port| {
                // committed (2/4-way, monoblocks): E0 10 38 <F0|port<<2|pol<<1|band>
                var cmd = dvb_diseqc_master_cmd{ .msg = .{
                    0xE0, 0x10, 0x38,
                    0xF0 | (@as(u8, port & 0x03) << 2) | (@as(u8, @intFromBool(p.pol_h)) << 1) | @as(u8, @intFromBool(high)),
                    0, 0,
                }, .msg_len = 4 };
                try ioctlChecked(fd, FE_DISEQC_SEND_MASTER_CMD, @intFromPtr(&cmd), "FE_DISEQC_SEND_MASTER_CMD");
                sleepMs(54); // spec: >=15ms, switches like a bit more
            }
            if (uncommitted) |up| {
                // DiSEqC 1.1 uncommitted switch (up to 16 ports): E0 10 39
                // <F0|(port-1)>. Ports are numbered 1..16 in settings.
                const idx: u8 = if (up > 0) up - 1 else 0;
                var ucmd = dvb_diseqc_master_cmd{ .msg = .{
                    0xE0, 0x10, 0x39, 0xF0 | (idx & 0x0F), 0, 0,
                }, .msg_len = 4 };
                try ioctlChecked(fd, FE_DISEQC_SEND_MASTER_CMD, @intFromPtr(&ucmd), "FE_DISEQC_SEND_MASTER_CMD(uncommitted)");
                sleepMs(54);
            }
            // Many 2-way switches (and enigma's a/b mode) only react to the
            // mini-DiSEqC tone burst, so send it as well when a committed port is
            // in play: A for even ports, B for odd ones.
            if (diseqc_port) |port| {
                try ioctlChecked(fd, FE_DISEQC_SEND_BURST, @as(usize, port & 1), "FE_DISEQC_SEND_BURST");
                sleepMs(30);
            }
        }
        // tone/voltage by band and polarisation (universal LNB)
        try ioctlChecked(fd, FE_SET_VOLTAGE, voltage, "FE_SET_VOLTAGE");
        try ioctlChecked(fd, FE_SET_TONE, tone, "FE_SET_TONE");
    }

    var props = [_]dtv_property{
        .{ .cmd = DTV_CLEAR },
        .{ .cmd = DTV_DELIVERY_SYSTEM, .data = p.sys },
        .{ .cmd = DTV_FREQUENCY, .data = ifreq }, // kHz IF
        .{ .cmd = DTV_MODULATION, .data = p.mod },
        .{ .cmd = DTV_SYMBOL_RATE, .data = p.sr },
        .{ .cmd = DTV_INNER_FEC, .data = p.fec },
        .{ .cmd = DTV_INVERSION, .data = INVERSION_AUTO },
        .{ .cmd = DTV_ROLLOFF, .data = ROLLOFF_AUTO },
        .{ .cmd = DTV_PILOT, .data = PILOT_AUTO },
        .{ .cmd = DTV_TUNE },
    };
    var cmdseq = dtv_properties{ .num = props.len, .props = &props };
    try ioctlChecked(fd, FE_SET_PROPERTY, @intFromPtr(&cmdseq), "FE_SET_PROPERTY");
}

fn waitLock(fd: i32, secs: u32) bool {
    var i: u32 = 0;
    const iters = secs * 10;
    while (i < iters) : (i += 1) {
        var status: u32 = 0;
        _ = linux.ioctl(fd, FE_READ_STATUS, @intFromPtr(&status));
        if (status & FE_HAS_LOCK != 0) return true;
        sleepMs(100);
    }
    return false;
}

// A demod can raise FE_HAS_LOCK with no transport stream behind it - seen on FBC
// tuners whose input carries no signal, where every frequency "locks" and the
// scan then silently yields nothing. Every real DVB stream carries a PAT, so
// treat "lock but not one PAT section" as no lock and move on to the next tuner.
fn streamAlive(dmx_path: [*:0]const u8, frontend: u32, ms: i64) bool {
    const dfd = demuxOpenFor(dmx_path, frontend) orelse return false;
    defer _ = linux.close(dfd);
    setSectionFilter(dfd, 0x00, 0x00, 0xff, null) catch return false;
    var fds = [_]linux.pollfd{.{ .fd = @intCast(dfd), .events = linux.POLL.IN, .revents = 0 }};
    var secbuf: [4096]u8 = undefined;
    const deadline = nowMs() + ms;
    while (nowMs() < deadline) {
        const nr = linux.poll(&fds, 1, 300);
        if (linux.errno(nr) != .SUCCESS or nr == 0) continue;
        if (fds[0].revents & linux.POLL.IN == 0) continue;
        const n = linux.read(dfd, &secbuf, secbuf.len);
        if (linux.errno(n) == .SUCCESS and n >= 8) return true;
    }
    return false;
}

fn setSectionFilter(fd: i32, pid: u16, table_id: u8, table_mask: u8, ext_id: ?u16) !void {
    var params = dmx_sct_filter_params{
        .pid = pid,
        .filter = .{},
        .timeout = 0,
        .flags = DMX_CHECK_CRC | DMX_IMMEDIATE_START,
    };
    params.filter.filter[0] = table_id;
    params.filter.mask[0] = table_mask;
    if (ext_id) |e| { // filter[1..2] map to section bytes 3-4 (table_id_extension)
        params.filter.filter[1] = @intCast(e >> 8);
        params.filter.filter[2] = @intCast(e & 0xff);
        params.filter.mask[1] = 0xff;
        params.filter.mask[2] = 0xff;
    }
    try ioctlChecked(fd, DMX_SET_FILTER, @intFromPtr(&params), "DMX_SET_FILTER");
}

// ---------- SDT parse ----------
fn u16be(b: []const u8, o: usize) u16 {
    return (@as(u16, b[o]) << 8) | b[o + 1];
}

const Out = struct {
    buf: [512]u8 = undefined,
    fn line(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch return;
        sysWrite(1, s);
    }
};

fn parseSdt(section: []const u8, ids_out: *[2]u16, out: *Out, seen: *std.AutoHashMap(u32, void)) void {
    if (section.len < 12) return;
    if (section[0] != 0x42 and section[0] != 0x46) return;
    const tsid = u16be(section, 3);
    const onid = u16be(section, 8);
    ids_out.* = .{ tsid, onid };
    loop_fuse = 0;
    var pos: usize = 11; // past SDT header, into the service loop
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    const end = 3 + section_len - 4; // excluding CRC
    while (pos + 5 <= end and pos + 5 <= section.len) {
        if (fuse("sdt-svc")) return;
        const sid = u16be(section, pos);
        const free_ca = (section[pos + 3] >> 4) & 1;
        const desc_loop_len = (@as(usize, section[pos + 3] & 0x0f) << 8) | section[pos + 4];
        var d = pos + 5;
        const dend = d + desc_loop_len;
        var stype: u8 = 0;
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        var prov_buf: [64]u8 = undefined;
        var prov_len: usize = 0;
        while (d + 2 <= dend and d + 2 <= section.len) {
            if (fuse("sdt-desc")) return;
            const tag = section[d];
            const dlen = section[d + 1];
            if (tag == 0x48 and d + 2 + dlen <= section.len) { // service_descriptor
                var q = d + 2;
                stype = section[q];
                q += 1;
                const pl = section[q];
                q += 1;
                prov_len = copyName(prov_buf[0..], section[q .. q + pl]);
                q += pl;
                const nl = section[q];
                q += 1;
                name_len = copyName(name_buf[0..], section[q .. q + nl]);
            }
            d += 2 + @as(usize, dlen); // NOTE: '2 + dlen' alone wraps in u8
        }
        const key = (@as(u32, sid) << 16) | tsid;
        if (seen.get(key) == null) {
            seen.put(key, {}) catch {};
            out.line("S {X:0>4}:{X:0>4}:{X:0>4} type={d} ca={d} \"{s}\" \"{s}\"\n", .{ sid, tsid, onid, stype, free_ca, name_buf[0..name_len], prov_buf[0..prov_len] });
        }
        pos = dend;
    }
}

// copies a DVB name, skips the leading encoding byte (<0x20), maps control chars to spaces
fn copyName(dst: []u8, src: []const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    if (src.len > 0 and src[0] < 0x20) start = 1;
    var i: usize = start;
    while (i < src.len and n < dst.len) : (i += 1) {
        const c = src[i];
        if (c >= 0x20) {
            dst[n] = c;
            n += 1;
        } else if (c != 0) {
            dst[n] = ' ';
            n += 1;
        }
    }
    return n;
}

const POLCHARS = "HVLR";
const Seen = std.AutoHashMap(u64, void);

// Parser loop fuse: any inner loop exceeding this many turns per section is a
// bug — report and bail out of the section instead of spinning forever.
var loop_fuse: u32 = 0;
fn fuse(where: []const u8) bool {
    loop_fuse += 1;
    if (loop_fuse > 200_000) {
        std.debug.print("[satscan] LOOP FUSE tripped in {s}\n", .{where});
        return true;
    }
    return false;
}

fn emitLcn(out: *Out, seen: *Seen, src: []const u8, lcn: u16, sid: u16, tsid: u16, onid: u16, visible: u8, region: ?u8) void {
    const r: u64 = if (region) |rg| rg else 0xff;
    const key: u64 = (@as(u64, r) << 56) | (@as(u64, sid) << 40) | (@as(u64, tsid) << 24) | (@as(u64, onid & 0xff) << 16) | lcn;
    if (seen.get(key) != null) return;
    seen.put(key, {}) catch {};
    if (region) |rg| {
        out.line("L {d} {X:0>4}:{X:0>4}:{X:0>4} visible={d} region={d} src={s}\n", .{ lcn, sid, tsid, onid, visible, rg, src });
    } else {
        out.line("L {d} {X:0>4}:{X:0>4}:{X:0>4} visible={d} src={s}\n", .{ lcn, sid, tsid, onid, visible, src });
    }
}

fn bcd(b: []const u8) u32 {
    var v: u32 = 0;
    for (b) |c| {
        v = v * 100 + (c >> 4) * 10 + (c & 0x0f);
    }
    return v;
}

// NIT (0x40) and BAT (0x4A) share the TS-loop structure; they differ in header
// field meaning and where LCN lives. lcn_desc — which descriptor to treat as LCN.
fn parseNitLike(section: []const u8, table_id_want: u8, want_ext: ?u16, lcn_desc: u8, lcn_src: []const u8,
                out: *Out, seen_tp: *Seen, seen_lcn: *Seen, discover: ?*TpQueue) void {
    if (section.len < 12) return;
    if (section[0] != table_id_want) return;
    // Some demux drivers ignore the ext-id part of the hardware section filter
    // (seen on some boxes), letting foreign BAT bouquets through - verify in software.
    if (want_ext) |e| {
        if (u16be(section, 3) != e) return;
    }
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    const total = 3 + section_len;
    if (total > section.len) return;
    const end = total - 4; // bez CRC
    loop_fuse = 0;
    const net_desc_len = (@as(usize, section[8] & 0x0f) << 8) | section[9];
    // Most networks carry the LCN descriptor per-transport in the TS loop, but
    // some (BIS TV) put a single one in the bouquet/network descriptor loop
    // covering every service by SID. Scan that loop first when it holds our LCN
    // descriptor; here there is no per-entry tsid/onid, so services are keyed by
    // SID against the section's own onid.
    if (lcn_desc != 0 and net_desc_len > 0) {
        const sec_onid = u16be(section, 3); // BAT: bytes 3-4 are bouquet_id, not onid
        _ = sec_onid;
        var bd: usize = 10;
        const bd_end = @min(10 + net_desc_len, end);
        while (bd + 2 <= bd_end) {
            const btag = section[bd];
            const blen = section[bd + 1];
            const bbody = section[bd + 2 .. @min(bd + 2 + blen, bd_end)];
            if (btag == lcn_desc) {
                // In the bouquet-descriptor loop the LCN descriptor is fully
                // addressed: 8-byte entries onid(2) tsid(2) sid(2) lcn(2), unlike
                // the 4-byte sid+lcn form inside a TS loop (where onid/tsid come
                // from the loop). BIS TV numbers its whole bouquet this way.
                var q: usize = 0;
                while (q + 8 <= bbody.len) : (q += 8) {
                    const e_onid = u16be(bbody, q);
                    const e_tsid = u16be(bbody, q + 2);
                    const sid = u16be(bbody, q + 4);
                    const visible = (bbody[q + 6] >> 7) & 1;
                    // 10-bit field with the low 4 bits reserved (always set): the
                    // channel number lives in the upper bits.
                    const raw = (@as(u16, bbody[q + 6] & 0x03) << 8) | bbody[q + 7];
                    const lcn = raw >> 4;
                    if (lcn > 0) emitLcn(out, seen_lcn, lcn_src, lcn, sid, e_tsid, e_onid, visible, null);
                }
            }
            bd += 2 + @as(usize, blen);
        }
    }
    var pos: usize = 10 + net_desc_len;
    if (pos + 2 > end) return;
    pos += 2; // transport_stream_loop_length
    while (pos + 6 <= end) {
        if (fuse("nitlike-ts")) return;
        const tsid = u16be(section, pos);
        const onid = u16be(section, pos + 2);
        const dlen = (@as(usize, section[pos + 4] & 0x0f) << 8) | section[pos + 5];
        var d = pos + 6;
        const dend = @min(d + dlen, end);
        while (d + 2 <= dend) {
            const tag = section[d];
            const l = section[d + 1];
            if (fuse("nitlike-desc")) return;
            const body = section[d + 2 .. @min(d + 2 + l, dend)];
            if (tag == 0x43 and body.len >= 11) { // satellite_delivery
                const freq_10khz = bcd(body[0..4]);
                const pos_bcd = bcd(body[4..6]);
                const west_east = (body[6] >> 7) & 1;
                const pol = (body[6] >> 5) & 3;
                const sys = (body[6] >> 2) & 1;
                const modl = body[6] & 3;
                // SR: 7 BCD digits (unit 100 sym/s), low nibble of byte 10 = FEC
                const sr_100 = bcd(body[7..10]) * 10 + (body[10] >> 4);
                const fec = body[10] & 0x0f;
                const tpkey: u64 = (@as(u64, tsid) << 16) | onid;
                if (seen_tp.get(tpkey) == null) {
                    seen_tp.put(tpkey, {}) catch {};
                    out.line("T {X:0>4}:{X:0>4} freq={d} pol={c} sr={d} fec={d} sys={s} pos={d}{s} mod={d}\n", .{
                        tsid, onid, freq_10khz * 10, POLCHARS[pol], sr_100 * 100, fec,
                        if (sys == 1) "S2" else "S", pos_bcd, if (west_east == 1) "E" else "W", modl,
                    });
                }
                if (discover) |q| {
                    const added = q.add(.{ .freq = freq_10khz * 10, .sr = sr_100 * 100, .pol = pol, .fec = mapDescFec(fec), .sys = if (sys == 1) SYS_DVBS2 else SYS_DVBS, .mod = if (modl == 2) PSK_8 else QPSK });
                    if (added) std.debug.print("[satscan] NIT discovered new tp {d} {c}\n", .{ freq_10khz * 10, POLCHARS[pol] });
                }
            } else if (tag == lcn_desc and lcn_desc != 0) {
                switch (lcn_desc) {
                    0x83 => { // sid(2), visible flag(1b) + lcn(10b)
                        var q: usize = 0;
                        while (q + 4 <= body.len) : (q += 4) {
                            const sid = u16be(body, q);
                            const visible = (body[q + 2] >> 7) & 1;
                            const lcn = (@as(u16, body[q + 2] & 0x03) << 8) | body[q + 3];
                            emitLcn(out, seen_lcn, lcn_src, lcn, sid, tsid, onid, visible, null);
                        }
                    },
                    0xb1 => { // Sky private: 2-byte header (region in byte 1), then 9-byte entries
                        // NOTE: no `continue` here — it would skip the `d += 2 + l`
                        // advance below and spin forever on the same descriptor.
                        if (body.len >= 2) {
                            const region = body[1];
                            var q: usize = 2;
                            while (q + 9 <= body.len) : (q += 9) {
                                const sid = u16be(body, q);
                                const sky_id = u16be(body, q + 5);
                                if (sky_id > 0 and sky_id != 0xffff) emitLcn(out, seen_lcn, lcn_src, sky_id, sid, tsid, onid, 1, region);
                            }
                        }
                    },
                    0xe2 => { // sid(2), lcn(10b)
                        var q: usize = 0;
                        while (q + 4 <= body.len) : (q += 4) {
                            const sid = u16be(body, q);
                            const lcn = (@as(u16, body[q + 2] & 0x03) << 8) | body[q + 3];
                            if (lcn > 0) emitLcn(out, seen_lcn, lcn_src, lcn, sid, tsid, onid, 1, null);
                        }
                    },
                    else => { // 0x82, 0x93 and friends: sid(2) lcn(2)
                        var q: usize = 0;
                        while (q + 4 <= body.len) : (q += 4) {
                            const sid = u16be(body, q);
                            const lcn = u16be(body, q + 2);
                            if (lcn > 0) emitLcn(out, seen_lcn, lcn_src, lcn, sid, tsid, onid, 1, null);
                        }
                    },
                }
            }
            d += 2 + @as(usize, l); // NOTE: '2 + l' alone wraps in u8 (254 -> 0)
        }
        pos = dend;
    }
}

// ---------- tuner configuration from /etc/enigma2/settings ----------
const NimMode = enum { unknown, simple, advanced, nothing, equal, loopthrough, satposdepends };
const MAX_SATS = 8;
const MAX_LNB = 33; // enigma numbers advanced LNB blocks 1..32

// One tuner's dish setup: which orbital positions it can reach and, for each,
// which committed DiSEqC port selects it (null = no switch, single LNB).
const NimCfg = struct {
    seen: bool = false,
    mode: NimMode = .unknown,
    single: bool = false, // diseqcMode=single -> never send a switch command
    ab_only: bool = false, // diseqcMode=toneburst_a_b / diseqc_a_b -> only ports 0 and 1 exist
    positions: [MAX_SATS]u32 = [_]u32{0} ** MAX_SATS,
    ports: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS,
    has_port: [MAX_SATS]bool = [_]bool{false} ** MAX_SATS,
    // Uncommitted DiSEqC (1.1) port per position, and, for advanced mode, the LNB
    // block each position maps to. In advanced dishes the DiSEqC commands live in
    // the LNB block (advanced.lnb.<N>.*), not the sat block, so we buffer them and
    // resolve position -> lnb -> {committed, uncommitted} in finalizeAdvanced().
    uports: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS,
    has_uport: [MAX_SATS]bool = [_]bool{false} ** MAX_SATS,
    lnb_of: [MAX_SATS]u8 = [_]u8{0} ** MAX_SATS, // 0 = unset
    lnb_comm: [MAX_LNB]i16 = [_]i16{-1} ** MAX_LNB,
    lnb_uncomm: [MAX_LNB]i16 = [_]i16{-1} ** MAX_LNB,
    nsat: usize = 0,
    unicable: bool = false, // from the advanced LNB block
    scr_slot: u8 = 0,
    scr_freq: u32 = 0,

    // The advanced LNB block (incl. unicable) only applies in advanced mode;
    // images keep stale advanced config around while running in simple mode.
    fn usesUnicable(self: NimCfg) bool {
        return self.unicable and self.scr_freq != 0 and self.mode == .advanced;
    }

    fn addSat(self: *NimCfg, pos: u32, port: ?u8) void {
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] == pos) {
                // First assignment wins: images keep stale duplicates (e.g.
                // diseqcA=130 alongside diseqcD=130), and letting the later one
                // through would move 13E onto port 3.
                if (port) |pt| {
                    if (!self.has_port[i]) {
                        self.ports[i] = pt;
                        self.has_port[i] = true;
                    }
                }
                return;
            }
        }
        if (self.nsat >= MAX_SATS) return;
        self.positions[self.nsat] = pos;
        if (port) |pt| {
            self.ports[self.nsat] = pt;
            self.has_port[self.nsat] = true;
        }
        self.nsat += 1;
    }

    fn setSatLnb(self: *NimCfg, pos: u32, lnb: u8) void {
        self.addSat(pos, null);
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] == pos) {
                self.lnb_of[i] = lnb;
                return;
            }
        }
    }

    // Resolve advanced position -> LNB block -> committed/uncommitted ports.
    fn finalizeAdvanced(self: *NimCfg) void {
        if (self.mode != .advanced) return;
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

    fn uportFor(self: NimCfg, pos: u32) ?u8 {
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] == pos and self.has_uport[i]) return self.uports[i];
        }
        return null;
    }

    // An A/B switch only has ports 0 and 1; diseqcC/D are stale leftovers there.
    fn portUsable(self: NimCfg, i: usize) bool {
        return self.has_port[i] and !(self.ab_only and self.ports[i] > 1);
    }

    fn handles(self: NimCfg, pos: u32) bool {
        if (self.mode == .nothing) return false;
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] != pos) continue;
            // in A/B mode a position only reachable through port C/D is not reachable
            if (self.ab_only and self.has_port[i] and self.ports[i] > 1) return false;
            return true;
        }
        return false;
    }

    // committed DiSEqC port for this position, or null when no switch is used
    fn portFor(self: NimCfg, pos: u32) ?u8 {
        if (self.single) return null;
        var i: usize = 0;
        while (i < self.nsat) : (i += 1) {
            if (self.positions[i] == pos and self.portUsable(i)) return self.ports[i];
        }
        return null;
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

fn parseSettings(path: [*:0]const u8, nims: []NimCfg) bool {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const buf = std.heap.page_allocator.alloc(u8, 1024 * 1024) catch return false;
    defer std.heap.page_allocator.free(buf);
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf.ptr + total, buf.len - total);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        total += n;
    }
    var lines = std.mem.splitScalar(u8, buf[0..total], '\n');
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
        if (std.mem.startsWith(u8, kv, "configMode=")) {
            const v = valueAfterEq(kv);
            c.mode = if (std.mem.eql(u8, v, "simple")) .simple
            else if (std.mem.eql(u8, v, "advanced")) .advanced
            else if (std.mem.eql(u8, v, "nothing")) .nothing
            else if (std.mem.eql(u8, v, "equal")) .equal
            else if (std.mem.eql(u8, v, "loopthrough")) .loopthrough
            else if (std.mem.eql(u8, v, "satposdepends")) .satposdepends
            else .unknown;
        } else if (std.mem.startsWith(u8, kv, "diseqc") and kv.len > 7 and kv[7] == '=') {
            // simple mode: diseqcA..D = orbital position on committed port 0..3
            const port: u8 = switch (kv[6]) {
                'A' => 0,
                'B' => 1,
                'C' => 2,
                'D' => 3,
                else => continue,
            };
            if (std.fmt.parseInt(u32, valueAfterEq(kv), 10) catch null) |pos| c.addSat(pos, port);
        } else if (std.mem.startsWith(u8, kv, "diseqcMode=")) {
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
            if (std.mem.startsWith(u8, sub, "commitedDiseqcCommand=") or std.mem.startsWith(u8, sub, "committedDiseqcCommand=")) {
                c.addSat(pos, parseCommitted(valueAfterEq(sub)));
            } else if (std.mem.eql(u8, sub, "lnb=") or std.mem.startsWith(u8, sub, "lnb=")) {
                const n = std.fmt.parseInt(u8, valueAfterEq(sub), 10) catch 0;
                c.setSatLnb(pos, n);
            } else {
                c.addSat(pos, null);
            }
        } else if (std.mem.startsWith(u8, kv, "advanced.lnb.")) {
            // advanced.lnb.<N>.<key>=<value> — the DiSEqC commands for that block
            const rest2 = kv["advanced.lnb.".len..];
            const dot2 = std.mem.indexOfScalar(u8, rest2, '.') orelse continue;
            const n = std.fmt.parseInt(u8, rest2[0..dot2], 10) catch continue;
            if (n == 0 or n >= MAX_LNB) continue;
            const sub = rest2[dot2 + 1 ..];
            if (std.mem.startsWith(u8, sub, "commitedDiseqcCommand=") or std.mem.startsWith(u8, sub, "committedDiseqcCommand=")) {
                if (parseCommitted(valueAfterEq(sub))) |pt| c.lnb_comm[n] = pt;
            } else if (std.mem.startsWith(u8, sub, "uncommittedDiseqcCommand=")) {
                c.lnb_uncomm[n] = std.fmt.parseInt(i16, valueAfterEq(sub), 10) catch -1;
            }
        } else if (std.mem.indexOf(u8, kv, ".lof=unicable") != null) {
            c.unicable = true;
        } else if (std.mem.indexOf(u8, kv, ".scrfrequency=") != null) {
            c.scr_freq = std.fmt.parseInt(u32, valueAfterEq(kv), 10) catch 0;
        } else if (std.mem.indexOf(u8, kv, ".scrList=") != null) {
            const n = std.fmt.parseInt(u8, valueAfterEq(kv), 10) catch 0;
            c.scr_slot = if (n > 0) n - 1 else 0; // UB number (1-based) -> EN50494 index
        }
    }
    for (nims) |*c| c.finalizeAdvanced();
    return true;
}

// equal/loopthrough/satposdepends inherit the first fully configured NIM
fn effectiveNim(nims: []const NimCfg, idx: usize, pos: u32) ?NimCfg {
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

// Full-satellite scan: walk every transponder from the queue (seeded from
// satellites.xml, extended live with NIT discoveries), grab SDT actual + NIT
// on each, emit T/S lines. LCN is provider-specific, so none here.
fn scanAll(fe: i32, fe_num: u32, dmx_path: [*:0]const u8, lnb: Lnb, scr: ?Scr, diseqc_port: ?u8, uncommitted: ?u8,
           queue: *TpQueue, lock_secs: u32, tp_secs: u32, max_tp: usize, pos_label: u32,
           out: *Out, alloc: std.mem.Allocator) !void {
    var seen = std.AutoHashMap(u32, void).init(alloc);
    defer seen.deinit();
    var seen_tp = Seen.init(alloc);
    defer seen_tp.deinit();
    var seen_lcn = Seen.init(alloc);
    defer seen_lcn.deinit();

    var locked: u32 = 0;
    var tried: usize = 0;
    var i: usize = 0;
    while (i < queue.len) : (i += 1) {
        if (max_tp != 0 and tried >= max_tp) break;
        tried += 1;
        const tp = queue.items[i];
        const prov = Provider{ .key = "", .name = "", .freq = tp.freq, .sr = tp.sr, .pol_h = tp.pol == 0, .fec = tp.fec, .sys = tp.sys, .mod = tp.mod, .onid = 0, .tsid = 0, .pos = pos_label };
        tune(fe, prov, lnb, scr, diseqc_port, uncommitted) catch {
            out.line("# tp {d}{c} sr={d} lock=err\n", .{ tp.freq, POLCHARS[tp.pol], tp.sr });
            continue;
        };
        if (!waitLock(fe, lock_secs)) {
            out.line("# tp {d}{c} sr={d} lock=0\n", .{ tp.freq, POLCHARS[tp.pol], tp.sr });
            continue;
        }
        locked += 1;
        out.line("# tp {d}{c} sr={d} lock=1\n", .{ tp.freq, POLCHARS[tp.pol], tp.sr });

        const fd_sdt = demuxOpenFor(dmx_path, fe_num) orelse continue;
        defer _ = linux.close(fd_sdt);
        const fd_nit = demuxOpenFor(dmx_path, fe_num) orelse continue;
        defer _ = linux.close(fd_nit);
        setSectionFilter(fd_sdt, 0x11, 0x42, 0xff, null) catch continue; // SDT actual only
        setSectionFilter(fd_nit, 0x10, 0x40, 0xff, null) catch continue;

        var fds = [_]linux.pollfd{
            .{ .fd = fd_sdt, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd_nit, .events = linux.POLL.IN, .revents = 0 },
        };
        var ids: [2]u16 = .{ 0, 0 };
        var got_own_t = false;
        var secbuf: [4200]u8 = undefined;
        const t0 = nowMs();
        while (nowMs() - t0 < @as(i64, tp_secs) * 1000) {
            const nr = linux.poll(&fds, fds.len, 300);
            if (linux.errno(nr) != .SUCCESS or nr == 0) continue;
            for (&fds) |*pf| {
                if (pf.revents & linux.POLL.IN == 0) continue;
                var drained: u32 = 0;
                while (drained < 256) : (drained += 1) {
                    const n = linux.read(pf.fd, &secbuf, secbuf.len);
                    if (linux.errno(n) != .SUCCESS or n == 0) break;
                    if (n < 12) continue;
                    const sec = secbuf[0..n];
                    if (pf.fd == fd_sdt) {
                        parseSdt(sec, &ids, out, &seen);
                        if (!got_own_t and ids[0] != 0) {
                            got_own_t = true;
                            // synthetic T for the tuned tp (some tps carry no NIT)
                            const tpkey: u64 = (@as(u64, ids[0]) << 16) | ids[1];
                            if (seen_tp.get(tpkey) == null) {
                                seen_tp.put(tpkey, {}) catch {};
                                out.line("T {X:0>4}:{X:0>4} freq={d} pol={c} sr={d} fec={d} sys={s} pos={d}E mod={d}\n", .{
                                    ids[0], ids[1], tp.freq, POLCHARS[tp.pol], tp.sr, tp.fec,
                                    if (tp.sys == SYS_DVBS2) "S2" else "S", pos_label, if (tp.mod == PSK_8) @as(u32, 2) else 1,
                                });
                            }
                        }
                    } else if (sec[0] == 0x40) {
                        parseNitLike(sec, 0x40, null, 0, "nit", out, &seen_tp, &seen_lcn, queue);
                    }
                }
            }
        }
        _ = linux.ioctl(fd_sdt, DMX_STOP, 0);
        _ = linux.ioctl(fd_nit, DMX_STOP, 0);
    }
    std.debug.print("[satscan] scan-all: tps={d} locked={d} services={d} transponders={d}\n", .{ tried, locked, seen.count(), seen_tp.count() });
}

fn batComplete(last: i32, got: *const [256]bool) bool {
    if (last < 0) return false; // no section seen yet
    var i: usize = 0;
    while (i <= @as(usize, @intCast(last))) : (i += 1) {
        if (!got[i]) return false;
    }
    return true;
}

fn findProvider(key: []const u8) ?Provider {
    for (PROVIDERS) |p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var adapter: u32 = 0;
    var fe_index: ?u32 = null; // null = auto-select a working tuner
    var demux: u32 = 0;
    var provider_key: []const u8 = "canalplus";
    var lnb = Lnb{};
    var secs: u32 = 8;
    var scan_secs: u32 = 25;
    var scr_slot: ?u8 = null;
    var scr_freq: u32 = 0;
    var settings_path: [:0]const u8 = "/etc/enigma2/settings";
    var cli_port: ?u8 = null;
    var dry_run = false;
    var scan_all = false;
    var satxml_path: [:0]const u8 = "/etc/tuxbox/satellites.xml";
    var sat_pos: u32 = 130;
    var tp_secs: u32 = 4;
    var max_tp: usize = 0;

    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--adapter")) {
            adapter = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--frontend")) {
            fe_index = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--demux")) {
            demux = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--provider")) {
            provider_key = it.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--lnb-lo")) {
            lnb.lo = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--lnb-hi")) {
            lnb.hi = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--lnb-sw")) {
            lnb.sw = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--secs")) {
            secs = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--scan-secs")) {
            scan_secs = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--scr-slot")) {
            scr_slot = try std.fmt.parseInt(u8, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--scr-freq")) {
            scr_freq = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--settings")) {
            settings_path = it.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--diseqc-port")) {
            cli_port = try std.fmt.parseInt(u8, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--scan-all")) {
            scan_all = true;
        } else if (std.mem.eql(u8, a, "--satxml")) {
            satxml_path = it.next() orelse return error.MissingArg;
        } else if (std.mem.eql(u8, a, "--pos")) {
            sat_pos = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--tp-secs")) {
            tp_secs = try std.fmt.parseInt(u32, it.next() orelse return error.MissingArg, 10);
        } else if (std.mem.eql(u8, a, "--max-tp")) {
            max_tp = try std.fmt.parseInt(usize, it.next() orelse return error.MissingArg, 10);
        }
    }

    const p: Provider = if (scan_all)
        // scan-all does not need a provider; home-TP fields are only used to
        // probe the tuner, so borrow them from the first XML transponder later.
        Provider{ .key = "scan", .name = "scan-all", .freq = 0, .sr = 0, .pol_h = false, .fec = FEC_AUTO, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 0, .tsid = 0 }
    else findProvider(provider_key) orelse {
        std.debug.print("[satscan] unknown provider '{s}' (canalplus|polsat|nova|skyitalia|tivusat|vivacom|bistv)\n", .{provider_key});
        return error.BadProvider;
    };

    var queue = TpQueue{};
    var p_eff = p;
    if (scan_all) {
        if (!parseSatellitesXml(satxml_path, sat_pos, &queue)) {
            // enigma often symlinks this into /etc/enigma2 as well
            if (!parseSatellitesXml("/etc/enigma2/satellites.xml", sat_pos, &queue)) {
                std.debug.print("[satscan] no transponders for pos={d} in {s}\n", .{ sat_pos, satxml_path });
                return error.NoTransponders;
            }
        }
        std.debug.print("[satscan] satellites.xml: {d} transponders for pos={d}\n", .{ queue.len, sat_pos });
        const first = queue.items[0];
        p_eff.freq = first.freq;
        p_eff.sr = first.sr;
        p_eff.pol_h = first.pol == 0;
        p_eff.fec = first.fec;
        p_eff.sys = first.sys;
        p_eff.mod = first.mod;
    }

    // Target orbital position: provider's home sat, or --pos for a full scan.
    const target_pos: u32 = if (scan_all) sat_pos else p.pos;

    // Tuner configuration from enigma settings (unicable, dish/DiSEqC layout).
    var nims = [_]NimCfg{.{}} ** 16;
    const have_settings = parseSettings(settings_path, &nims);
    if (!have_settings) std.debug.print("[satscan] no {s} - trying every tuner with a plain LNB\n", .{settings_path});

    const cli_scr: ?Scr = if (scr_slot) |sl| blk: {
        if (scr_freq == 0) {
            std.debug.print("[satscan] --scr-slot requires --scr-freq <MHz>\n", .{});
            return error.MissingArg;
        }
        break :blk Scr{ .slot = sl, .freq_mhz = scr_freq };
    } else null;

    if (dry_run) {
        // Diagnostics only: report what the dish setup implies, touch nothing.
        var out_d = Out{};
        out_d.line("# dry-run target={d}.{d}E provider={s} freq={d} pol={c}\n", .{
            target_pos / 10, target_pos % 10, p.name, p.freq, @as(u8, if (p.pol_h) 'H' else 'V'),
        });
        var ni: usize = 0;
        while (ni < nims.len) : (ni += 1) {
            const c = nims[ni];
            if (!c.seen) continue;
            out_d.line("NIM{d} mode={s} single={d} ab={d} sats=", .{ ni, @tagName(c.mode), @intFromBool(c.single), @intFromBool(c.ab_only) });
            var j: usize = 0;
            while (j < c.nsat) : (j += 1) {
                if (c.has_port[j]) {
                    out_d.line("{d}(port{d}) ", .{ c.positions[j], c.ports[j] });
                } else {
                    out_d.line("{d} ", .{c.positions[j]});
                }
            }
            if (c.usesUnicable()) {
                out_d.line("unicable(slot={d},{d}MHz) ", .{ c.scr_slot, c.scr_freq });
            } else if (c.unicable) {
                out_d.line("unicable-cfg-ignored(mode!=advanced) ", .{});
            }
            const eff = effectiveNim(&nims, ni, target_pos);
            if (eff) |cfg| {
                const uc = cfg.uportFor(target_pos);
                if (cfg.portFor(target_pos)) |pt| {
                    if (uc) |u| {
                        out_d.line("=> WOULD USE, DiSEqC committed port {d} + uncommitted {d}\n", .{ pt, u });
                    } else {
                        out_d.line("=> WOULD USE, DiSEqC committed port {d}\n", .{pt});
                    }
                } else if (uc) |u| {
                    out_d.line("=> WOULD USE, DiSEqC uncommitted {d}\n", .{u});
                } else {
                    out_d.line("=> WOULD USE, no switch command\n", .{});
                }
            } else {
                out_d.line("=> cannot reach target\n", .{});
            }
        }
        return;
    }

    // Auto-selection: successive frontends; NIM config from settings; busy (EBUSY)
    // or no LOCK -> next one. --frontend pins a specific tuner.
    var pathbuf: [64]u8 = undefined;
    var probebuf: [64]u8 = undefined;
    const dmx_probe_path = try std.fmt.bufPrintZ(&probebuf, "/dev/dvb/adapter{d}/demux{d}", .{ adapter, demux });
    var fe: i32 = -1;
    var chosen_fe: u32 = 0;
    var chosen_port: ?u8 = null;
    var chosen_uncommitted: ?u8 = null;
    var locked = false;
    var tuners_tried: usize = 0; // frontends we actually tuned
    var unreachable_nims: usize = 0; // skipped: dish config cannot reach target_pos
    var f: u32 = if (fe_index) |fi| fi else 0;
    const f_end: u32 = if (fe_index) |fi| fi + 1 else 16;
    while (f < f_end) : (f += 1) {
        var scr: ?Scr = cli_scr;
        var diseqc_port: ?u8 = cli_port;
        var uncommitted: ?u8 = null;
        if (have_settings) {
            if (effectiveNim(&nims, f, target_pos)) |cfg| {
                if (cli_scr == null and cfg.usesUnicable()) {
                    scr = Scr{ .slot = cfg.scr_slot, .freq_mhz = cfg.scr_freq };
                }
                if (cli_port == null) diseqc_port = cfg.portFor(target_pos);
                uncommitted = cfg.uportFor(target_pos);
            } else if (fe_index == null) {
                unreachable_nims += 1;
                continue; // this NIM cannot reach the target position - skip
            } else {
                std.debug.print("[satscan] frontend{d}: NIM not configured for {d}.{d}E - trying anyway\n", .{ f, target_pos / 10, target_pos % 10 });
            }
        }
        const fe_path = try std.fmt.bufPrintZ(&pathbuf, "/dev/dvb/adapter{d}/frontend{d}", .{ adapter, f });
        const fd = sysOpen(fe_path, true) orelse {
            if (fe_index != null) {
                std.debug.print("[satscan] frontend{d} busy/unavailable\n", .{f});
                return error.TunerBusy;
            }
            continue;
        };
        if (scr) |u| {
            std.debug.print("[satscan] frontend{d}: unicable slot={d} freq={d}MHz{s}\n", .{ f, u.slot, u.freq_mhz, if (diseqc_port != null) " (+bank)" else "" });
        } else if (diseqc_port) |pt| {
            std.debug.print("[satscan] frontend{d}: plain LNB, DiSEqC committed port {d}\n", .{ f, pt });
        } else {
            std.debug.print("[satscan] frontend{d}: plain LNB\n", .{f});
        }
        if (scan_all) { // scan-all: first configured tuner that opens; locks counted per tp
            fe = fd;
            chosen_fe = f;
            chosen_port = diseqc_port;
            chosen_uncommitted = uncommitted;
            locked = true;
            break;
        }
        // Try the primary home TP, then any spare `alts`, on this frontend.
        var cands: [8]HomeTp = undefined;
        cands[0] = .{ .freq = p_eff.freq, .sr = p_eff.sr, .pol_h = p_eff.pol_h, .fec = p_eff.fec, .sys = p_eff.sys, .mod = p_eff.mod };
        var ncand: usize = 1;
        for (p.alts) |alt| {
            if (ncand >= cands.len) break;
            cands[ncand] = alt;
            ncand += 1;
        }
        var cand_locked = false;
        tuners_tried += 1;
        var ci: usize = 0;
        while (ci < ncand) : (ci += 1) {
            var pc = p_eff;
            pc.freq = cands[ci].freq;
            pc.sr = cands[ci].sr;
            pc.pol_h = cands[ci].pol_h;
            pc.fec = cands[ci].fec;
            pc.sys = cands[ci].sys;
            pc.mod = cands[ci].mod;
            tune(fd, pc, lnb, scr, diseqc_port, uncommitted) catch continue;
            var ok = waitLock(fd, secs);
            if (!ok and scr != null) { // unicable can be moody - one retry
                tune(fd, pc, lnb, scr, diseqc_port, uncommitted) catch {};
                ok = waitLock(fd, secs);
            }
            if (ok) {
                // guard against a lock with no stream behind it (see streamAlive)
                if (!streamAlive(dmx_probe_path, f, 2500)) {
                    std.debug.print("[satscan] frontend{d}: LOCK but no stream (no PAT) - ignoring\n", .{f});
                    ok = false;
                    continue;
                }
                p_eff = pc; // downstream table reads use the TP that actually locked
                cand_locked = true;
                break;
            }
        }
        if (cand_locked) {
            fe = fd;
            chosen_fe = f;
            chosen_port = diseqc_port;
            chosen_uncommitted = uncommitted;
            locked = true;
            break;
        }
        std.debug.print("[satscan] frontend{d}: no LOCK\n", .{f});
        _ = linux.close(fd);
    }
    if (fe < 0) {
        // "did not lock" and "no tuner can even reach this position" are different
        // faults: the first means no signal, the second a dish/DiSEqC config that
        // never lists the target. Reporting both as NoLock invites wrong diagnoses.
        if (tuners_tried == 0 and unreachable_nims > 0) {
            std.debug.print("[satscan] no tuner is configured for {d}.{d}E ({d} NIM(s) skipped) - nothing was tuned\n", .{ target_pos / 10, target_pos % 10, unreachable_nims });
            return error.PositionNotConfigured;
        }
        std.debug.print("[satscan] no tuner achieved LOCK on {d}.{d}E ({d} tuner(s) tried)\n", .{ target_pos / 10, target_pos % 10, tuners_tried });
        return error.NoLock;
    }
    defer _ = linux.close(fe);
    std.debug.print("[satscan] tuner: frontend{d}\n", .{chosen_fe});

    var dmxbuf0: [64]u8 = undefined;
    const dmx_path0 = try std.fmt.bufPrintZ(&dmxbuf0, "/dev/dvb/adapter{d}/demux{d}", .{ adapter, demux });

    if (scan_all) {
        var out_sa = Out{};
        out_sa.line("# scan-all pos={d} tps={d} frontend={d}\n", .{ sat_pos, queue.len, chosen_fe });
        const scr_used: ?Scr = if (cli_scr != null) cli_scr else if (have_settings) blk: {
            if (effectiveNim(&nims, chosen_fe, target_pos)) |cfg| {
                if (cfg.usesUnicable()) break :blk Scr{ .slot = cfg.scr_slot, .freq_mhz = cfg.scr_freq };
            }
            break :blk null;
        } else null;
        try scanAll(fe, chosen_fe, dmx_path0, lnb, scr_used, chosen_port, chosen_uncommitted, &queue, secs, tp_secs, max_tp, sat_pos, &out_sa, alloc);
        return;
    }

    var out = Out{};
    out.line("# provider={s} freq={d} pol={s} lock={d} frontend={d}\n", .{ p.name, p_eff.freq, if (p_eff.pol_h) "H" else "V", @intFromBool(locked), chosen_fe });

    var dmxbuf: [64]u8 = undefined;
    const dmx_path = try std.fmt.bufPrintZ(&dmxbuf, "/dev/dvb/adapter{d}/demux{d}", .{ adapter, demux });

    // three independent section filters on the same demux device:
    const fd_sdt = demuxOpenFor(dmx_path, chosen_fe) orelse return error.DemuxOpen;
    defer _ = linux.close(fd_sdt);
    try setSectionFilter(fd_sdt, 0x11, 0x42, 0xfb, null); // SDT actual (0x42) + other (0x46)

    const fd_nit = demuxOpenFor(dmx_path, chosen_fe) orelse return error.DemuxOpen;
    defer _ = linux.close(fd_nit);
    // NIT: DVB default 0x10/0x40, or the platform's private pid/table (M7: 0xBC)
    try setSectionFilter(fd_nit, p.nit_pid, p.nit_table_id, if (p.nit_other) 0xfe else 0xff, null);

    var fd_bat: i32 = -1;
    if (p.bat_bouquet_id != 0) {
        fd_bat = demuxOpenFor(dmx_path, chosen_fe) orelse return error.DemuxOpen;
        try setSectionFilter(fd_bat, p.bat_pid, 0x4a, 0xff, p.bat_bouquet_id); // BAT of our bouquet
    }
    defer if (fd_bat >= 0) {
        _ = linux.close(fd_bat);
    };

    var seen = std.AutoHashMap(u32, void).init(alloc);
    defer seen.deinit();
    var seen_tp = Seen.init(alloc);
    defer seen_tp.deinit();
    var seen_lcn = Seen.init(alloc);
    defer seen_lcn.deinit();

    var ids: [2]u16 = .{ 0, 0 };
    var secbuf: [4200]u8 = undefined;
    var fds_buf: [3]linux.pollfd = undefined;
    var nfds: usize = 2;
    fds_buf[0] = .{ .fd = fd_sdt, .events = linux.POLL.IN, .revents = 0 };
    fds_buf[1] = .{ .fd = fd_nit, .events = linux.POLL.IN, .revents = 0 };
    if (fd_bat >= 0) {
        fds_buf[2] = .{ .fd = fd_bat, .events = linux.POLL.IN, .revents = 0 };
        nfds = 3;
    }
    // SI tables repeat cyclically, so we stop after a scan-time cap — but a large
    // BAT can cycle slower than the cap, so we track its section completeness
    // (section_number/last_section_number) and keep going until every section
    // arrived (hard cap = 4x scan time). Idle ends early only on a quiet mux.
    // Real wall-clock time; each ready fd is drained to EAGAIN (busy muxes push
    // sections faster than one-read-per-poll).
    const idle_limit: u32 = 40; // 12s of silence = done
    var bat_version: i32 = -1;
    var bat_last: i32 = -1;
    var bat_got = [_]bool{false} ** 256;
    const t0 = nowMs();
    var idle: u32 = 0;
    // Past the nominal scan time we keep going while the mux is still telling us
    // something new: a fixed multiple of the scan time cuts slow, large tables
    // (Sky's BAT cycles far slower than a typical scan window) yet makes every
    // fast platform wait for nothing. Progress, not the clock, decides.
    const stall_ms: i64 = 15000; // no new service/LCN/section for this long = done
    const abs_cap_ms: i64 = @as(i64, scan_secs) * 12000; // safety net
    var last_progress = nowMs();
    var prog_sig: usize = 0;
    while (idle < idle_limit) {
        const elapsed = nowMs() - t0;
        var bat_sections: usize = 0;
        for (bat_got) |g| {
            if (g) bat_sections += 1;
        }
        const sig = seen.count() + seen_lcn.count() + seen_tp.count() + bat_sections;
        if (sig != prog_sig) {
            prog_sig = sig;
            last_progress = nowMs();
        }
        if (elapsed >= @as(i64, scan_secs) * 1000) {
            const bat_done = fd_bat < 0 or batComplete(bat_last, &bat_got);
            const stalled = nowMs() - last_progress >= stall_ms;
            if (bat_done or stalled or elapsed >= abs_cap_ms) break;
        }
        const nr = linux.poll(&fds_buf, @intCast(nfds), 300);
        if (linux.errno(nr) != .SUCCESS) break;
        if (nr == 0) {
            idle += 1;
            continue;
        }
        idle = 0;
        var fi: usize = 0;
        while (fi < nfds) : (fi += 1) {
            if (fds_buf[fi].revents & linux.POLL.IN == 0) continue;
            // Drain the fd, but bounded: old drivers can return 0 on buffer
            // overflow (busy-loop bait), and the outer loop must keep checking
            // the clock.
            var drained: u32 = 0;
            while (drained < 256) : (drained += 1) {
            const n = linux.read(fds_buf[fi].fd, &secbuf, secbuf.len);
            const e = linux.errno(n);
            if (e != .SUCCESS) break; // AGAIN = drained; other errors: stop this fd for now
            if (n == 0) break;
            if (n < 12) continue;
            const sec = secbuf[0..n];
            if (fds_buf[fi].fd == fd_sdt) {
                parseSdt(sec, &ids, &out, &seen);
            } else if (fds_buf[fi].fd == fd_nit) {
                if (sec[0] == p.nit_table_id or (p.nit_other and sec[0] == p.nit_table_id + 1)) {
                    parseNitLike(sec, sec[0], null, p.nit_lcn_desc, "nit", &out, &seen_tp, &seen_lcn, null);
                }
            } else {
                if (sec.len > 7 and u16be(sec, 3) == p.bat_bouquet_id) {
                    const ver: i32 = (sec[5] >> 1) & 0x1f;
                    if (ver != bat_version) { // list update mid-scan: start over
                        bat_version = ver;
                        bat_last = sec[7];
                        bat_got = [_]bool{false} ** 256;
                    }
                    bat_got[sec[6]] = true;
                }
                parseNitLike(sec, 0x4a, p.bat_bouquet_id, p.bat_lcn_desc, "bat", &out, &seen_tp, &seen_lcn, null);
            }
            }
        }
    }

    if (fd_bat >= 0 and !batComplete(bat_last, &bat_got)) {
        std.debug.print("[satscan] warning: BAT incomplete (some sections never arrived)\n", .{});
    }
    _ = linux.ioctl(fd_sdt, DMX_STOP, 0);
    _ = linux.ioctl(fd_nit, DMX_STOP, 0);
    if (fd_bat >= 0) _ = linux.ioctl(fd_bat, DMX_STOP, 0);
    std.debug.print("[satscan] services={d} transponders={d} lcn={d}\n", .{ seen.count(), seen_tp.count(), seen_lcn.count() });
}
