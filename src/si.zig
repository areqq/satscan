// DVB SI parsers: SDT (service names), NIT/BAT (transponders + logical channel
// numbers). Sections arrive CRC-checked from the demux, but a broadcaster's own
// SI bugs pass CRC just fine, so every length field is treated as hostile:
// the build runs ReleaseSmall (no runtime bounds checks), and an out-of-range
// slice here would be silent garbage, not a crash.

const std = @import("std");
const dvb = @import("dvb.zig");

pub const POLCHARS = "HVLR";
pub const Seen = std.AutoHashMap(u64, void);
pub const SeenSvc = std.AutoHashMap(u32, void);

/// Full identity of one channel-number entry. A struct key (not a packed u64)
/// so no field gets truncated: sid/tsid/onid/lcn are 16 bits each and the Sky
/// region adds another byte — that is more than 64 bits.
pub const LcnKey = struct { region: u8, sid: u16, tsid: u16, onid: u16, lcn: u16 };
pub const SeenLcn = std.AutoHashMap(LcnKey, void);

/// Transponder queue for the full-satellite scan: seeded from satellites.xml,
/// extended live with NIT discoveries.
pub const TpQueue = struct {
    items: [512]QTp = undefined,
    len: usize = 0,

    pub const QTp = struct { tp: dvb.Tp, pol: u8 };

    // dedupe by frequency window (2 MHz) + polarisation
    pub fn add(self: *TpQueue, tp: dvb.Tp, pol: u8) bool {
        for (self.items[0..self.len]) |have| {
            if (have.pol == pol and absDiff(have.tp.freq, tp.freq) < 2000) return false;
        }
        if (self.len >= self.items.len) return false;
        self.items[self.len] = .{ .tp = tp, .pol = pol };
        self.len += 1;
        return true;
    }
};

fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

/// enigma satellites.xml fec_inner and the DVB satellite_delivery descriptor
/// share the same code table; both map to Linux DVB API fe_code_rate here.
pub fn mapFec(x: u32) u32 {
    return switch (x) {
        1 => 1, // 1/2
        2 => dvb.FEC_2_3,
        3 => dvb.FEC_3_4,
        4 => dvb.FEC_5_6,
        5 => 7, // 7/8
        6 => 8, // 8/9
        7 => 10, // 3/5
        8 => 4, // 4/5
        9 => 11, // 9/10
        else => dvb.FEC_AUTO,
    };
}

pub fn u16be(b: []const u8, o: usize) u16 {
    return (@as(u16, b[o]) << 8) | b[o + 1];
}

fn bcd(b: []const u8) u32 {
    var v: u32 = 0;
    for (b) |c| v = v * 100 + (c >> 4) * 10 + (c & 0x0f);
    return v;
}

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

// ---------- SDT ----------

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

/// Parse one SDT section (actual 0x42 or other 0x46), emitting an `S` line per
/// service not seen before. `ids_out` receives the section's tsid/onid.
pub fn parseSdt(section: []const u8, ids_out: *[2]u16, out: *dvb.Out, seen: *SeenSvc) void {
    if (section.len < 12) return;
    if (section[0] != 0x42 and section[0] != 0x46) return;
    const tsid = u16be(section, 3);
    const onid = u16be(section, 8);
    ids_out.* = .{ tsid, onid };
    loop_fuse = 0;
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    // everything below stays inside `end`: the section body minus CRC, clamped to
    // what we actually received
    const end = @min(3 + section_len -| 4, section.len);
    var pos: usize = 11; // past SDT header, into the service loop
    while (pos + 5 <= end) {
        if (fuse("sdt-svc")) return;
        const sid = u16be(section, pos);
        const free_ca = (section[pos + 3] >> 4) & 1;
        const desc_loop_len = (@as(usize, section[pos + 3] & 0x0f) << 8) | section[pos + 4];
        var d = pos + 5;
        const dend = @min(d + desc_loop_len, end);
        var stype: u8 = 0;
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        var prov_buf: [64]u8 = undefined;
        var prov_len: usize = 0;
        while (d + 2 <= dend) {
            if (fuse("sdt-desc")) return;
            const tag = section[d];
            const dlen: usize = section[d + 1];
            const body_end = @min(d + 2 + dlen, dend);
            if (tag == 0x48 and d + 4 <= body_end) { // service_descriptor
                var q = d + 2;
                stype = section[q];
                q += 1;
                // provider name: length byte + bytes, both bounded by the descriptor
                const pl: usize = section[q];
                q += 1;
                const pend = @min(q + pl, body_end);
                prov_len = copyName(prov_buf[0..], section[q..pend]);
                q = pend;
                if (q < body_end) {
                    const nl: usize = section[q];
                    q += 1;
                    const nend = @min(q + nl, body_end);
                    name_len = copyName(name_buf[0..], section[q..nend]);
                }
            }
            d += 2 + dlen; // NOTE: '2 + dlen' in u8 would wrap (254 -> 0)
        }
        const key = (@as(u32, sid) << 16) | tsid;
        if (seen.get(key) == null) {
            seen.put(key, {}) catch {};
            out.line("S {X:0>4}:{X:0>4}:{X:0>4} type={d} ca={d} \"{s}\" \"{s}\"\n", .{ sid, tsid, onid, stype, free_ca, name_buf[0..name_len], prov_buf[0..prov_len] });
        }
        pos = dend;
    }
}

// ---------- NIT / BAT ----------

fn emitLcn(out: *dvb.Out, seen: *SeenLcn, src: []const u8, lcn: u16, sid: u16, tsid: u16, onid: u16, visible: u8, region: ?u8) void {
    const key = LcnKey{ .region = region orelse 0xff, .sid = sid, .tsid = tsid, .onid = onid, .lcn = lcn };
    if (seen.get(key) != null) return;
    seen.put(key, {}) catch {};
    if (region) |rg| {
        out.line("L {d} {X:0>4}:{X:0>4}:{X:0>4} visible={d} region={d} src={s}\n", .{ lcn, sid, tsid, onid, visible, rg, src });
    } else {
        out.line("L {d} {X:0>4}:{X:0>4}:{X:0>4} visible={d} src={s}\n", .{ lcn, sid, tsid, onid, visible, src });
    }
}

/// Where a platform keeps its channel numbers and how the entries look.
pub const LcnLayout = enum {
    none,
    /// 4-byte sid(2) + [visible(1b) reserved(5b) lcn(10b)] — descriptor 0x83
    /// (Canal+, M7, TNTSAT...). Entries are emitted as broadcast, lcn 0 included.
    sid_visible_lcn10,
    /// 4-byte sid(2) + lcn(10b), no visibility flag — 0xE2 (Vivacom)
    sid_lcn10,
    /// 4-byte sid(2) lcn(2) — 0x82 (Polsat), 0x93 (Nova)
    sid_lcn16,
    /// Sky private 0xB1: 2-byte header (region in byte 1), 9-byte entries
    sky_b1,
    /// 8-byte onid(2) tsid(2) sid(2) [visible(1b) .. lcn(10b) with low 4 bits
    /// reserved] — descriptor in the BAT's bouquet-descriptor loop (BIS TV)
    bouquet_loop_addressed,
};

/// Parse the 4- or 9-byte entry list of one LCN descriptor found in a TS loop.
fn parseLcnEntries(layout: LcnLayout, body: []const u8, tsid: u16, onid: u16, out: *dvb.Out, seen: *SeenLcn, src: []const u8) void {
    switch (layout) {
        .sid_visible_lcn10 => {
            var q: usize = 0;
            while (q + 4 <= body.len) : (q += 4) {
                const sid = u16be(body, q);
                const visible = (body[q + 2] >> 7) & 1;
                const lcn = (@as(u16, body[q + 2] & 0x03) << 8) | body[q + 3];
                emitLcn(out, seen, src, lcn, sid, tsid, onid, visible, null);
            }
        },
        .sid_lcn10 => {
            var q: usize = 0;
            while (q + 4 <= body.len) : (q += 4) {
                const sid = u16be(body, q);
                const lcn = (@as(u16, body[q + 2] & 0x03) << 8) | body[q + 3];
                if (lcn > 0) emitLcn(out, seen, src, lcn, sid, tsid, onid, 1, null);
            }
        },
        .sid_lcn16 => {
            var q: usize = 0;
            while (q + 4 <= body.len) : (q += 4) {
                const sid = u16be(body, q);
                const lcn = u16be(body, q + 2);
                if (lcn > 0) emitLcn(out, seen, src, lcn, sid, tsid, onid, 1, null);
            }
        },
        .sky_b1 => {
            if (body.len < 2) return;
            const region = body[1];
            var q: usize = 2;
            while (q + 9 <= body.len) : (q += 9) {
                const sid = u16be(body, q);
                const sky_id = u16be(body, q + 5);
                if (sky_id > 0 and sky_id != 0xffff) emitLcn(out, seen, src, sky_id, sid, tsid, onid, 1, region);
            }
        },
        .bouquet_loop_addressed => {
            var q: usize = 0;
            while (q + 8 <= body.len) : (q += 8) {
                const e_onid = u16be(body, q);
                const e_tsid = u16be(body, q + 2);
                const sid = u16be(body, q + 4);
                const visible = (body[q + 6] >> 7) & 1;
                const raw = (@as(u16, body[q + 6] & 0x03) << 8) | body[q + 7];
                const lcn = raw >> 4; // low 4 bits reserved, always set
                if (lcn > 0) emitLcn(out, seen, src, lcn, sid, e_tsid, e_onid, visible, null);
            }
        },
        .none => {},
    }
}

pub const NitLike = struct {
    table_id: u8,
    /// BAT: only this bouquet_id (some demuxes ignore the hardware ext-id filter)
    want_ext: ?u16 = null,
    lcn_desc: u8 = 0,
    lcn_layout: LcnLayout = .none,
    /// Look for the LCN descriptor in the bouquet/network descriptor loop too
    /// (BIS TV puts one there, fully addressed). Opt-in: 0x82/0x83 are private
    /// tags and a network may use them for something else in that loop.
    lcn_in_bouquet_loop: bool = false,
    src: []const u8, // "nit" | "bat" for the L line
};

/// NIT (0x40/0x41) and BAT (0x4A) share the TS-loop structure; they differ in
/// header semantics and where the LCN lives. Emits `T` lines for transponders
/// (satellite_delivery 0x43) and `L` lines for channel numbers. With `discover`
/// set, newly seen transponders on `want_pos` are queued for a deeper scan.
pub fn parseNitLike(section: []const u8, cfg: NitLike, out: *dvb.Out, seen_tp: *Seen, seen_lcn: *SeenLcn, discover: ?*TpQueue, want_pos: ?u32) void {
    if (section.len < 12) return;
    if (section[0] != cfg.table_id) return;
    if (cfg.want_ext) |e| {
        if (u16be(section, 3) != e) return;
    }
    const section_len = (@as(usize, section[1] & 0x0f) << 8) | section[2];
    const total = 3 + section_len;
    if (total > section.len) return;
    const end = total - 4; // excluding CRC
    loop_fuse = 0;
    const net_desc_len = (@as(usize, section[8] & 0x0f) << 8) | section[9];

    if (cfg.lcn_in_bouquet_loop and cfg.lcn_desc != 0 and net_desc_len > 0) {
        var bd: usize = 10;
        const bd_end = @min(10 + net_desc_len, end);
        while (bd + 2 <= bd_end) {
            if (fuse("nitlike-bouquet")) return;
            const btag = section[bd];
            const blen: usize = section[bd + 1];
            const bbody = section[bd + 2 .. @min(bd + 2 + blen, bd_end)];
            if (btag == cfg.lcn_desc) parseLcnEntries(.bouquet_loop_addressed, bbody, 0, 0, out, seen_lcn, cfg.src);
            bd += 2 + blen;
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
            if (fuse("nitlike-desc")) return;
            const tag = section[d];
            const l: usize = section[d + 1];
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
                        tsid,                        onid,    freq_10khz * 10,                  POLCHARS[pol], sr_100 * 100, fec,
                        if (sys == 1) "S2" else "S", pos_bcd, if (west_east == 1) "E" else "W", modl,
                    });
                }
                if (discover) |q| skip: {
                    // A network's NIT can announce transponders on several orbital
                    // positions (M7 spans 19.2E and 23.5E); tuning those on a dish
                    // pointed elsewhere just burns time, so keep only our target.
                    if (want_pos) |wp| {
                        const tp_pos: u32 = if (west_east == 1) pos_bcd else 3600 - pos_bcd;
                        if (tp_pos != wp) break :skip;
                    }
                    const added = q.add(.{
                        .freq = freq_10khz * 10,
                        .sr = sr_100 * 100,
                        .pol_h = pol == 0,
                        .fec = mapFec(fec),
                        .sys = if (sys == 1) dvb.SYS_DVBS2 else dvb.SYS_DVBS,
                        .mod = if (modl == 2) dvb.PSK_8 else dvb.QPSK,
                    }, pol);
                    if (added) std.debug.print("[satscan] NIT discovered new tp {d} {c}\n", .{ freq_10khz * 10, POLCHARS[pol] });
                }
            } else if (tag == cfg.lcn_desc and cfg.lcn_desc != 0) {
                parseLcnEntries(cfg.lcn_layout, body, tsid, onid, out, seen_lcn, cfg.src);
            }
            d += 2 + l; // NOTE: '2 + l' in u8 would wrap (254 -> 0)
        }
        pos = dend;
    }
}

// ---------- satellites.xml ----------

fn xmlAttr(line: []const u8, name: []const u8) ?u32 {
    var buf: [40]u8 = undefined;
    const pat = std.fmt.bufPrint(&buf, "{s}=\"", .{name}) catch return null;
    const i = std.mem.indexOf(u8, line, pat) orelse return null;
    const rest = line[i + pat.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return std.fmt.parseInt(u32, rest[0..j], 10) catch null;
}

/// Minimal satellites.xml reader: transponders of the <sat position="POS"> block.
pub fn parseSatellitesXml(alloc: std.mem.Allocator, path: [*:0]const u8, want_pos: u32, queue: *TpQueue) bool {
    const file = dvb.readFile(alloc, path, 2 * 1024 * 1024) orelse return false;
    defer file.deinit(alloc);
    var in_sat = false;
    var lines = std.mem.splitScalar(u8, file.data, '\n');
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
        const pol: u8 = @intCast((xmlAttr(line, "polarization") orelse 0) & 3);
        _ = queue.add(.{
            .freq = freq_khz,
            .sr = sr,
            .pol_h = pol == 0,
            .fec = mapFec(xmlAttr(line, "fec_inner") orelse 0),
            .sys = if ((xmlAttr(line, "system") orelse 0) == 1) dvb.SYS_DVBS2 else dvb.SYS_DVBS,
            .mod = if ((xmlAttr(line, "modulation") orelse 0) == 2) dvb.PSK_8 else dvb.QPSK,
        }, pol);
    }
    return queue.len > 0;
}
