// Linux DVB API v5 surface used by satscan: frontend tuning (DiSEqC committed,
// uncommitted 1.1, Unicable EN50494, universal LNB), demux section filters and
// the raw-syscall I/O helpers everything else is built on. No libc.

const std = @import("std");
const linux = std.os.linux;

// ---------- ioctl (arch-aware: mips/ppc encode dir/size differently) ----------
const IOCTL = linux.IOCTL;

// ---------- frontend constants ----------
pub const FE_HAS_LOCK: u32 = 0x10;

pub const SEC_VOLTAGE_13: u32 = 0; // vertical (V)
pub const SEC_VOLTAGE_18: u32 = 1; // horizontal (H)
pub const SEC_TONE_ON: u32 = 0;
pub const SEC_TONE_OFF: u32 = 1;

// fe_delivery_system
pub const SYS_DVBS: u32 = 5;
pub const SYS_DVBS2: u32 = 6;
// fe_modulation
pub const QPSK: u32 = 0;
pub const PSK_8: u32 = 9;
// fe_code_rate
pub const FEC_2_3: u32 = 2;
pub const FEC_3_4: u32 = 3;
pub const FEC_5_6: u32 = 5;
pub const FEC_AUTO: u32 = 9;
// fe_spectral_inversion / fe_rolloff / fe_pilot
const INVERSION_AUTO: u32 = 2;
const ROLLOFF_AUTO: u32 = 3;
const PILOT_AUTO: u32 = 2;

// DTV property commands
const DTV_TUNE: u32 = 1;
const DTV_CLEAR: u32 = 2;
const DTV_FREQUENCY: u32 = 3;
const DTV_MODULATION: u32 = 4;
const DTV_INVERSION: u32 = 6;
const DTV_SYMBOL_RATE: u32 = 8;
const DTV_INNER_FEC: u32 = 9;
const DTV_PILOT: u32 = 12;
const DTV_ROLLOFF: u32 = 13;
const DTV_DELIVERY_SYSTEM: u32 = 17;

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

// ---------- demux ----------
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
pub const DMX_STOP = IOCTL.IO('o', 42);
// STB extension (all enigma boxes): route demux input to a given frontend.
const DMX_SET_SOURCE = IOCTL.IOW('o', 49, u32);

// ---------- raw-syscall I/O ----------
pub fn sysOpen(path: [*:0]const u8, nonblock: bool) ?i32 {
    var flags = linux.O{ .ACCMODE = .RDWR };
    flags.NONBLOCK = nonblock;
    const rc = linux.open(path, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn close(fd: i32) void {
    _ = linux.close(fd);
}

/// A whole file read into memory (capped at `max`). `data` is the part actually
/// read; `buf` is the full allocation to hand back to the allocator.
pub const FileData = struct {
    buf: []u8,
    data: []u8,
    pub fn deinit(self: FileData, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

/// Read a whole file (capped at `max`). Null when it cannot be opened.
pub fn readFile(alloc: std.mem.Allocator, path: [*:0]const u8, max: usize) ?FileData {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const buf = alloc.alloc(u8, max) catch return null;
    var total: usize = 0;
    while (total < buf.len) {
        const n = linux.read(fd, buf.ptr + total, buf.len - total);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        total += n;
    }
    return .{ .buf = buf, .data = buf[0..total] };
}

pub fn nowMs() i64 {
    // gettimeofday: ancient syscall, works on every kernel these boxes run
    // (clock_gettime via zig can hit vdso/time64 paths that old kernels lack).
    var tv: linux.timeval = .{ .sec = 0, .usec = 0 };
    _ = linux.gettimeofday(&tv, null);
    return @as(i64, tv.sec) * 1000 + @divTrunc(@as(i64, tv.usec), 1000);
}

pub fn sleepMs(ms: u32) void {
    var ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @as(isize, @intCast(ms % 1000)) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

fn ioctlChecked(fd: i32, request: u32, arg: usize, what: []const u8) !void {
    const rc = linux.ioctl(fd, request, arg);
    if (linux.errno(rc) != .SUCCESS) {
        std.debug.print("[satscan] ioctl {s} failed: {t}\n", .{ what, linux.errno(rc) });
        return error.Ioctl;
    }
}

// ---------- buffered stdout ----------
// Data lines go to stdout, diagnostics to stderr. Output is buffered: a scan
// emits well over a thousand lines and one write() per line is measurable on
// the MIPS boxes.
pub const Out = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    line_buf: [512]u8 = undefined,

    pub fn line(self: *Out, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.line_buf, fmt, args) catch return;
        if (self.len + s.len > self.buf.len) self.flush();
        @memcpy(self.buf[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    pub fn flush(self: *Out) void {
        var off: usize = 0;
        while (off < self.len) {
            const n = linux.write(1, self.buf[off..].ptr, self.len - off);
            if (linux.errno(n) != .SUCCESS) break;
            off += n;
        }
        self.len = 0;
    }
};

// ---------- tuning ----------
pub const Lnb = struct { lo: u32 = 9750000, hi: u32 = 10600000, sw: u32 = 11700000 };
pub const Scr = struct { slot: u8, freq_mhz: u32 }; // Unicable EN50494 user band

/// The one set of parameters a tuner needs. Providers, spare entry transponders
/// and satellites.xml entries all reduce to this.
pub const Tp = struct {
    freq: u32, // kHz
    sr: u32, // symbols/s
    pol_h: bool, // true = H (18 V), false = V (13 V)
    fec: u32,
    sys: u32,
    mod: u32,
};

/// Everything that selects the signal path in front of the demod.
pub const Switch = struct {
    scr: ?Scr = null,
    committed: ?u8 = null, // DiSEqC committed port 0..3
    uncommitted: ?u8 = null, // DiSEqC 1.1 port 1..16
};

fn diseqc(fd: i32, msg: [6]u8, len: u8, what: []const u8) !void {
    var cmd = dvb_diseqc_master_cmd{ .msg = msg, .msg_len = len };
    try ioctlChecked(fd, FE_DISEQC_SEND_MASTER_CMD, @intFromPtr(&cmd), what);
}

pub fn tune(fd: i32, tp: Tp, lnb: Lnb, sw: Switch) !void {
    const high = tp.freq >= lnb.sw;
    var ifreq: u32 = if (high) tp.freq - lnb.hi else tp.freq - lnb.lo;

    if (sw.scr) |u| {
        // Unicable EN50494: SCR command sent at 18V, reception on the slot IF
        const tp_if_mhz = ifreq / 1000;
        const t: u32 = (tp_if_mhz + u.freq_mhz + 2) / 4 - 350;
        // bit 4 selects the satellite position bank (committed port 0/1)
        const bank: u8 = if (sw.committed) |pt| (pt & 1) else 0;
        const msg = [6]u8{
            0xE0,                                                                                                                                                           0x10,               0x5A,
            (@as(u8, u.slot & 0x07) << 5) | (bank << 4) | (@as(u8, @intFromBool(tp.pol_h)) << 3) | (@as(u8, @intFromBool(high)) << 2) | @as(u8, @intCast((t >> 8) & 0x03)), @intCast(t & 0xff), 0,
        };
        try ioctlChecked(fd, FE_SET_TONE, SEC_TONE_OFF, "FE_SET_TONE");
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_13, "FE_SET_VOLTAGE");
        sleepMs(15);
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_18, "FE_SET_VOLTAGE(18)");
        sleepMs(10);
        try diseqc(fd, msg, 5, "FE_DISEQC_SEND_MASTER_CMD(scr)");
        sleepMs(10);
        try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_13, "FE_SET_VOLTAGE(13)");
        ifreq = u.freq_mhz * 1000; // receive on the user-band IF
    } else {
        const voltage: u32 = if (tp.pol_h) SEC_VOLTAGE_18 else SEC_VOLTAGE_13;
        const tone: u32 = if (high) SEC_TONE_ON else SEC_TONE_OFF;
        if (sw.committed != null or sw.uncommitted != null) {
            // A committed and/or DiSEqC 1.1 uncommitted switch: tone off, 18V for
            // a reliable command, then send (order: committed, uncommitted, tone
            // burst - the "cut" order enigma uses for cascaded switches).
            try ioctlChecked(fd, FE_SET_TONE, SEC_TONE_OFF, "FE_SET_TONE");
            try ioctlChecked(fd, FE_SET_VOLTAGE, SEC_VOLTAGE_18, "FE_SET_VOLTAGE(18)");
            sleepMs(15);
            if (sw.committed) |port| {
                // committed (2/4-way, monoblocks): E0 10 38 <F0|port<<2|pol<<1|band>
                const msg = [6]u8{ 0xE0, 0x10, 0x38, 0xF0 | (@as(u8, port & 0x03) << 2) | (@as(u8, @intFromBool(tp.pol_h)) << 1) | @as(u8, @intFromBool(high)), 0, 0 };
                try diseqc(fd, msg, 4, "FE_DISEQC_SEND_MASTER_CMD");
                sleepMs(54); // spec: >=15ms, switches like a bit more
            }
            if (sw.uncommitted) |up| {
                // DiSEqC 1.1 uncommitted switch (up to 16 ports): E0 10 39
                // <F0|(port-1)>. Ports are numbered 1..16 in settings.
                const idx: u8 = if (up > 0) up - 1 else 0;
                const msg = [6]u8{ 0xE0, 0x10, 0x39, 0xF0 | (idx & 0x0F), 0, 0 };
                try diseqc(fd, msg, 4, "FE_DISEQC_SEND_MASTER_CMD(uncommitted)");
                sleepMs(54);
            }
            // Many 2-way switches (and enigma's a/b mode) only react to the
            // mini-DiSEqC tone burst, so send it as well when a committed port is
            // in play: A for even ports, B for odd ones.
            if (sw.committed) |port| {
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
        .{ .cmd = DTV_DELIVERY_SYSTEM, .data = tp.sys },
        .{ .cmd = DTV_FREQUENCY, .data = ifreq }, // kHz IF
        .{ .cmd = DTV_MODULATION, .data = tp.mod },
        .{ .cmd = DTV_SYMBOL_RATE, .data = tp.sr },
        .{ .cmd = DTV_INNER_FEC, .data = tp.fec },
        .{ .cmd = DTV_INVERSION, .data = INVERSION_AUTO },
        .{ .cmd = DTV_ROLLOFF, .data = ROLLOFF_AUTO },
        .{ .cmd = DTV_PILOT, .data = PILOT_AUTO },
        .{ .cmd = DTV_TUNE },
    };
    var cmdseq = dtv_properties{ .num = props.len, .props = &props };
    try ioctlChecked(fd, FE_SET_PROPERTY, @intFromPtr(&cmdseq), "FE_SET_PROPERTY");
}

pub fn hasLock(fd: i32) bool {
    var status: u32 = 0;
    _ = linux.ioctl(fd, FE_READ_STATUS, @intFromPtr(&status));
    return status & FE_HAS_LOCK != 0;
}

/// Wait for LOCK. Right after a retune the demod can still report the previous
/// transponder's lock for a moment, so a scan that hops transponders would
/// "lock" instantly on the stale flag and read the old mux again; a short settle
/// before polling avoids that.
pub fn waitLock(fd: i32, secs: u32) bool {
    sleepMs(150);
    var i: u32 = 0;
    const iters = secs * 10;
    while (i < iters) : (i += 1) {
        if (hasLock(fd)) return true;
        sleepMs(100);
    }
    return false;
}

// ---------- demux ----------
pub fn demuxOpenFor(dmx_path: [*:0]const u8, frontend: u32) ?i32 {
    const fd = sysOpen(dmx_path, true) orelse return null;
    // Only reroute when we are not on the demux's default input (frontend0):
    // some STB drivers disturb already-armed filters when re-sourced.
    if (frontend > 0) _ = linux.ioctl(fd, DMX_SET_SOURCE, @intFromPtr(&frontend));
    return fd;
}

pub fn setSectionFilter(fd: i32, pid: u16, table_id: u8, table_mask: u8, ext_id: ?u16) !void {
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

pub fn demuxStop(fd: i32) void {
    _ = linux.ioctl(fd, DMX_STOP, 0);
}

/// Poll a set of section-filter fds and hand every complete section to `on_sec`
/// until `deadline_ms` (absolute, from nowMs). Each ready fd is drained to
/// EAGAIN, but bounded: old drivers can return 0 on buffer overflow (busy-loop
/// bait), and the caller's loop must keep checking its own clock. Returns false
/// on a poll error.
pub fn pumpSections(fds: []linux.pollfd, deadline_ms: i64, ctx: anytype, comptime on_sec: fn (@TypeOf(ctx), i32, []const u8) void) bool {
    var secbuf: [4200]u8 = undefined;
    while (nowMs() < deadline_ms) {
        const nr = linux.poll(fds.ptr, @intCast(fds.len), 300);
        if (linux.errno(nr) != .SUCCESS) return false;
        if (nr == 0) continue;
        for (fds) |*pf| {
            if (pf.revents & linux.POLL.IN == 0) continue;
            var drained: u32 = 0;
            while (drained < 256) : (drained += 1) {
                const n = linux.read(pf.fd, &secbuf, secbuf.len);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                if (n < 12) continue;
                on_sec(ctx, pf.fd, secbuf[0..n]);
            }
        }
    }
    return true;
}

/// A demod can raise FE_HAS_LOCK with no transport stream behind it - seen on FBC
/// tuners whose input carries no signal, where every frequency "locks" and the
/// scan then silently yields nothing. Every real DVB stream carries a PAT, so
/// "lock but not one PAT section" is treated as no lock.
pub fn streamAlive(dmx_path: [*:0]const u8, frontend: u32, ms: i64) bool {
    const dfd = demuxOpenFor(dmx_path, frontend) orelse return false;
    defer close(dfd);
    setSectionFilter(dfd, 0x00, 0x00, 0xff, null) catch return false;
    var fds = [_]linux.pollfd{.{ .fd = dfd, .events = linux.POLL.IN, .revents = 0 }};
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
