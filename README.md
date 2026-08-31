# satscan

Standalone, dependency-free binary that scans channel line-ups of the Hot Bird
13.0E platforms straight off a DVB-S/S2 tuner and prints them as plain text —
service names, transponders and the operator's logical channel numbers (LCN).
Written from scratch in **Zig 0.16**, raw Linux syscalls only (no libc, static
musl binaries ~150–230 KB).

Supported providers (`--provider`):

| key | platform | LCN source |
|---|---|---|
| `canalplus` | Platforma Canal+ (PL) | BAT 0x2020, descriptor 0x83 |
| `polsat` | Polsat Box (PL) | NIT, descriptor 0x82 |
| `skyitalia` | Sky Italia | BAT 0x6250, Sky private 0xB1 (with regions) |
| `tivusat` | Tivùsat (IT) | NIT actual+other, descriptor 0x83 |
| `nova` | Nova (GR) | BAT 0x0001, descriptor 0x93 |
| `vivacom` | Vivacom (BG) | BAT 0x6158, descriptor 0xE2 |

*Dokumentacja po polsku: [README.pl.md](README.pl.md)*

## Usage

```sh
satscan --provider <key> [options] > list.txt      # one platform with LCN
satscan --scan-all [options] > full.txt            # whole satellite from satellites.xml
```

`--scan-all` walks every transponder of the configured orbital position from
`/etc/tuxbox/satellites.xml` (`--pos`, default 130 = 13.0E), extends the queue
live with transponders discovered in NIT, and captures SDT actual on each
(~7 min for all of 13.0E). Extra options: `--tp-secs` (per-TP capture window,
default 4), `--max-tp N` (limit, for quick tests), `--satxml PATH`.

That is usually all — the tool configures itself:

- reads `/etc/enigma2/settings`, skips NIMs not configured for 13.0E,
  recognises **Unicable/SCR (EN50494)** and plain universal LNB setups
  (voltage + 22 kHz tone, no DiSEqC),
- tries successive frontends until one both opens (busy tuners return
  `EBUSY` and are skipped) and achieves **LOCK**,
- keeps scanning until the bouquet table is **complete**
  (BAT section tracking), not just for a fixed time.

Options:

| option | meaning |
|---|---|
| `--provider canalplus\|polsat` | which platform to scan (required) |
| `--adapter N` / `--frontend N` / `--demux N` | pin specific devices (default: auto) |
| `--settings PATH` | enigma settings path (default `/etc/enigma2/settings`) |
| `--scr-slot N --scr-freq MHz` | force Unicable EN50494 (overrides settings) |
| `--lnb-lo/hi/sw kHz` | universal LNB parameters (defaults 9750/10600/11700 MHz) |
| `--secs S` | LOCK wait per tuner (default 8) |
| `--scan-secs S` | base scan time (default 25; extends up to 4× until BAT completes) |

## Output format

One line per record on stdout, diagnostics on stderr:

```
# provider=Polsat Box freq=12188000 pol=V lock=1 frontend=0
T 1CE8:0071 freq=12188000 pol=V sr=27500000 fec=3 sys=S2 pos=130E mod=2
S 3391:3390:0071 type=1 ca=1 "Polsat HD" "Cyfrowy Polsat S.A."
L 1 3391:3390:0071 visible=1 src=nit
```

- `T` — transponder from NIT (`tsid:onid`, frequency kHz, polarisation, symbol
  rate, DVB FEC code, S/S2, orbital position, modulation),
- `S` — service from SDT (`sid:tsid:onid`, DVB service type, `ca` free/scrambled
  flag, name, provider),
- `L` — logical channel number (`src=nit` — Polsat, descriptor 0x82;
  `src=bat` — Canal+, descriptor 0x83 in bouquet 0x2020, with the
  visible-service flag).

## How it reads the data

Tunes to the platform's home transponder (Canal+: 10719 V, Polsat: 12188 V)
and reads DVB SI tables from the demux with three parallel section filters:
SDT actual+other in one mask (0x42/0xFB), NIT actual, and BAT filtered by
bouquet id. The BAT filter is additionally verified in software — some demux
drivers (seen on some boxes) ignore the extension part of the hardware filter.

## Credits / inspiration

satscan was inspired by **[SatScanLcn](https://github.com/Huevos/SatScanLcn)**
by Huevos — an Enigma2 plugin covering 30+ European platforms. Its provider
database and descriptor parsing were the reference for the home-transponder
parameters and the LCN descriptor layouts (0x82 NIT / 0x83 BAT) used here.
satscan is an independent from-scratch implementation (Zig, raw syscalls,
no Enigma2 dependency), not a port of its code.

## Building

```sh
zig build      # produces zig-out/bin/satscan-armhf and satscan-mipsel
```

Two portable flavours, chosen the hard way:

- **satscan-armhf** — ARMv7 + VFPv3-D16, **NEON explicitly disabled**: some
  STB SoCs (some ARM STBs) lack NEON and the default baseline SIGILLs; the
  no-NEON build runs on every ARM box we tried, NEON-capable ones included.
- **satscan-mipsel** — MIPS32 **r1**: older Broadcom MIPS (e.g. BCM7362
  ) SIGILL on r2 instructions. Also note MIPS encodes `ioctl`
  numbers differently — the code uses arch-aware `std.os.linux.IOCTL`.

CI builds both flavours on every push and publishes GitHub Releases with
checksums on `satscan-v*` tags.

## License

GPL-2.0 — see [LICENSE](LICENSE). The provider parameters and descriptor
layouts were derived from [SatScanLcn](https://github.com/Huevos/SatScanLcn)
(GPLv2), so this project keeps the same licence.

## Tested on

| box | arch | dish setup |
|---|---|---|
| 2×DVB-S2X box | armv7l | universal LNB, no DiSEqC |
| FBC box (8×) | armv7l | Unicable EN50494 (Sharp, auto-configured from settings) |
| ARM box (no NEON) | armv7l | universal LNB |
| MIPS box | mipsel r1 | universal LNB |

Full captures from all four boxes are **bit-identical** (Canal+: 38 T / 644 S /
629 L; Polsat: 42 T / 333 S / 298 L).
