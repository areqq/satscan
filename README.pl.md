# satscan

Samodzielna binarka bez zależności, która skanuje ramówki platform z Hot Birda
13.0E wprost z tunera DVB-S/S2 i wypisuje je jako zwykły tekst — nazwy usług,
transpondery i numerację operatora (LCN). Napisana od zera w **Zig 0.16**,
wyłącznie surowe syscalle Linuksa (bez libc, statyczne binarki musl ~150–230 KB).

Obsługiwani providerzy (`--provider`):

| klucz | platforma | źródło LCN |
|---|---|---|
| `canalplus` | Platforma Canal+ (PL) | BAT 0x2020, deskryptor 0x83 |
| `polsat` | Polsat Box (PL) | NIT, deskryptor 0x82 |
| `skyitalia` | Sky Italia | BAT 0x6250, prywatny Sky 0xB1 (z regionami) |
| `tivusat` | Tivùsat (IT) | NIT actual+other, deskryptor 0x83 |
| `nova` | Nova (GR) | BAT 0x0001, deskryptor 0x93 |
| `vivacom` | Vivacom (BG) | BAT 0x6158, deskryptor 0xE2 |

Astra 19.2E (`--pos 192`, wymaga anteny/portu DiSEqC na tę pozycję) —
**zweryfikowane na sygnale** (usługi + LCN, dwa kolejne przebiegi bit w bit takie same):

| klucz | platforma | źródło LCN |
|---|---|---|
| `tntsat` | TNTSAT (FR) | BAT 0xC00F, deskryptor 0x83 |
| `movistar` | Movistar+ (ES) | BAT 0x0021, deskryptor 0x83 |
| `simplitv` | simpliTV (AT) | BAT 0x3700, deskryptor 0x83 |
| `canaldigitaal` | Canal Digitaal (NL) | NIT pid 0x385, prywatna tablica 0xBC |
| `tvvlaanderen` | TV Vlaanderen (BE) | NIT pid 0x38F, prywatna tablica 0xBC |
| `telesat` | TeleSAT (BE) | NIT pid 0x399, prywatna tablica 0xBC |
| `austriasat` | Austriasat (AT) | NIT pid 0x3B6, prywatna tablica 0xBC |
| `diveo` | Diveo (DE) | NIT pid 0x3C0, prywatna tablica 0xBC |

Na sygnale pięć platform M7 zwraca te same 142 usługi, ale pięć różnych zestawów
LCN (657 / 661 / 644 / 356 / 218 wpisów) — to najczytelniejsze potwierdzenie, że
prywatny PID NIT każdej z nich jest czytany poprawnie.

Pięć platform M7 dzieli jeden transponder domowy (12515 H) i różni się wyłącznie
prywatnym PID-em NIT, na którym siedzi ich ramówka.

*English documentation: [README.md](README.md)*

## Użycie

```sh
satscan --provider <klucz> [opcje] > lista.txt     # jedna platforma z LCN
satscan --scan-all [opcje] > pelny.txt             # caly satelita z satellites.xml
```

`--scan-all` przechodzi wszystkie transpondery pozycji orbitalnej z
`/etc/tuxbox/satellites.xml` (`--pos`, domyślnie 130 = 13.0E), rozszerza kolejkę
na żywo o transpondery odkryte w NIT i zbiera SDT actual z każdego
(~7 min dla całego 13.0E). Dodatkowe opcje: `--tp-secs` (okno na TP, domyślnie 4),
`--max-tp N` (limit, do szybkich testów), `--satxml ŚCIEŻKA`.

Zwykle to wszystko — narzędzie konfiguruje się samo:

- czyta `/etc/enigma2/settings`, pomija NIM-y niesięgające docelowej pozycji
  orbitalnej, rozpoznaje **Unicable/SCR (EN50494)**, zwykły uniwersalny LNB
  (napięcie + ton 22 kHz) oraz **przełączniki committed DiSEqC** — port bierze
  z `diseqcA..D` (tryb prosty) albo `advanced.sat.<pos>.commitedDiseqcCommand`
  (zaawansowany), więc anteny wielosatelitarne działają bez dodatkowych flag; po
  komendzie committed idzie jeszcze mini-DiSEqC tone burst (A/B), który wysyła też
  enigma — dla przełączników reagujących wyłącznie na burst,
- próbuje kolejnych frontendów, aż któryś się otworzy (zajęte tunery zwracają
  `EBUSY` i są pomijane) **i** złapie LOCK,
- skanuje aż tablica bukietu będzie **kompletna** (śledzenie sekcji BAT): po
  nominalnym oknie `--scan-secs` czyta dalej, dopóki napływają nowe usługi, LCN-y
  lub sekcje, i kończy po 15 s ciszy — dzięki temu wolne, wielkie tablice (BAT
  Sky) dochodzą do końca, a szybkie platformy na nic nie czekają,
  a nie tylko przez sztywny czas.

Opcje:

| opcja | znaczenie |
|---|---|
| `--provider canalplus\|polsat` | którą platformę skanować (wymagane) |
| `--adapter N` / `--frontend N` / `--demux N` | przypięcie konkretnych urządzeń (domyślnie: auto) |
| `--settings ŚCIEŻKA` | ustawienia enigmy (domyślnie `/etc/enigma2/settings`) |
| `--scr-slot N --scr-freq MHz` | wymuszenie Unicable EN50494 (nadpisuje settings) |
| `--diseqc-port N` | wymuszenie portu committed DiSEqC 0–3 (nadpisuje settings) |
| `--dry-run` | wypisuje decyzję o antenie/tunerze (pozycje, port DiSEqC, unicable) i kończy, nie dotykając tunera |
| `--lnb-lo/hi/sw kHz` | parametry uniwersalnego LNB (domyślnie 9750/10600/11700 MHz) |
| `--secs S` | czekanie na LOCK per tuner (domyślnie 8) |
| `--scan-secs S` | bazowy czas skanu (domyślnie 25; wydłuża się do 4× aż BAT będzie kompletny) |

## Format wyjścia

Jedna linia na rekord na stdout, diagnostyka na stderr:

```
# provider=Polsat Box freq=12188000 pol=V lock=1 frontend=0
T 1CE8:0071 freq=12188000 pol=V sr=27500000 fec=3 sys=S2 pos=130E mod=2
S 3391:3390:0071 type=1 ca=1 "Polsat HD" "Cyfrowy Polsat S.A."
L 1 3391:3390:0071 visible=1 src=nit
```

- `T` — transponder z NIT (`tsid:onid`, częstotliwość kHz, polaryzacja,
  symbol rate, kod FEC DVB, S/S2, pozycja orbitalna, modulacja),
- `S` — usługa z SDT (`sid:tsid:onid`, typ usługi DVB, flaga `ca` FTA/kodowany,
  nazwa, provider),
- `L` — numer logiczny kanału (`src=nit` — Polsat, deskryptor 0x82;
  `src=bat` — Canal+, deskryptor 0x83 w bukiecie 0x2020, z flagą
  visible-service).

## Jak czyta dane

Stroi się na transponder domowy platformy (Canal+: 10719 V, Polsat: 12188 V)
i czyta tablice DVB SI z demuxa trzema równoległymi filtrami sekcji:
SDT actual+other jedną maską (0x42/0xFB), NIT actual oraz BAT filtrowany po
bouquet id. Filtr BAT jest dodatkowo weryfikowany programowo — niektóre
sterowniki demuxa (widziane na czesci dekoderow) ignorują część extension filtra
sprzętowego.

## Podziękowania / inspiracja

Inspiracją dla satscan był **[SatScanLcn](https://github.com/Huevos/SatScanLcn)**
autorstwa Huevosa — wtyczka Enigma2 obsługująca ponad 30 europejskich platform.
Jego baza providerów i parsowanie deskryptorów posłużyły za punkt odniesienia
dla parametrów transponderów domowych i układów deskryptorów LCN (0x82 NIT /
0x83 BAT). satscan to niezależna implementacja od zera (Zig, surowe syscalle,
bez zależności od Enigma2), nie port tamtego kodu.

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

## Licencja

GPL-2.0 — patrz [LICENSE](LICENSE). Parametry providerów i układy deskryptorów
pochodzą z [SatScanLcn](https://github.com/Huevos/SatScanLcn) (GPLv2), więc ten
projekt zachowuje tę samą licencję.

## Przetestowane na

| dekoder | arch | instalacja |
|---|---|---|
| 2×DVB-S2X box | armv7l | uniwersalny LNB, bez DiSEqC |
| FBC box (8×) | armv7l | Unicable EN50494 (Sharp, auto z settings) |
| ARM box (bez NEON) | armv7l | uniwersalny LNB |
| MIPS box | mipsel r1 | uniwersalny LNB |

Pełne zgrania z wszystkich czterech dekoderów są **bitowo identyczne**
(Canal+: 38 T / 644 S / 629 L; Polsat: 42 T / 333 S / 298 L).
