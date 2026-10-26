; Fixed-address RAM buffers (the renderer, the rasterizer and the SD loader take turns) (linker: --section-start=.ringbuf=0x800100 in m19_mode.S's
; section, .wsbuf=0x800200, data from 0x8004B0)
;   scr_ws / rast_buf / scr_io_buffer: the renderer's workspace (vertex rows, clip buffers),
;   256-aligned so the rasterizer can use it as its output buffer while a picture is
;   rasterized, and the SD loader's 512-byte buffer at boot - never in use at the same time.
	.section .wsbuf,"aw",@nobits
	.global scr_ws, rast_buf, scr_io_buffer, pool, scr_bucket
scr_ws:
rast_buf:
scr_io_buffer:
	.skip	256
pool:                                   ; the rasterizer's active-edge slots (72 x 9 bytes): it runs
	.skip	432                     ; only after the renderer has finished with its workspace
scr_bucket:                             ; the renderer's row heads (110 x 16 bit) - free while a picture is
	.skip	220                     ; rasterized, so they are also the pool's slots 48 .. 71
