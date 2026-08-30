# satscan

Samodzielna binarka bez zależności, która skanuje ramówki **Polsat Box**
i **Platformy Canal+** wprost z tunera DVB-S2 (Hot Bird 13.0E) i wypisuje je
jako zwykły tekst — nazwy usług, transpondery i numerację operatora (LCN).
Napisana od zera w **Zig 0.16**, wyłącznie surowe syscalle Linuksa
(bez libc, statyczne binarki musl ~150–230 KB).

*English documentation: [README.md](README.md)*

## Użycie

```sh
satscan --provider canalplus|polsat [opcje] > lista.txt
```

Zwykle to wszystko — narzędzie konfiguruje się samo:

- czyta `/etc/enigma2/settings`, pomija NIM-y nieskonfigurowane na 13.0E,
  rozpoznaje **Unicable/SCR (EN50494)** oraz zwykły uniwersalny LNB
  (napięcie + ton 22 kHz, bez DiSEqC),
- próbuje kolejnych frontendów, aż któryś się otworzy (zajęte tunery zwracają
  `EBUSY` i są pomijane) **i** złapie LOCK,
- skanuje aż tablica bukietu będzie **kompletna** (śledzenie sekcji BAT),
  a nie tylko przez sztywny czas.

Opcje:

| opcja | znaczenie |
|---|---|
| `--provider canalplus\|polsat` | którą platformę skanować (wymagane) |
| `--adapter N` / `--frontend N` / `--demux N` | przypięcie konkretnych urządzeń (domyślnie: auto) |
| `--settings ŚCIEŻKA` | ustawienia enigmy (domyślnie `/etc/enigma2/settings`) |
| `--scr-slot N --scr-freq MHz` | wymuszenie Unicable EN50494 (nadpisuje settings) |
| `--lnb-lo/hi/sw kHz` | parametry uniwersalnego LNB (domyślnie 9750/10600/11700 MHz) |
| `--secs S` | czekanie na LOCK per tuner (domyślnie 8) |
| `--scan-secs S` | bazowy czas skanu (domyślnie 25; wydłuża się do 4× aż BAT będzie kompletny) |

## Format wyjścia

Jedna linia na rekord na stdout, diagnostyka na stderr:

```
# provider=Polsat Box freq=12188000 pol=V lock=1 frontend=0
T 1CE8:0071 freq=12188000 pol=V sr=27500000 fec=3 sys=S2 pos=130E mod=2
S 3391:3390:0071 type=1 "Polsat HD" "Cyfrowy Polsat S.A."
L 1 3391:3390:0071 visible=1 src=nit
```

- `T` — transponder z NIT (`tsid:onid`, częstotliwość kHz, polaryzacja,
  symbol rate, kod FEC DVB, S/S2, pozycja orbitalna, modulacja),
- `S` — usługa z SDT actual+other (`sid:tsid:onid`, typ usługi DVB, nazwa,
  provider),
- `L` — numer logiczny kanału (`src=nit` — Polsat, deskryptor 0x82;
  `src=bat` — Canal+, deskryptor 0x83 w bukiecie 0x2020, z flagą
  visible-service).

## Jak czyta dane

Stroi się na transponder domowy platformy (Canal+: 10719 V, Polsat: 12188 V)
i czyta tablice DVB SI z demuxa trzema równoległymi filtrami sekcji:
SDT actual+other jedną maską (0x42/0xFB), NIT actual oraz BAT filtrowany po
bouquet id. Filtr BAT jest dodatkowo weryfikowany programowo — niektóre
sterowniki demuxa (widziane na czesci dekoderow) ignorują część extension filtra
sprzętowego. Układ deskryptorów LCN i delivery jest ten sam, który parsuje
wtyczka SatScanLcn dla Enigma2; satscan to niezależna implementacja od zera.

## Budowanie

```sh
zig build      # daje zig-out/bin/satscan-armhf i satscan-mipsel
```

Dwa przenośne warianty — dobrane po bolesnych testach:

- **satscan-armhf** — ARMv7 + VFPv3-D16, **NEON jawnie wyłączony**: część
  SoC-ów STB (czesc ARM-owych STB) nie ma NEON i domyślny baseline daje SIGILL;
  build bez NEON działa na każdym testowanym ARM-ie, także tych z NEON-em.
- **satscan-mipsel** — MIPS32 **r1**: starsze Broadcomy MIPS (np. BCM7362
  ) dają SIGILL na instrukcjach r2. Dodatkowo MIPS inaczej
  koduje numery `ioctl` — kod używa arch-aware `std.os.linux.IOCTL`.

CI buduje oba warianty przy każdym pushu, a na tagach `satscan-v*` publikuje
GitHub Release z sumami kontrolnymi.

## Przetestowane na

| dekoder | arch | instalacja |
|---|---|---|
| 2×DVB-S2X box | armv7l | uniwersalny LNB, bez DiSEqC |
| FBC box (8×) | armv7l | Unicable EN50494 (Sharp, auto z settings) |
| ARM box (bez NEON) | armv7l | uniwersalny LNB |
| MIPS box | mipsel r1 | uniwersalny LNB |

Pełne zgrania z wszystkich czterech dekoderów są **bitowo identyczne**
(Canal+: 38 T / 644 S / 629 L; Polsat: 42 T / 333 S / 298 L).
