#!/usr/bin/env python3
"""Sound effect samples for the 128 KB SPI RAM build (game/Makefile: SAMPLES=1).

    python3 mksfx.py SOUNDS_DIR OUT.BIN [--preview DIR] [--gain NAME=DB ...] [--no-trim]

Reads SOUNDS_DIR/<effect>.wav for the six effects of the remake (any of them may be missing:
that effect gets the noise burst of the builds without samples), converts each one to what the
mixer plays -
mono, 8-bit unsigned (128 = silence), 7867 Hz (one sample per two scanlines) - and writes the
blob that `make uze` stores in the .uze after the track data. The game loads it into SPI RAM
at 0x5200 (after the track data, up to the renderer's buffers at 0x14000: 60,928 bytes).

WAV files: PCM 8/16/24/32-bit or float, mono or stereo, any sample rate, any length (the total
must fit). Each one is mixed to mono, resampled (windowed-sinc low-pass), trimmed of near-
silence at both ends (--no-trim keeps it), normalised to full scale, then scaled by its gain
(--gain offroad=-6: 6 dB quieter than full scale).

Blob: 'S' 'X' count 0, then per effect (in the game's order) offset and length (16-bit little-
endian; offset from the blob's start, length in samples), then the samples, padded to a whole
number of 512-byte sectors.

--preview DIR writes DIR/<effect>.wav: exactly what the console plays (8-bit, 7867 Hz)."""
import sys, os, struct, math, argparse

EFFECTS = ['grounded', 'offroad', 'wreck', 'smash', 'creak', 'hitcar']   # sfx_req - 1 (scr_shim.cpp)
RATE = 28636360 / 1820 / 2          # the mixer: one sample per two lines, 7867.1 Hz
MAX_BYTES = 0x14000 - 0x5200        # SPI RAM from the track data to the renderer's edge slots
HEAD = 4 + 4 * len(EFFECTS)
# an effect without a .wav: the noise burst of the builds without samples (game/scr_game.c,
# sfx_tab: each random value held for `grain` scanlines, `frames` display frames long; binary,
# from pjmix.S's 16-bit Galois LFSR)
NOISE = {'grounded': (8, 7), 'offroad': (6, 9), 'wreck': (2, 42), 'smash': (1, 21), 'creak': (12, 7),
         'hitcar': (3, 14)}


def noise_burst(grain, frames, lfsr):
    hold, n, out, v = max(1, round(grain / 2)), frames * 131, bytearray(), 128
    for i in range(n):
        if i % hold == 0:
            lsb = lfsr[0] & 1
            lfsr[0] >>= 1
            if lsb:
                lfsr[0] ^= 0xB400
            v = 255 if lfsr[0] & 0x80 else 0
        out.append(v)
    return bytes(out)


def read_wav(path):
    """-> (sample rate, mono samples as floats in -1..1)"""
    d = open(path, 'rb').read()
    if d[:4] != b'RIFF' or d[8:12] != b'WAVE':
        raise ValueError('not a RIFF/WAVE file')
    i, fmt, data = 12, None, None
    while i + 8 <= len(d):
        cid, sz = d[i:i + 4], struct.unpack_from('<I', d, i + 4)[0]
        body = d[i + 8:i + 8 + sz]
        if cid == b'fmt ':
            fmt = body
        elif cid == b'data':
            data = body
        i += 8 + sz + (sz & 1)
    if fmt is None or data is None:
        raise ValueError('no fmt or data chunk')
    tag, ch, rate, _, align, bits = struct.unpack_from('<HHIIHH', fmt)
    if tag == 0xFFFE and len(fmt) >= 26:                 # WAVE_FORMAT_EXTENSIBLE: the sub-format
        tag = struct.unpack_from('<H', fmt, 24)[0]
    width = bits // 8
    if tag == 1 and bits in (8, 16, 24, 32):
        if bits == 8:
            conv = lambda b, o: (b[o] - 128) / 128
        else:
            full = float(1 << (bits - 1))
            conv = lambda b, o: int.from_bytes(b[o:o + width], 'little', signed=True) / full
    elif tag == 3 and bits in (32, 64):
        f = '<f' if bits == 32 else '<d'
        conv = lambda b, o: struct.unpack_from(f, b, o)[0]
    else:
        raise ValueError(f'unsupported format (tag {tag}, {bits} bits)')
    n = len(data) // align
    out = []
    for k in range(n):
        o = k * align
        out.append(sum(conv(data, o + c * width) for c in range(ch)) / ch)
    return rate, out


def resample(x, src, dst, taps=24):
    """windowed-sinc (Blackman) resampling, cut-off below the lower Nyquist frequency"""
    if abs(src - dst) < 1e-6:
        return list(x)
    ratio = dst / src
    fc = 0.45 * min(1.0, ratio)                          # cut-off, in cycles per source sample
    half = int(math.ceil(taps / min(1.0, ratio)))
    n_out = int(len(x) * ratio)
    out = []
    for j in range(n_out):
        t = j / ratio                                    # position in source samples
        c = int(math.floor(t))
        acc = wsum = 0.0
        for k in range(c - half + 1, c + half + 1):
            if k < 0 or k >= len(x):
                continue
            u = t - k
            s = 2 * fc * (math.sin(2 * math.pi * fc * u) / (2 * math.pi * fc * u) if u else 1.0)
            w = 0.42 + 0.5 * math.cos(math.pi * u / half) + 0.08 * math.cos(2 * math.pi * u / half)
            acc += x[k] * s * w
            wsum += s * w
        out.append(acc / wsum if wsum else 0.0)
    return out


def trim(x, level=1.5 / 128):
    """near-silence off both ends"""
    a, b = 0, len(x)
    while a < b and abs(x[a]) < level:
        a += 1
    while b > a and abs(x[b - 1]) < level:
        b -= 1
    return x[a:b]


def to_u8(x, gain_db):
    peak = max((abs(v) for v in x), default=0.0)
    g = (127.0 / peak if peak else 0.0) * 10 ** (gain_db / 20)
    return bytes(max(0, min(255, int(round(128 + v * g)))) for v in x)


def write_preview(path, s):
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(s)) + b'WAVEfmt ' +
                struct.pack('<IHHIIHH', 16, 1, 1, int(round(RATE)), int(round(RATE)), 1, 8) +
                b'data' + struct.pack('<I', len(s)) + s)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('sounds')
    ap.add_argument('out')
    ap.add_argument('--preview')
    ap.add_argument('--gain', action='append', default=[], metavar='NAME=DB')
    ap.add_argument('--no-trim', action='store_true')
    a = ap.parse_args()
    gains = {}
    for g in a.gain:
        k, v = g.split('=')
        if k.lower() not in EFFECTS:
            sys.exit(f'mksfx: --gain: no effect "{k}" (effects: {", ".join(EFFECTS)})')
        gains[k.lower()] = float(v)
    names = os.listdir(a.sounds) if os.path.isdir(a.sounds) else []
    files = {f.lower()[:-4]: f for f in names if f.lower().endswith('.wav')}
    for k in files:
        if k not in EFFECTS:
            print(f'mksfx: {files[k]}: not an effect name, ignored ({", ".join(EFFECTS)})')
    blob, table, lfsr = bytearray(), [], [1]
    print(f'mksfx: {RATE:.0f} Hz, 8-bit; up to {MAX_BYTES} bytes in all')
    for e in EFFECTS:
        if e not in files:
            s = noise_burst(*NOISE[e], lfsr)
            note = f'(no {e}.wav: a noise burst)'
        else:
            path = os.path.join(a.sounds, files[e])
            try:
                rate, x = read_wav(path)
            except (ValueError, struct.error) as err:
                sys.exit(f'mksfx: {path}: {err}')
            y = resample(x, rate, RATE)
            if not a.no_trim:
                y = trim(y)
            s = to_u8(y, gains.get(e, 0.0))
            if len(s) > 0xFFFF:
                sys.exit(f'mksfx: {path}: {len(s) / RATE:.2f} s, longer than the 8.3 s an effect can last')
            note = f'(from {files[e]}: {rate} Hz, {len(x) / rate:.2f} s)'
        table.append((HEAD + len(blob), len(s)))
        blob += s
        print(f'  {e:9s} {len(s):6d}    {len(s) / RATE:5.2f} s  {note}')
        if a.preview:
            os.makedirs(a.preview, exist_ok=True)
            write_preview(os.path.join(a.preview, e + '.wav'), s)
    out = bytearray(b'SX' + bytes([len(EFFECTS), 0]))
    for off, n in table:
        out += struct.pack('<HH', off, n)
    out += blob
    out += bytes((-len(out)) % 512)
    print(f'mksfx: {len(out)} bytes ({len(out) // 512} sectors), {MAX_BYTES - len(out)} to spare')
    if len(out) > MAX_BYTES:
        sys.exit(f'mksfx: {len(out)} bytes: more than the {MAX_BYTES} of SPI RAM for the samples - '
                 'shorten some sounds (or lower their level so more of their ends is trimmed)')
    open(a.out, 'wb').write(out)


if __name__ == '__main__':
    main()
