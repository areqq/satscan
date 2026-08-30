// satscan — niezalezna binarka (Zig 0.16) do skanowania list Polsat/Canal+ z 13E.
// Stroi frontend DVB-S2 (antena 1x1, BEZ DiSEqC — samo napiecie + ton 22kHz),
// czeka na LOCK, czyta z demuxa sekcje SI (SDT/NIT/BAT) i wypisuje surowy tekst
// (po jednej linii na wpis), ktory dalej obrabiamy naszymi skryptami.
//
// Uzycie: satscan [--adapter N] [--frontend N] [--demux N] --provider canalplus|polsat
//                 [--lnb-lo kHz] [--lnb-hi kHz] [--lnb-sw kHz] [--secs S]
//
// Format wyjscia (stdout):
//   # provider=<p> freq=<kHz> pol=<H|V> lock=<0|1>
//   S <sid_hex>:<tsid_hex>:<onid_hex> type=<n> "<name>" "<provider>"
//   (kolejne tablice — NIT/BAT z LCN — dochodza w nastepnej iteracji)

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

// ---------- ioctl ----------
fn ioc(dir: u32, typ: u32, nr: u32, size: u32) u32 {
    return (dir << 30) | (size << 16) | (typ << 8) | nr;
}
const IOC_NONE: u32 = 0;
const IOC_WRITE: u32 = 1;
const IOC_READ: u32 = 2;
const O: u32 = 'o';

// ---------- DVB frontend (API v5) ----------
const FE_HAS_LOCK: u32 = 0x10;

const SEC_VOLTAGE_13: u32 = 0; // pion (V)
const SEC_VOLTAGE_18: u32 = 1; // poziom (H)
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
    pad: [48]u8 = [_]u8{0} ** 48, // reszta unii u (na 32-bit: 52 bajty razem z data)
    result: i32 = 0,
};

const dtv_properties = extern struct {
    num: u32,
    props: [*]dtv_property,
};

const FE_SET_PROPERTY = ioc(IOC_WRITE, O, 82, @sizeOf(dtv_properties));
const FE_READ_STATUS = ioc(IOC_READ, O, 69, 4);
const FE_SET_VOLTAGE = ioc(IOC_NONE, O, 67, 0);
const FE_SET_TONE = ioc(IOC_NONE, O, 66, 0);

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
const DMX_SET_FILTER = ioc(IOC_WRITE, O, 43, @sizeOf(dmx_sct_filter_params));
const DMX_STOP = ioc(IOC_NONE, O, 42, 0);

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
};

const PROVIDERS = [_]Provider{
    .{ .key = "canalplus", .name = "Platforma Canal+", .freq = 10719000, .sr = 27500000, .pol_h = false, .fec = FEC_5_6, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 318, .tsid = 11000 },
    .{ .key = "polsat", .name = "Polsat Box", .freq = 12188000, .sr = 27500000, .pol_h = false, .fec = FEC_3_4, .sys = SYS_DVBS2, .mod = PSK_8, .onid = 113, .tsid = 7400 },
};

// ---------- I/O na surowych syscallach (bez libc) ----------
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

fn sleepMs(ms: u32) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @as(isize, @intCast(ms % 1000)) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

// ---------- helpers ----------
fn ioctlChecked(fd: i32, request: u32, arg: usize, what: []const u8) !void {
    const rc = linux.ioctl(fd, request, arg);
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("[satscan] ioctl {s} nieudany: {t}\n", .{ what, linux.errno(rc) });
        return error.Ioctl;
    }
}

const Lnb = struct { lo: u32 = 9750000, hi: u32 = 10600000, sw: u32 = 11700000 };

fn tune(fd: i32, p: Provider, lnb: Lnb) !void {
    // ton/napiecie wg pasma i polaryzacji (uniwersalny LNB, bez DiSEqC)
    const high = p.freq >= lnb.sw;
    const ifreq: u32 = if (high) p.freq - lnb.hi else p.freq - lnb.lo;
    const voltage: u32 = if (p.pol_h) SEC_VOLTAGE_18 else SEC_VOLTAGE_13;
    const tone: u32 = if (high) SEC_TONE_ON else SEC_TONE_OFF;

    try ioctlChecked(fd, FE_SET_VOLTAGE, voltage, "FE_SET_VOLTAGE");
    try ioctlChecked(fd, FE_SET_TONE, tone, "FE_SET_TONE");

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

fn setSectionFilter(fd: i32, pid: u16, table_id: u8) !void {
    var params = dmx_sct_filter_params{
        .pid = pid,
        .filter = .{},
        .timeout = 0,
        .flags = DMX_CHECK_CRC | DMX_IMMEDIATE_START,
    };
    params.filter.filter[0] = table_id;
    params.filter.mask[0] = 0xff;
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
    const tsid = u16be(section, 3);
    const onid = u16be(section, 8);
    onid_out.* = onid;
    var pos: usize = 11; // po naglowku SDT do petli uslug
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    const end = 3 + section_len - 4; // bez CRC
    while (pos + 5 <= end and pos + 5 <= section.len) {
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
            d += 2 + dlen;
        }
        const key = (@as(u32, sid) << 16) | tsid;
        if (seen.get(key) == null) {
            seen.put(key, {}) catch {};
            out.line("S {X:0>4}:{X:0>4}:{X:0>4} type={d} \"{s}\" \"{s}\"\n", .{ sid, tsid, onid, stype, name_buf[0..name_len], prov_buf[0..prov_len] });
        }
        pos = dend;
    }
}

// kopiuje nazwe DVB, pomija pierwszy bajt-wskaznik kodowania (<0x20), zamienia znaki kontrolne na spacje
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

fn findProvider(key: []const u8) ?Provider {
    for (PROVIDERS) |p| {
        if (std.mem.eql(u8, p.key, key)) return p;
    }
    return null;
}

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;

    var adapter: u32 = 0;
    var fe_index: ?u32 = null; // null = auto-szukaj wolnego tunera
    var demux: u32 = 0;
    var provider_key: []const u8 = "canalplus";
    var lnb = Lnb{};
    var secs: u32 = 8;

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
        }
    }

    const p = findProvider(provider_key) orelse {
        std.debug.print("[satscan] nieznany provider '{s}' (canalplus|polsat)\n", .{provider_key});
        return error.BadProvider;
    };

    // Otwarcie tunera: podany --frontend, albo auto — pierwszy, ktory sie otworzy
    // (zajety przez enigme zwraca EBUSY i jest pomijany).
    var pathbuf: [64]u8 = undefined;
    var fe: i32 = -1;
    var chosen_fe: u32 = 0;
    if (fe_index) |fi| {
        const fe_path = try std.fmt.bufPrintZ(&pathbuf, "/dev/dvb/adapter{d}/frontend{d}", .{ adapter, fi });
        fe = sysOpen(fe_path, true) orelse {
            std.debug.print("[satscan] frontend{d} zajety/niedostepny\n", .{fi});
            return error.TunerBusy;
        };
        chosen_fe = fi;
    } else {
        var f: u32 = 0;
        while (f < 8) : (f += 1) {
            const fe_path = try std.fmt.bufPrintZ(&pathbuf, "/dev/dvb/adapter{d}/frontend{d}", .{ adapter, f });
            if (sysOpen(fe_path, true)) |fd| {
                fe = fd;
                chosen_fe = f;
                break;
            }
        }
        if (fe < 0) {
            std.debug.print("[satscan] brak wolnego tunera (zajete przez enigme?) — zwolnij tuner albo zatrzymaj enigme2\n", .{});
            return error.NoFreeTuner;
        }
    }
    defer _ = linux.close(fe);
    std.debug.print("[satscan] tuner: frontend{d}\n", .{chosen_fe});

    try tune(fe, p, lnb);
    const locked = waitLock(fe, secs);

    var out = Out{};
    out.line("# provider={s} freq={d} pol={s} lock={d}\n", .{ p.name, p.freq, if (p.pol_h) "H" else "V", @intFromBool(locked) });
    if (!locked) {
        std.debug.print("[satscan] brak LOCK — sprawdz LNB/kabel/pozycje anteny\n", .{});
        return error.NoLock;
    }

    var dmxbuf: [64]u8 = undefined;
    const dmx_path = try std.fmt.bufPrintZ(&dmxbuf, "/dev/dvb/adapter{d}/demux{d}", .{ adapter, demux });
    const dfd = sysOpen(dmx_path, false) orelse return error.DemuxOpen;
    defer _ = linux.close(dfd);

    try setSectionFilter(dfd, 0x11, 0x42); // SDT actual

    var seen = std.AutoHashMap(u32, void).init(alloc);
    defer seen.deinit();

    var onid: u16 = 0;
    var secbuf: [4096]u8 = undefined;
    var pfd = [_]linux.pollfd{.{ .fd = dfd, .events = linux.POLL.IN, .revents = 0 }};
    var idle: u32 = 0;
    while (idle < 30) {
        const nr = linux.poll(&pfd, 1, 300);
        if (linux.errno(nr) != .SUCCESS) break;
        if (nr == 0) {
            idle += 1;
            continue;
        }
        idle = 0;
        const n = linux.read(dfd, &secbuf, secbuf.len);
        if (linux.errno(n) != .SUCCESS or n < 4) continue;
        parseSdt(secbuf[0..n], &onid, &out, &seen);
    }

    _ = linux.ioctl(dfd, DMX_STOP, 0);
    std.debug.print("[satscan] uslug SDT: {d}\n", .{seen.count()});
}
