# Track data

This folder holds the eight tracks of *Stunt Car Racer* and the tools that turn them into the
form the Uzebox game uses.

| File | What it is |
|---|---|
| `source/Tracks/*.bin` | **The original track data**: the eight Amiga track files, 804 bytes each |
| `source/orig_tracks.json` | A dump from the PC remake *after* it has converted the tracks: its shape templates, height profiles and fully computed tracks (written by `scr_dump()` in `tests/reference/src/Track_dump.cpp`) |
| `gen_trackdata.py` | The generator: builds `SCRTRK.BIN` and `port/scr_trackdata.h` from the two above |
| `SCRTRK.BIN` | The game's track data, appended to the `.uze` by `make uze` and copied into SPI RAM at start-up |

To regenerate (both outputs come out byte-identical):

```sh
cd data && python3 gen_trackdata.py source/orig_tracks.json source/Tracks
```

The generator takes each piece's bytes from the `.bin` files; the shape templates and height
profiles from the JSON (the remake has them built in, converted from the Amiga game); and the
JSON's computed corners, only to work out each piece's bounding sphere for the renderer.

## How a track is built

A track is a chain of up to 100 pieces, each occupying one square of a 16 x 16 grid. A piece is
stored as a few small numbers, and its 3D shape is built from two kinds of shared data:

* **Shape templates** (11): where the road's left and right edges run across a grid square, row
  by row - a straight, a diagonal, curves of different radii.
* **Height profiles** (128): the height of an edge, row by row - flat, a hill, a ramp, a jump.

A corner of the road at a given row of a piece is its template's point for that row, rotated to
the piece's direction (one of four: a swap and a mirroring of x and z, no trigonometry), placed
on the piece's grid square; its height is the edge's profile value for that row plus the piece's
offset for that edge. The left and right edges have their own profile and offset, which gives
banking. The bottom of each wall is the same point at ground level. A piece's last row is the
next piece's first, so the track joins up.

The PC remake computes every corner of a track once, into a table of tens of kilobytes. The
Uzebox, with 4 KB of RAM, keeps the compact form and computes corners when they are needed
(`port/scr_track.cpp`, `port/scr_rows.S`) - with exactly the remake's values.

## The Amiga track files (`source/Tracks/*.bin`, 804 bytes)

The per-piece arrays always have 100 entries; only the first *n* are used.

| Bytes | Content | Format |
|---|---|---|
| 0 | Number of pieces *n* | uint8 |
| 1 | The player's start piece (also the finish line) | uint8 |
| 2 - 101 | Each piece's grid square | uint8: bits 0-3 x, bits 4-7 z (0-15 each) |
| 102 - 201 | Each piece's angle and template | uint8 bitfield, below |
| 202 - 301 | Its left edge's height profile | uint8: profile ID 0-127 |
| 302 - 401 | Its right edge's height profile | uint8: bits 0-6 profile ID; **bit 7 the road stripes' starting colour** |
| 402 - 601 | Its left edge's height offset | int16, **big-endian** |
| 602 - 801 | Its right edge's height offset | int16, big-endian |
| 802 | Boost, standard league | uint8 |
| 803 | Boost, super league | uint8 |

The angle-and-template byte:

| Bits | Mask | Meaning |
|---|---|---|
| 0 - 3 | `0x0F` | Template number (0-10) |
| 4 | `0x10` | Reversed: the piece is driven from its template's far end |
| 5 | `0x20` | Unused |
| 6 - 7 | `0xC0` | Rotation: `0x00` 0 degrees, `0x40` 90 degrees clockwise, `0x80` 180, `0xC0` 270 |

## `source/orig_tracks.json`

The remake's own values, written as decimal numbers (JSON has no hexadecimal): fields that are
bitfields are given in hex below.

### `piece_y`: the 128 height profiles

`piece_y[id]` is a list of heights, one per row of a piece; `id` is the profile ID from bytes
202-401 of a track file (the low 7 bits). Profiles have 9, 10, 12 or 14 values - one more than
the segments of the templates they are used with (8, 9, 11, 13); four IDs are empty (unused).

The values are plain integers, 0 to 10,336, in the remake's height units (before its x2 scaling,
see `c` below). All are multiples of 32, from the Amiga's two storage forms: 15-bit big-endian
words (`((hi & 0x7F) << 8) | lo`), or bytes packing a coarse and a fine part:
`y = ((b & 0x0F) << 8) | ((b << 1) & 0xE0)` - bits 0-3 in steps of 256, bits 4-6 in steps of 32.

### `templates`: the 11 shape templates

| Field | Meaning | Values |
|---|---|---|
| `ns` | Segments (rows - 1) | 8, 9, 11, 13 |
| `left` | It curves to the left | 0 / 1 |
| `type` | Bits 6-7: `0x00` straight, `0x40` diagonal (45 degrees), `0x80` curve right, `0xC0` curve left | 0, 64, 128, 192 |
| `lr` | `lengthReduction`: how fast the opponent progresses through the piece, relative to 128 | 122, 124, 128, 135 |
| `steer` | `steeringAmount`: how strongly the road turns (the player's steering) | `0x20`, `0x32`, `0x3E` (32, 50, 62) |
| `xz` | The edges' positions, row by row | `(ns + 1) x 2` points `[x, z]`: left edge, right edge, alternating |

The `xz` values are plain signed 16-bit integers (not fixed point), in units of 1/2048 of a grid
square: `0x800` (2048) is one square. Straight pieces advance by 256 a row - an eighth of a
square - which can make them look like 8.8 fixed point: template 0 is `[832, 0], [1216, 0],
[832, 256], [1216, 256], ...`. Diagonal pieces reach a little into their neighbours' squares
(-136 to 2,483). The Amiga stores them as 16-bit little-endian words.

**Templates 2, 5, 8 and 9 are empty**: the original game never uses those numbers (the remake:
"only 0,1,3,4,6,7,10 used"). They keep the template numbers the Amiga's; no track refers to them.

### `tracks`: the 8 tracks

| Field | Meaning |
|---|---|
| `n` | Number of pieces |
| `start` | The start piece (also the finish line) |
| `half` | The half-lap checkpoint: `start + n / 2`, wrapped round |
| `sb`, `spb` | Boost, standard and super league |
| `segs` | Total segments of the track |
| `pieces` | One entry per piece, below |

### `pieces`

`f`, twelve values:

| Index | Field | Values |
|---|---|---|
| 0 | `x`: grid square | 0-15 |
| 1 | `y` | always 0 |
| 2 | `z`: grid square | 0-15 |
| 3 | `roughPieceAngle` | 0, 16384, 32768, 49152: the rotation bits scaled to 65536 a full turn (`0x40` -> 16384) |
| 4 | `oppositeDirection` | 0 / 1: bit 4 of the angle byte |
| 5 - 8 | `curveToLeft`, `type`, `lengthReduction`, `steeringAmount` | copied from the template |
| 9 | `numSegments` | copied from the template |
| 10 | `firstSegment` | the running total of the previous pieces' segments |
| 11 | `initialColour` | 0 / 1: bit 7 of the right height-profile byte |

* `rc`: each segment's road colour, a remake palette index: 26 a steep segment (drawn black),
  27 and 28 alternating between even and odd pieces.
* `sc`: the walls' colour, 36 or 41, alternating likewise.
* `c`: the corners, `(numSegments + 1) x 4` of them - for each row the left road edge, the right
  road edge, the left wall's bottom, the right wall's bottom - each `[x, y, z]` in world units:
  x and z `(grid square x 2048 + rotated template value) x 2` (a square is 4096), y for the
  road edges `(profile[row] + the edge's offset) x 2`, for the wall bottoms 0.

## `SCRTRK.BIN` (20,992 bytes)

Little-endian unless noted. Eight 2048-byte track slots, then the shared tables; padded to a
whole number of 512-byte sectors. In the `.uze` it is appended after the program, sector-aligned;
the game finds it there and checks it with `SCR_DATA_SUM`, the 16-bit sum of all its bytes.

A track slot (track *t* at `t x 2048`):

| Offset | Content |
|---|---|
| 0 | Number of pieces |
| 1 | Start piece |
| 2, 3 | Boost, standard and super league |
| 4 - 5 | Total segments (uint16) |
| 6 - 15 | Unused (0) |
| 16 + 16 *p* | Piece *p*'s record (100 of them), below |
| 1664 - 1919 | The track map: byte `16 x + z` is the piece on grid square (x, z), `0xFF` none |
| 1920 - 2047 | Unused (0) |

A piece record (16 bytes):

| Bytes | Content |
|---|---|
| 0 | Grid square (as the track file) |
| 1 | Angle and template (as the track file) |
| 2 | Left height profile ID |
| 3 | Right height profile ID; bit 7 the stripes' starting colour |
| 4 - 5 | Left height offset, int16 **big-endian** (as the track file) |
| 6 - 7 | Right height offset, int16 big-endian |
| 8 - 9 | `firstSegment` (uint16) |
| 10 - 11 | Steep segments: bit *i* set if segment *i* is steep (drawn black) |
| 12 - 14 | Bounding sphere centre x, y, z, in units of 64 (x, z int8 relative to the piece's square; y uint8, of height / 4) |
| 15 | Bounding sphere radius, in units of 64 (rounded up, plus a margin; Draw Bridge's moving pieces more) |

The shared tables (their offsets are in `port/scr_trackdata.h`):

| Offset | Size | Content |
|---|---|---|
| `0x4000` | 2490 | All height profiles' values, one after another (int16) |
| `0x49BA` | 256 | Each profile's first value's index (128 x uint16) |
| `0x4ABA` | 584 | All templates' points, one after another (int16 x, z pairs) |
| `0x4D02` | 514 | Sine table (257 x uint16) |
| `0x4F04` | 514 | Arctangent table (257 x uint16) |

The templates' other values (segments, direction, type, `lengthReduction`, `steeringAmount`, and
each template's first point) are small tables in flash, in `port/scr_trackdata.h`.
