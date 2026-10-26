/* Uzebox video mode 19: run-length-encoded scanlines (videoMode19.s). Build with -DVIDEO_MODE=19
 * and this folder's parent on the include path (or this folder copied into kernel/), with the
 * kernel's defines.h listing mode 19 (kernel/uzebox_kernel.patch). */
#pragma once
#define M19_KERNEL                      /* the mode source: kernel build (not its standalone tests) */
#define VMODE_ASM_SOURCE   "videoMode19/videoMode19.s"
#define VMODE_C_PROTOTYPES "videoMode19/videoMode19.h"
#define VMODE_FUNC         m19_render
#define FIRST_RENDER_LINE  20          /* kernel calls m19_render on this line (left blank)  */
#define FRAME_LINES        222         /* + 220 picture lines + 1 line during the handback   */

/* The kernel's shared headers expect tile-mode parameters; this mode has no tiles. */
#define VRAM_PTR_TYPE      unsigned char
#define VRAM_ADDR_SIZE     1
#define TILE_WIDTH         8
#define TILE_HEIGHT        8
#define VRAM_TILES_H       32
#define VRAM_TILES_V       28
#define SCREEN_TILES_H     32
#define SCREEN_TILES_V     28
#define VRAM_SIZE          0
