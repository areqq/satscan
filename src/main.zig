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

// ---------- provider table ----------
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
    bat_bouquet_id: u16 = 0, // 0 = no BAT scan
    bat_lcn_desc: u8 = 0, // LCN descriptor in BAT (Canal+: 0x83)
    nit_lcn_desc: u8 = 0, // LCN descriptor in NIT (Polsat: 0x82)
    nit_other: bool = false, // also read NIT-other 0x41 (Tivusat keeps LCN there)
};

const FEC_2_3: u32 = 2;

const PROVIDERS = [_]Provider{
    .{ .key = "canalplus", .name = "Platforma Canal+", .freq = 10719000, .sr = 27500000, .pol_h = false, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 318, .tsid = 11000, .bat_bouquet_id = 0x2020, .bat_lcn_desc = 0x83 },
    .{ .key = "polsat", .name = "Polsat Box", .freq = 12188000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 113, .tsid = 7400, .nit_lcn_desc = 0x82 },
    .{ .key = "nova", .name = "Nova Greece", .freq = 11823000, .sr = 27500000, .pol_h = true, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 318, .tsid = 5500, .bat_bouquet_id = 0x0001, .bat_lcn_desc = 0x93 },
    .{ .key = "skyitalia", .name = "Sky Italia", .freq = 11881000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS, .mod = QPSK, .onid = 64511, .tsid = 5800, .bat_bouquet_id = 0x6250, .bat_lcn_desc = 0xb1 },
    .{ .key = "tivusat", .name = "Tivusat", .freq = 10992000, .sr = 27500000, .pol_h = false, .fec = FEC_2_3, .sys = SYS_DVBS, .mod = QPSK, .onid = 318, .tsid = 12400, .nit_lcn_desc = 0x83, .nit_other = true },
    .{ .key = "vivacom", .name = "Vivacom", .freq = 12713000, .sr = 30000000, .pol_h = false, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 213, .tsid = 10000, .bat_bouquet_id = 0x6158, .bat_lcn_desc = 0xe2 },
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

fn tune(fd: i32, p: Provider, lnb: Lnb, scr: ?Scr) !void {
    const high = p.freq >= lnb.sw;
    var ifreq: u32 = if (high) p.freq - lnb.hi else p.freq - lnb.lo;

    if (scr) |u| {
        // Unicable EN50494: SCR command sent at 18V, reception on the slot IF
        const tp_if_mhz = ifreq / 1000;
        const t: u32 = (tp_if_mhz + u.freq_mhz + 2) / 4 - 350;
        var cmd = dvb_diseqc_master_cmd{ .msg = .{
            0xE0, 0x10, 0x5A,
            (@as(u8, u.slot & 0x07) << 5) | (@as(u8, @intFromBool(p.pol_h)) << 3) | (@as(u8, @intFromBool(high)) << 2) | @as(u8, @intCast((t >> 8) & 0x03)),
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
        // tone/voltage by band and polarisation (universal LNB, no DiSEqC)
        const voltage: u32 = if (p.pol_h) SEC_VOLTAGE_18 else SEC_VOLTAGE_13;
        const tone: u32 = if (high) SEC_TONE_ON else SEC_TONE_OFF;
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

fn parseSdt(section: []const u8, onid_out: *u16, out: *Out, seen: *std.AutoHashMap(u32, void)) void {
    if (section.len < 12) return;
    if (section[0] != 0x42 and section[0] != 0x46) return;
    const tsid = u16be(section, 3);
    const onid = u16be(section, 8);
    onid_out.* = onid;
    loop_fuse = 0;
    var pos: usize = 11; // past SDT header, into the service loop
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    const end = 3 + section_len - 4; // excluding CRC
    while (pos + 5 <= end and pos + 5 <= section.len) {
        if (fuse("sdt-svc")) return;
        const sid = u16be(section, pos);
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
            out.line("S {X:0>4}:{X:0>4}:{X:0>4} type={d} \"{s}\" \"{s}\"\n", .{ sid, tsid, onid, stype, name_buf[0..name_len], prov_buf[0..prov_len] });
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
                out: *Out, seen_tp: *Seen, seen_lcn: *Seen) void {
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
const NimCfg = struct {
    seen: bool = false,
    mode: NimMode = .unknown,
    diseqc130: bool = false, // simple mode: diseqcA=130
    adv130: bool = false, // advanced mode: sat.130 configured
    unicable: bool = false,
    scr_slot: u8 = 0,
    scr_freq: u32 = 0,

    fn eligible13e(self: NimCfg) bool {
        return switch (self.mode) {
            .nothing => false,
            .advanced => self.adv130,
            else => self.diseqc130 or self.adv130,
        };
    }
};

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
        const kv = rest[dot + 1 ..];
        if (std.mem.startsWith(u8, kv, "configMode=")) {
            const v = valueAfterEq(kv);
            c.mode = if (std.mem.eql(u8, v, "simple")) .simple
            else if (std.mem.eql(u8, v, "advanced")) .advanced
            else if (std.mem.eql(u8, v, "nothing")) .nothing
            else if (std.mem.eql(u8, v, "equal")) .equal
            else if (std.mem.eql(u8, v, "loopthrough")) .loopthrough
            else if (std.mem.eql(u8, v, "satposdepends")) .satposdepends
            else .unknown;
        } else if (std.mem.eql(u8, kv, "diseqcA=130")) {
            c.diseqc130 = true;
        } else if (std.mem.startsWith(u8, kv, "advanced.sat.130.")) {
            c.adv130 = true;
        } else if (std.mem.indexOf(u8, kv, ".lof=unicable") != null) {
            c.unicable = true;
        } else if (std.mem.indexOf(u8, kv, ".scrfrequency=") != null) {
            c.scr_freq = std.fmt.parseInt(u32, valueAfterEq(kv), 10) catch 0;
        } else if (std.mem.indexOf(u8, kv, ".scrList=") != null) {
            const n = std.fmt.parseInt(u8, valueAfterEq(kv), 10) catch 0;
            c.scr_slot = if (n > 0) n - 1 else 0; // UB number (1-based) -> EN50494 index
        }
    }
    return true;
}

// equal/loopthrough/satposdepends inherit the first fully configured NIM
fn effectiveNim(nims: []const NimCfg, idx: usize) ?NimCfg {
    if (idx >= nims.len) return null;
    const c = nims[idx];
    switch (c.mode) {
        .nothing => return null,
        .equal, .loopthrough, .satposdepends => {
            for (nims) |donor| {
                if (donor.eligible13e() and donor.mode != .equal and donor.mode != .loopthrough and donor.mode != .satposdepends) return donor;
            }
            return null;
        },
        else => return if (c.eligible13e()) c else null,
    }
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
        }
    }

    const p = findProvider(provider_key) orelse {
        std.debug.print("[satscan] unknown provider '{s}' (canalplus|polsat|nova|skyitalia|tivusat|vivacom)\n", .{provider_key});
        return error.BadProvider;
    };

    // Tuner configuration from enigma settings (unicable, 13E assignment).
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

    // Auto-selection: successive frontends; NIM config from settings; busy (EBUSY)
    // or no LOCK -> next one. --frontend pins a specific tuner.
    var pathbuf: [64]u8 = undefined;
    var fe: i32 = -1;
    var chosen_fe: u32 = 0;
    var locked = false;
    var f: u32 = if (fe_index) |fi| fi else 0;
    const f_end: u32 = if (fe_index) |fi| fi + 1 else 16;
    while (f < f_end) : (f += 1) {
        var scr: ?Scr = cli_scr;
        if (have_settings) {
            if (effectiveNim(&nims, f)) |cfg| {
                if (cli_scr == null and cfg.unicable and cfg.scr_freq != 0) {
                    scr = Scr{ .slot = cfg.scr_slot, .freq_mhz = cfg.scr_freq };
                }
            } else if (fe_index == null) {
                continue; // NIM not configured for 13E - skipped in auto mode
            } else {
                std.debug.print("[satscan] frontend{d}: NIM not configured for 13E - trying anyway\n", .{f});
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
            std.debug.print("[satscan] frontend{d}: unicable slot={d} freq={d}MHz\n", .{ f, u.slot, u.freq_mhz });
        } else {
            std.debug.print("[satscan] frontend{d}: plain LNB\n", .{f});
        }
        tune(fd, p, lnb, scr) catch {
            _ = linux.close(fd);
            continue;
        };
        var ok = waitLock(fd, secs);
        if (!ok and scr != null) { // unicable can be moody - one retry
            tune(fd, p, lnb, scr) catch {};
            ok = waitLock(fd, secs);
        }
        if (ok) {
            fe = fd;
            chosen_fe = f;
            locked = true;
            break;
        }
        std.debug.print("[satscan] frontend{d}: no LOCK\n", .{f});
        _ = linux.close(fd);
    }
    if (fe < 0) {
        std.debug.print("[satscan] no tuner achieved LOCK on 13E\n", .{});
        return error.NoLock;
    }
    defer _ = linux.close(fe);
    std.debug.print("[satscan] tuner: frontend{d}\n", .{chosen_fe});

    var out = Out{};
    out.line("# provider={s} freq={d} pol={s} lock={d} frontend={d}\n", .{ p.name, p.freq, if (p.pol_h) "H" else "V", @intFromBool(locked), chosen_fe });

    var dmxbuf: [64]u8 = undefined;
    const dmx_path = try std.fmt.bufPrintZ(&dmxbuf, "/dev/dvb/adapter{d}/demux{d}", .{ adapter, demux });

    // three independent section filters on the same demux device:
    const fd_sdt = sysOpen(dmx_path, true) orelse return error.DemuxOpen;
    defer _ = linux.close(fd_sdt);
    try setSectionFilter(fd_sdt, 0x11, 0x42, 0xfb, null); // SDT actual (0x42) + other (0x46)

    const fd_nit = sysOpen(dmx_path, true) orelse return error.DemuxOpen;
    defer _ = linux.close(fd_nit);
    try setSectionFilter(fd_nit, 0x10, 0x40, if (p.nit_other) 0xfe else 0xff, null); // NIT actual (+other)

    var fd_bat: i32 = -1;
    if (p.bat_bouquet_id != 0) {
        fd_bat = sysOpen(dmx_path, true) orelse return error.DemuxOpen;
        try setSectionFilter(fd_bat, 0x11, 0x4a, 0xff, p.bat_bouquet_id); // BAT of our bouquet
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

    var onid: u16 = 0;
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
    while (idle < idle_limit) {
        const elapsed = nowMs() - t0;
        if (elapsed >= @as(i64, scan_secs) * 1000) {
            const bat_done = fd_bat < 0 or batComplete(bat_last, &bat_got);
            if (bat_done or elapsed >= @as(i64, scan_secs) * 4000) break;
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
                parseSdt(sec, &onid, &out, &seen);
            } else if (fds_buf[fi].fd == fd_nit) {
                if (sec[0] == 0x40 or (p.nit_other and sec[0] == 0x41)) {
                    parseNitLike(sec, sec[0], null, p.nit_lcn_desc, "nit", &out, &seen_tp, &seen_lcn);
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
                parseNitLike(sec, 0x4a, p.bat_bouquet_id, p.bat_lcn_desc, "bat", &out, &seen_tp, &seen_lcn);
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
