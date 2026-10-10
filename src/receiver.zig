// Scanning through the receiver software. On an FBC tuner only the root
// frontend can send DiSEqC/Unicable commands; while the receiver (enigma2)
// holds that root for live TV, satscan cannot steer the dish at all. What it
// can do is ask the receiver to tune for it: a stream request on the
// streaming port makes enigma allocate a free frontend, send the commands
// through its root and keep the transponder up for as long as the client
// stays connected. satscan then finds that frontend by the TSID in its PAT
// and reads the SI tables off a demux routed to it. Live TV is untouched.
//
// Needs a service reference on the target transponder: taken from the
// receiver's lamedb (any service of the transponder will do).
const std = @import("std");
const linux = std.os.linux;
const dvb = @import("dvb.zig");
const settings = @import("settings.zig");

pub const DEFAULT_LAMEDB = "/etc/enigma2/lamedb";
pub const DEFAULT_PORT: u16 = 8001;

/// A transponder of the lamedb with one of its services.
pub const Entry = struct {
    ns: u32,
    tsid: u16,
    onid: u16,
    freq: u32, // kHz
    pol_h: bool,
    sid: u16 = 0,
    typ: u32 = 1,
};

pub const Lamedb = struct {
    entries: []Entry,

    pub fn deinit(self: Lamedb, alloc: std.mem.Allocator) void {
        alloc.free(self.entries);
    }

    /// The entry for `tp` (2 MHz window, same polarisation) that has a service.
    pub fn find(self: Lamedb, tp: dvb.Tp) ?Entry {
        for (self.entries) |e| {
            if (e.sid == 0 or e.pol_h != tp.pol_h) continue;
            const diff = if (e.freq > tp.freq) e.freq - tp.freq else tp.freq - e.freq;
            if (diff <= 2000) return e;
        }
        return null;
    }
};

fn hexField(it: *std.mem.SplitIterator(u8, .scalar), comptime T: type) ?T {
    const s = it.next() orelse return null;
    return std.fmt.parseInt(T, s, 16) catch null;
}

fn decField(it: *std.mem.SplitIterator(u8, .scalar), comptime T: type) ?T {
    const s = it.next() orelse return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// Parse lamedb v4: "transponders" (key line `ns:tsid:onid`, then a
/// `\ts freq:sr:pol:...` line) and "services" (`sid:ns:tsid:onid:type:...`,
/// name, provider). Only the first service of each transponder is kept.
pub fn load(alloc: std.mem.Allocator, path: [*:0]const u8) ?Lamedb {
    const file = dvb.readFile(alloc, path, 8 << 20) orelse return null;
    defer file.deinit(alloc);
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(alloc);

    var in_services = false;
    var pending: ?Entry = null;
    var lines = std.mem.splitScalar(u8, file.data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.eql(u8, line, "services")) {
            in_services = true;
            continue;
        }
        if (line.len == 0 or std.mem.eql(u8, line, "end")) continue;
        if (!in_services) {
            if (line[0] == '\t') {
                const p = pending orelse continue;
                if (line.len < 3 or line[1] != 's') continue;
                var it = std.mem.splitScalar(u8, line[3..], ':');
                const freq = decField(&it, u32) orelse continue;
                _ = decField(&it, u32) orelse continue; // symbol rate
                const pol = decField(&it, u8) orelse continue;
                entries.append(alloc, .{ .ns = p.ns, .tsid = p.tsid, .onid = p.onid, .freq = freq, .pol_h = (pol & 1) == 0 }) catch return null;
                pending = null;
            } else {
                var it = std.mem.splitScalar(u8, line, ':');
                const ns = hexField(&it, u32) orelse continue;
                const tsid = hexField(&it, u16) orelse continue;
                const onid = hexField(&it, u16) orelse continue;
                pending = .{ .ns = ns, .tsid = tsid, .onid = onid, .freq = 0, .pol_h = false };
            }
        } else if (line[0] != '\t' and std.mem.count(u8, line, ":") >= 5) {
            var it = std.mem.splitScalar(u8, line, ':');
            const sid = hexField(&it, u16) orelse continue;
            const ns = hexField(&it, u32) orelse continue;
            const tsid = hexField(&it, u16) orelse continue;
            const onid = hexField(&it, u16) orelse continue;
            const typ = decField(&it, u32) orelse continue;
            for (entries.items) |*e| {
                if (e.sid == 0 and e.ns == ns and e.tsid == tsid and e.onid == onid) {
                    e.sid = sid;
                    e.typ = typ;
                    break;
                }
            }
        }
    }
    return .{ .entries = entries.toOwnedSlice(alloc) catch return null };
}

/// An open stream request: the receiver keeps `frontend` on our transponder
/// until `sock` is closed.
pub const Stream = struct {
    sock: i32,
    frontend: u32,
    tsid: u16,

    pub fn close(self: Stream) void {
        dvb.close(self.sock);
    }
};

pub const Error = error{ NoService, Connect, NotTuned };

/// Ask the receiver for `tp` and find the frontend it tuned (by PAT TSID).
pub fn open(db: Lamedb, tp: dvb.Tp, port: u16, adapter: u32, dmx_path: [*:0]const u8, secs: u32) Error!Stream {
    const e = db.find(tp) orelse return error.NoService;
    const sock = dvb.tcpConnectLocal(port) orelse return error.Connect;
    errdefer dvb.close(sock);
    var req: [160]u8 = undefined;
    const text = std.mem.print(&req, "GET /1:0:{X}:{X}:{X}:{X}:{X}:0:0:0: HTTP/1.0\r\n\r\n", .{ e.typ, e.sid, e.tsid, e.onid, e.ns }) catch return error.Connect;
    if (!dvb.writeAll(sock, text)) return error.Connect;

    var pathbuf: [64]u8 = undefined;
    const deadline = dvb.nowMs() + @as(i64, secs) * 1000;
    while (dvb.nowMs() < deadline) {
        dvb.drain(sock);
        var f: u32 = 0;
        while (f < settings.MAX_NIMS) : (f += 1) {
            const path = std.mem.printSentinel(&pathbuf, "/dev/dvb/adapter{d}/frontend{d}", .{ adapter, f }, 0) catch break;
            if (linux.access(path, 0) != 0) break;
            if (!dvb.openElsewhere(path) or !dvb.lockedReadOnly(path)) continue;
            if (dvb.patTsid(dmx_path, f, 700)) |tsid| {
                if (tsid == e.tsid) return .{ .sock = sock, .frontend = f, .tsid = tsid };
            }
        }
        dvb.sleepMs(300);
    }
    return error.NotTuned;
}
