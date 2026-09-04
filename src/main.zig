// satscan — standalone binary (Zig 0.16) scanning platform channel line-ups
// straight off a DVB-S2 tuner: Hot Bird 13.0E and Astra 19.2E platforms with
// logical channel numbers, or a full-satellite scan from satellites.xml.
//
// Automatic operation: reads /etc/enigma2/settings and picks a tuner by itself —
// skips NIMs that cannot reach the target position, recognises Unicable
// (EN50494), committed DiSEqC, DiSEqC 1.1 uncommitted (cascaded dishes) and a
// plain universal LNB, and tries successive frontends until one locks on a real
// stream. Reads SI sections from the demux: SDT actual+other (service names),
// NIT and BAT (transponders + LCN). Data on stdout, diagnostics on stderr.
//
// Run `satscan --help` for the full option list.
//
// Output format (stdout):
//   # provider=<p> freq=<kHz> pol=<H|V> lock=1 frontend=<n>
//   T <tsid>:<onid> freq=<kHz> pol=<..> sr=<sym/s> fec=<n> sys=<S|S2> pos=<...> mod=<n>
//   S <sid>:<tsid>:<onid> type=<n> ca=<0|1> "<name>" "<provider>"
//   L <lcn> <sid>:<tsid>:<onid> visible=<0|1> [region=<n>] src=<nit|bat>

const std = @import("std");
const linux = std.os.linux;
const dvb = @import("dvb.zig");
const si = @import("si.zig");
const settings = @import("settings.zig");
const providers = @import("providers.zig");

const Provider = providers.Provider;

const USAGE =
    \\satscan — scan a satellite platform's channel line-up off a DVB-S2 tuner
    \\
    \\  satscan --provider <key> [options]      scan one platform (services + LCN)
    \\  satscan --scan-all [--pos <deg*10>]      every transponder of a satellite
    \\  satscan --dry-run ...                    show the tuner/dish decision only
    \\
    \\Providers: {s}
    \\
    \\Tuner selection (default: automatic from /etc/enigma2/settings):
    \\  --adapter N          DVB adapter (default 0)
    \\  --frontend N         pin a frontend instead of trying each in turn
    \\  --demux N            demux device (default 0)
    \\  --settings PATH      enigma settings file (default /etc/enigma2/settings)
    \\  --diseqc-port N      force committed DiSEqC port 0-3
    \\  --scr-slot N --scr-freq MHz   force Unicable EN50494 user band
    \\  --lnb-lo/--lnb-hi/--lnb-sw kHz  LNB local oscillators / band switch
    \\
    \\Timing:
    \\  --secs S             wait for LOCK per transponder (default 8)
    \\  --scan-secs S        nominal SI read time; extends while data still
    \\                       arrives, stops after 15 s of silence (default 25)
    \\
    \\Full-satellite scan:
    \\  --pos P              orbital position x10, e.g. 130, 192 (default 130)
    \\  --satxml PATH        satellites.xml (default /etc/tuxbox/satellites.xml)
    \\  --tp-secs S          SI read time per transponder (default 4)
    \\  --max-tp N           stop after N transponders (default: all)
    \\
;

fn usage() void {
    var kb: [512]u8 = undefined;
    std.debug.print(USAGE, .{providers.listKeys(&kb)});
}

const Cli = struct {
    adapter: u32 = 0,
    fe_index: ?u32 = null, // null = auto-select a working tuner
    demux: u32 = 0,
    provider_key: ?[]const u8 = null,
    lnb: dvb.Lnb = .{},
    secs: u32 = 8,
    scan_secs: u32 = 25,
    scr_slot: ?u8 = null,
    scr_freq: u32 = 0,
    settings_path: [:0]const u8 = "/etc/enigma2/settings",
    cli_port: ?u8 = null,
    dry_run: bool = false,
    scan_all: bool = false,
    satxml_path: [:0]const u8 = "/etc/tuxbox/satellites.xml",
    sat_pos: u32 = 130,
    tp_secs: u32 = 4,
    max_tp: usize = 0,
};

fn argInt(comptime T: type, it: *std.process.Args.Iterator, flag: []const u8) !T {
    const raw = it.next() orelse {
        std.debug.print("[satscan] {s} needs a value\n", .{flag});
        return error.BadArgs;
    };
    return std.fmt.parseInt(T, raw, 10) catch {
        std.debug.print("[satscan] {s}: '{s}' is not a number\n", .{ flag, raw });
        return error.BadArgs;
    };
}

fn argStr(it: *std.process.Args.Iterator, flag: []const u8) ![:0]const u8 {
    return it.next() orelse {
        std.debug.print("[satscan] {s} needs a value\n", .{flag});
        return error.BadArgs;
    };
}

fn parseCli(init: std.process.Init.Minimal) !Cli {
    var c = Cli{};
    var it = std.process.Args.Iterator.init(init.args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            usage();
            return error.Help;
        } else if (std.mem.eql(u8, a, "--adapter")) {
            c.adapter = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--frontend")) {
            c.fe_index = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--demux")) {
            c.demux = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--provider")) {
            c.provider_key = try argStr(&it, a);
        } else if (std.mem.eql(u8, a, "--lnb-lo")) {
            c.lnb.lo = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--lnb-hi")) {
            c.lnb.hi = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--lnb-sw")) {
            c.lnb.sw = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--secs")) {
            c.secs = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--scan-secs")) {
            c.scan_secs = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--scr-slot")) {
            c.scr_slot = try argInt(u8, &it, a);
        } else if (std.mem.eql(u8, a, "--scr-freq")) {
            c.scr_freq = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--settings")) {
            c.settings_path = try argStr(&it, a);
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            c.dry_run = true;
        } else if (std.mem.eql(u8, a, "--diseqc-port")) {
            c.cli_port = try argInt(u8, &it, a);
        } else if (std.mem.eql(u8, a, "--scan-all")) {
            c.scan_all = true;
        } else if (std.mem.eql(u8, a, "--satxml")) {
            c.satxml_path = try argStr(&it, a);
        } else if (std.mem.eql(u8, a, "--pos")) {
            c.sat_pos = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--tp-secs")) {
            c.tp_secs = try argInt(u32, &it, a);
        } else if (std.mem.eql(u8, a, "--max-tp")) {
            c.max_tp = try argInt(usize, &it, a);
        } else {
            std.debug.print("[satscan] unknown option '{s}' (see --help)\n", .{a});
            return error.BadArgs;
        }
    }
    if (c.secs == 0 or c.scan_secs == 0 or c.tp_secs == 0) {
        std.debug.print("[satscan] --secs, --scan-secs and --tp-secs must be > 0\n", .{});
        return error.BadArgs;
    }
    if (c.cli_port) |pt| if (pt > 3) {
        std.debug.print("[satscan] --diseqc-port must be 0-3\n", .{});
        return error.BadArgs;
    };
    if (c.scr_slot != null and c.scr_freq == 0) {
        std.debug.print("[satscan] --scr-slot requires --scr-freq <MHz>\n", .{});
        return error.BadArgs;
    }
    if (!c.scan_all and c.provider_key == null) {
        usage();
        std.debug.print("[satscan] --provider <key> or --scan-all is required\n", .{});
        return error.BadArgs;
    }
    return c;
}

// ---------- tuner selection ----------

const Tuner = struct {
    fd: i32,
    index: u32,
    sw: dvb.Switch,
    tp: dvb.Tp, // the transponder that actually locked
};

const SelectError = error{ NoLock, PositionNotConfigured, TunerBusy, OutOfMemory, Overflow };

/// Walk the frontends (or the pinned one), pick the first that opens, reaches
/// `target_pos` per settings and locks on a real stream for one of `cands`.
fn selectTuner(cli: Cli, nims: []const settings.NimCfg, have_settings: bool, target_pos: u32, cands: []const dvb.Tp, dmx_path: [*:0]const u8) SelectError!Tuner {
    const cli_scr: ?dvb.Scr = if (cli.scr_slot) |sl| .{ .slot = sl, .freq_mhz = cli.scr_freq } else null;
    var pathbuf: [64]u8 = undefined;
    var tuners_tried: usize = 0; // frontends we actually tuned
    var unreachable_nims: usize = 0; // skipped: dish config cannot reach target_pos
    var f: u32 = cli.fe_index orelse 0;
    const f_end: u32 = if (cli.fe_index) |fi| fi + 1 else settings.MAX_NIMS;
    while (f < f_end) : (f += 1) {
        var sw = dvb.Switch{ .scr = cli_scr, .committed = cli.cli_port };
        if (have_settings) {
            if (settings.effectiveNim(nims, f, target_pos)) |cfg| {
                sw = cfg.switchFor(target_pos, cli_scr, cli.cli_port);
            } else if (cli.fe_index == null) {
                unreachable_nims += 1;
                continue; // this NIM cannot reach the target position - skip
            } else {
                std.debug.print("[satscan] frontend{d}: NIM not configured for {d}.{d}E - trying anyway\n", .{ f, target_pos / 10, target_pos % 10 });
            }
        }
        const fe_path = std.fmt.bufPrintZ(&pathbuf, "/dev/dvb/adapter{d}/frontend{d}", .{ cli.adapter, f }) catch return error.Overflow;
        const fd = dvb.sysOpen(fe_path, true) orelse {
            if (cli.fe_index != null) {
                std.debug.print("[satscan] frontend{d} busy/unavailable\n", .{f});
                return error.TunerBusy;
            }
            continue;
        };
        if (sw.scr) |u| {
            std.debug.print("[satscan] frontend{d}: unicable slot={d} freq={d}MHz{s}\n", .{ f, u.slot, u.freq_mhz, if (sw.committed != null) " (+bank)" else "" });
        } else if (sw.committed) |pt| {
            std.debug.print("[satscan] frontend{d}: plain LNB, DiSEqC committed port {d}{s}\n", .{ f, pt, if (sw.uncommitted != null) " + uncommitted" else "" });
        } else {
            std.debug.print("[satscan] frontend{d}: plain LNB\n", .{f});
        }
        // scan-all included: a frontend is only accepted once it has locked on a
        // real stream. Taking "the first one that opens" bit us on multi-tuner
        // boxes where frontend0 has no cable - every transponder then reports
        // lock=0 while the working tuner sits idle.
        tuners_tried += 1;
        for (cands) |tp| {
            dvb.tune(fd, tp, cli.lnb, sw) catch continue;
            var ok = dvb.waitLock(fd, cli.secs);
            if (!ok and sw.scr != null) { // unicable can be moody - one retry
                dvb.tune(fd, tp, cli.lnb, sw) catch {};
                ok = dvb.waitLock(fd, cli.secs);
            }
            if (!ok) continue;
            // guard against a lock with no stream behind it (see dvb.streamAlive)
            if (!dvb.streamAlive(dmx_path, f, 2500)) {
                std.debug.print("[satscan] frontend{d}: LOCK but no stream (no PAT) - ignoring\n", .{f});
                continue;
            }
            return .{ .fd = fd, .index = f, .sw = sw, .tp = tp };
        }
        std.debug.print("[satscan] frontend{d}: no LOCK\n", .{f});
        dvb.close(fd);
    }
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

fn printDryRun(nims: []const settings.NimCfg, target_pos: u32, p: Provider, out: *dvb.Out) void {
    out.line("# dry-run target={d}.{d}E provider={s} freq={d} pol={c}\n", .{
        target_pos / 10, target_pos % 10, p.name, p.home.freq, @as(u8, if (p.home.pol_h) 'H' else 'V'),
    });
    for (nims, 0..) |c, ni| {
        if (!c.seen) continue;
        out.line("NIM{d} mode={s} single={d} ab={d} sats=", .{ ni, @tagName(c.mode), @intFromBool(c.single), @intFromBool(c.ab_only) });
        for (c.positions[0..c.nsat], c.ports[0..c.nsat], c.has_port[0..c.nsat]) |pos, port, has| {
            if (has) out.line("{d}(port{d}) ", .{ pos, port }) else out.line("{d} ", .{pos});
        }
        if (c.usesUnicable()) {
            out.line("unicable(slot={d},{d}MHz) ", .{ c.scr_slot, c.scr_freq });
        } else if (c.unicable) {
            out.line("unicable-cfg-ignored(mode!=advanced) ", .{});
        }
        if (settings.effectiveNim(nims, ni, target_pos)) |cfg| {
            const sw = cfg.switchFor(target_pos, null, null);
            if (sw.committed) |pt| {
                if (sw.uncommitted) |u| {
                    out.line("=> WOULD USE, DiSEqC committed port {d} + uncommitted {d}\n", .{ pt, u });
                } else {
                    out.line("=> WOULD USE, DiSEqC committed port {d}\n", .{pt});
                }
            } else if (sw.uncommitted) |u| {
                out.line("=> WOULD USE, DiSEqC uncommitted {d}\n", .{u});
            } else {
                out.line("=> WOULD USE, no switch command\n", .{});
            }
        } else {
            out.line("=> cannot reach target\n", .{});
        }
    }
}

// ---------- full-satellite scan ----------

const ScanAllCtx = struct {
    out: *dvb.Out,
    seen: *si.SeenSvc,
    seen_tp: *si.Seen,
    seen_lcn: *si.SeenLcn,
    queue: *si.TpQueue,
    fd_sdt: i32,
    ids: [2]u16 = .{ 0, 0 },
    got_own_t: bool = false,
    tp: si.TpQueue.QTp,
    pos_label: u32,

    fn onSection(self: *ScanAllCtx, fd: i32, sec: []const u8) void {
        if (fd == self.fd_sdt) {
            si.parseSdt(sec, &self.ids, self.out, self.seen);
            if (!self.got_own_t and self.ids[0] != 0) {
                self.got_own_t = true;
                // synthetic T for the tuned tp (some tps carry no NIT)
                const tpkey: u64 = (@as(u64, self.ids[0]) << 16) | self.ids[1];
                if (self.seen_tp.get(tpkey) == null) {
                    self.seen_tp.put(tpkey, {}) catch {};
                    const t = self.tp.tp;
                    self.out.line("T {X:0>4}:{X:0>4} freq={d} pol={c} sr={d} fec={d} sys={s} pos={d}E mod={d}\n", .{
                        self.ids[0],                               self.ids[1],    t.freq,                                     si.POLCHARS[self.tp.pol], t.sr, t.fec,
                        if (t.sys == dvb.SYS_DVBS2) "S2" else "S", self.pos_label, if (t.mod == dvb.PSK_8) @as(u32, 2) else 1,
                    });
                }
            }
        } else if (sec[0] == 0x40) {
            si.parseNitLike(sec, .{ .table_id = 0x40, .src = "nit" }, self.out, self.seen_tp, self.seen_lcn, self.queue, self.pos_label);
        }
    }
};

/// Walk every transponder from the queue (seeded from satellites.xml, extended
/// live with NIT discoveries), grab SDT actual + NIT on each, emit T/S lines.
/// LCN is provider-specific, so none here.
fn scanAll(t: Tuner, cli: Cli, dmx_path: [*:0]const u8, queue: *si.TpQueue, pos_label: u32, out: *dvb.Out, alloc: std.mem.Allocator) !void {
    var seen = si.SeenSvc.init(alloc);
    defer seen.deinit();
    var seen_tp = si.Seen.init(alloc);
    defer seen_tp.deinit();
    var seen_lcn = si.SeenLcn.init(alloc);
    defer seen_lcn.deinit();

    var locked: u32 = 0;
    var tried: usize = 0;
    var i: usize = 0;
    while (i < queue.len) : (i += 1) {
        if (cli.max_tp != 0 and tried >= cli.max_tp) break;
        tried += 1;
        const q = queue.items[i];
        dvb.tune(t.fd, q.tp, cli.lnb, t.sw) catch {
            out.line("# tp {d}{c} sr={d} lock=err\n", .{ q.tp.freq, si.POLCHARS[q.pol], q.tp.sr });
            continue;
        };
        // Same PAT guard as the provider path: on an FBC input without signal
        // every frequency "locks", and a full scan would report 100% locks with
        // zero services.
        if (!dvb.waitLock(t.fd, cli.secs) or !dvb.streamAlive(dmx_path, t.index, 2000)) {
            out.line("# tp {d}{c} sr={d} lock=0\n", .{ q.tp.freq, si.POLCHARS[q.pol], q.tp.sr });
            continue;
        }
        locked += 1;
        out.line("# tp {d}{c} sr={d} lock=1\n", .{ q.tp.freq, si.POLCHARS[q.pol], q.tp.sr });

        const fd_sdt = dvb.demuxOpenFor(dmx_path, t.index) orelse continue;
        defer dvb.close(fd_sdt);
        const fd_nit = dvb.demuxOpenFor(dmx_path, t.index) orelse continue;
        defer dvb.close(fd_nit);
        dvb.setSectionFilter(fd_sdt, 0x11, 0x42, 0xff, null) catch continue; // SDT actual only
        dvb.setSectionFilter(fd_nit, 0x10, 0x40, 0xff, null) catch continue;

        var fds = [_]linux.pollfd{
            .{ .fd = fd_sdt, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd_nit, .events = linux.POLL.IN, .revents = 0 },
        };
        var ctx = ScanAllCtx{ .out = out, .seen = &seen, .seen_tp = &seen_tp, .seen_lcn = &seen_lcn, .queue = queue, .fd_sdt = fd_sdt, .tp = q, .pos_label = pos_label };
        _ = dvb.pumpSections(&fds, dvb.nowMs() + @as(i64, cli.tp_secs) * 1000, &ctx, ScanAllCtx.onSection);
        dvb.demuxStop(fd_sdt);
        dvb.demuxStop(fd_nit);
    }
    std.debug.print("[satscan] scan-all: tps={d} locked={d} services={d} transponders={d}\n", .{ tried, locked, seen.count(), seen_tp.count() });
}

// ---------- provider scan ----------

const BatTracker = struct {
    version: i32 = -1,
    last: i32 = -1,
    got: [256]bool = [_]bool{false} ** 256,
    count: usize = 0,

    fn note(self: *BatTracker, sec: []const u8) void {
        const ver: i32 = (sec[5] >> 1) & 0x1f;
        if (ver != self.version) { // list update mid-scan: start over
            self.version = ver;
            self.last = sec[7];
            self.got = [_]bool{false} ** 256;
            self.count = 0;
        }
        if (!self.got[sec[6]]) {
            self.got[sec[6]] = true;
            self.count += 1;
        }
    }

    fn complete(self: BatTracker) bool {
        if (self.last < 0) return false; // no section seen yet
        return self.count >= @as(usize, @intCast(self.last)) + 1;
    }
};

const ProviderCtx = struct {
    p: Provider,
    out: *dvb.Out,
    seen: *si.SeenSvc,
    seen_tp: *si.Seen,
    seen_lcn: *si.SeenLcn,
    fd_sdt: i32,
    fd_nit: i32,
    fd_bat: i32,
    ids: [2]u16 = .{ 0, 0 },
    bat: BatTracker = .{},

    fn onSection(self: *ProviderCtx, fd: i32, sec: []const u8) void {
        const p = self.p;
        if (fd == self.fd_sdt) {
            si.parseSdt(sec, &self.ids, self.out, self.seen);
        } else if (fd == self.fd_nit) {
            if (sec[0] == p.nit_table_id or (p.nit_other and sec[0] == p.nit_table_id + 1)) {
                si.parseNitLike(sec, .{ .table_id = sec[0], .lcn_desc = p.nit_lcn_desc, .lcn_layout = p.nit_lcn_layout, .src = "nit" }, self.out, self.seen_tp, self.seen_lcn, null, null);
            }
        } else if (fd == self.fd_bat) {
            if (sec.len > 7 and si.u16be(sec, 3) == p.bat_bouquet_id) self.bat.note(sec);
            si.parseNitLike(sec, .{ .table_id = 0x4a, .want_ext = p.bat_bouquet_id, .lcn_desc = p.bat_lcn_desc, .lcn_layout = p.bat_lcn_layout, .lcn_in_bouquet_loop = p.bat_lcn_in_bouquet_loop, .src = "bat" }, self.out, self.seen_tp, self.seen_lcn, null, null);
        }
    }

    /// Progress signature: anything new since last look means the mux is still
    /// telling us something.
    fn progress(self: ProviderCtx) usize {
        return self.seen.count() + self.seen_lcn.count() + self.seen_tp.count() + self.bat.count;
    }
};

fn scanProvider(t: Tuner, p: Provider, cli: Cli, dmx_path: [*:0]const u8, out: *dvb.Out, alloc: std.mem.Allocator) !void {
    out.line("# provider={s} freq={d} pol={s} lock=1 frontend={d}\n", .{ p.name, t.tp.freq, if (t.tp.pol_h) "H" else "V", t.index });

    // three independent section filters on the same demux device:
    const fd_sdt = dvb.demuxOpenFor(dmx_path, t.index) orelse return error.DemuxOpen;
    defer dvb.close(fd_sdt);
    try dvb.setSectionFilter(fd_sdt, 0x11, 0x42, 0xfb, null); // SDT actual (0x42) + other (0x46)

    const fd_nit = dvb.demuxOpenFor(dmx_path, t.index) orelse return error.DemuxOpen;
    defer dvb.close(fd_nit);
    // NIT: DVB default 0x10/0x40, or the platform's private pid/table (M7: 0xBC)
    try dvb.setSectionFilter(fd_nit, p.nit_pid, p.nit_table_id, if (p.nit_other) 0xfe else 0xff, null);

    var fd_bat: i32 = -1;
    if (p.bat_bouquet_id != 0) {
        fd_bat = dvb.demuxOpenFor(dmx_path, t.index) orelse return error.DemuxOpen;
        try dvb.setSectionFilter(fd_bat, p.bat_pid, 0x4a, 0xff, p.bat_bouquet_id); // BAT of our bouquet
    }
    defer if (fd_bat >= 0) dvb.close(fd_bat);

    var seen = si.SeenSvc.init(alloc);
    defer seen.deinit();
    var seen_tp = si.Seen.init(alloc);
    defer seen_tp.deinit();
    var seen_lcn = si.SeenLcn.init(alloc);
    defer seen_lcn.deinit();

    var fds_buf: [3]linux.pollfd = undefined;
    var nfds: usize = 2;
    fds_buf[0] = .{ .fd = fd_sdt, .events = linux.POLL.IN, .revents = 0 };
    fds_buf[1] = .{ .fd = fd_nit, .events = linux.POLL.IN, .revents = 0 };
    if (fd_bat >= 0) {
        fds_buf[2] = .{ .fd = fd_bat, .events = linux.POLL.IN, .revents = 0 };
        nfds = 3;
    }
    var ctx = ProviderCtx{ .p = p, .out = out, .seen = &seen, .seen_tp = &seen_tp, .seen_lcn = &seen_lcn, .fd_sdt = fd_sdt, .fd_nit = fd_nit, .fd_bat = fd_bat };

    // SI tables repeat cyclically. Past the nominal scan time we keep going while
    // the mux is still telling us something new: a fixed multiple of the scan
    // time cuts slow, large tables (Sky's BAT cycles far slower than a typical
    // window) yet makes every fast platform wait for nothing. Progress, not the
    // clock, decides; a BAT is also tracked to section completeness.
    const stall_ms: i64 = 15000; // no new service/LCN/section for this long = done
    const abs_cap_ms: i64 = @as(i64, cli.scan_secs) * 12000; // safety net
    const t0 = dvb.nowMs();
    var last_progress = t0;
    var prog_sig: usize = 0;
    while (true) {
        const now = dvb.nowMs();
        const sig = ctx.progress();
        if (sig != prog_sig) {
            prog_sig = sig;
            last_progress = now;
        }
        if (now - t0 >= @as(i64, cli.scan_secs) * 1000) {
            const bat_done = fd_bat < 0 or ctx.bat.complete();
            if (bat_done or now - last_progress >= stall_ms or now - t0 >= abs_cap_ms) break;
        }
        // pump in 1 s slices so the progress/stall logic above gets to run
        if (!dvb.pumpSections(fds_buf[0..nfds], now + 1000, &ctx, ProviderCtx.onSection)) break;
    }

    if (fd_bat >= 0 and !ctx.bat.complete()) {
        std.debug.print("[satscan] warning: BAT incomplete (some sections never arrived)\n", .{});
    }
    dvb.demuxStop(fd_sdt);
    dvb.demuxStop(fd_nit);
    if (fd_bat >= 0) dvb.demuxStop(fd_bat);
    std.debug.print("[satscan] services={d} transponders={d} lcn={d}\n", .{ seen.count(), seen_tp.count(), seen_lcn.count() });
}

// ---------- main ----------

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.page_allocator;
    const cli = parseCli(init) catch |e| switch (e) {
        error.Help => return,
        else => return e,
    };

    var out = dvb.Out{};
    defer out.flush();

    // Provider (or a placeholder for scan-all) and the candidate entry transponders.
    var cands_buf: [9]dvb.Tp = undefined;
    var ncand: usize = 0;
    var queue = si.TpQueue{};
    const p: Provider = if (cli.scan_all) blk: {
        if (!si.parseSatellitesXml(alloc, cli.satxml_path, cli.sat_pos, &queue)) {
            // enigma often symlinks this into /etc/enigma2 as well
            if (!si.parseSatellitesXml(alloc, "/etc/enigma2/satellites.xml", cli.sat_pos, &queue)) {
                std.debug.print("[satscan] no transponders for pos={d} in {s}\n", .{ cli.sat_pos, cli.satxml_path });
                return error.NoTransponders;
            }
        }
        std.debug.print("[satscan] satellites.xml: {d} transponders for pos={d}\n", .{ queue.len, cli.sat_pos });
        // probe the tuner with the first few transponders: a single weak one
        // must not disqualify a working frontend
        while (ncand < 4 and ncand < queue.len) : (ncand += 1) cands_buf[ncand] = queue.items[ncand].tp;
        break :blk Provider{ .key = "scan", .name = "scan-all", .home = queue.items[0].tp, .onid = 0, .tsid = 0, .pos = cli.sat_pos };
    } else blk: {
        const key = cli.provider_key.?;
        const found = providers.find(key) orelse {
            var kb: [512]u8 = undefined;
            std.debug.print("[satscan] unknown provider '{s}' ({s})\n", .{ key, providers.listKeys(&kb) });
            return error.BadProvider;
        };
        cands_buf[0] = found.home;
        ncand = 1;
        for (found.alts) |alt| {
            if (ncand >= cands_buf.len) break;
            cands_buf[ncand] = alt;
            ncand += 1;
        }
        break :blk found;
    };
    const cands = cands_buf[0..ncand];
    const target_pos: u32 = p.pos;

    // Tuner configuration from enigma settings (unicable, dish/DiSEqC layout).
    var nims = [_]settings.NimCfg{.{}} ** settings.MAX_NIMS;
    const have_settings = settings.parse(alloc, cli.settings_path, &nims);
    if (!have_settings) std.debug.print("[satscan] no {s} - trying every tuner with a plain LNB\n", .{cli.settings_path});

    if (cli.dry_run) { // diagnostics only: report what the dish setup implies, touch nothing
        printDryRun(&nims, target_pos, p, &out);
        return;
    }

    var dmxbuf: [64]u8 = undefined;
    const dmx_path = try std.fmt.bufPrintZ(&dmxbuf, "/dev/dvb/adapter{d}/demux{d}", .{ cli.adapter, cli.demux });

    const t = try selectTuner(cli, &nims, have_settings, target_pos, cands, dmx_path);
    defer dvb.close(t.fd);
    std.debug.print("[satscan] tuner: frontend{d}\n", .{t.index});

    if (cli.scan_all) {
        out.line("# scan-all pos={d} tps={d} frontend={d}\n", .{ cli.sat_pos, queue.len, t.index });
        try scanAll(t, cli, dmx_path, &queue, cli.sat_pos, &out, alloc);
    } else {
        try scanProvider(t, p, cli, dmx_path, &out, alloc);
    }
}
