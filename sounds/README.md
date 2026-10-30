# Sound effect samples

The 128 KB SPI RAM build (the default) plays the remake's six sound effects from samples made
from the `.wav` files in this folder - `make uze` converts them with `../tools/mksfx.py` (python3)
and stores them in the `.uze` after the track data:

| File | Played when |
|---|---|
| `grounded.wav` | the car hits the ground hard (a landing that damages it) |
| `offroad.wav` | the car is on the ground off the road: dust (asked for every game tick there; it plays to its end before it starts again) |
| `wreck.wav` | sparks: the car scrapes along the road's edge, or rides on a wrecked wheel |
| `smash.wav` | damage that makes a new hole in the damage bar |
| `creak.wav` | lighter damage |
| `hitcar.wav` | the two cars collide |

* Any sample rate, 8/16/24/32-bit or float, mono or stereo. Each file is mixed to mono,
  resampled to the mixer's 7,867 Hz, trimmed of near-silence at both ends, normalised to full
  scale and stored as 8-bit.
* Any length: the six together must fit in 60,928 bytes (about 7.7 s at 7,867 Hz; one effect at
  most 8.3 s). `mksfx.py` lists each one's size and stops the build if they do not fit.
* A missing file: that effect gets the noise burst of the builds without samples.
* An effect asked for again while it plays goes on; another effect replaces it. It is added to
  the engine at three quarters of full scale (the engine plays at a quarter, effect or not).

To hear what the console will play, before building:

```sh
python3 ../tools/mksfx.py . /tmp/sfx.bin --preview /tmp/sfx_preview   # 8-bit, 7,867 Hz .wav files
python3 ../tools/mksfx.py . /tmp/sfx.bin --gain offroad=-6               # an effect 6 dB quieter
```

(`--gain` is a `mksfx.py` option; to use one in the build, add it to the `scrsfx.bin` rule in
`game/Makefile`.)

The 64 KB build (`SPIRAM=64`) and `SAMPLES=0` keep the noise bursts and need no python3.
