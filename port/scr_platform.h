/* Platform layer for the Stunt Car Racer (Remake) logic port: replaces the DirectX/Windows
 * headers. Builds unchanged on the PC (32-bit reference) and the AVR (Uzebox). */
#pragma once
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
/* abs() on long values: avr-libc only has int abs() (16 bits on the AVR), C++ on the PC has
 * an overload for long. Use one 32-bit version everywhere. */
static inline long scr_labs(long x) { return x < 0 ? -x : x; }
#undef abs
#define abs(x) scr_labs(x)        /* only renderer-side outputs still use floats (opponent angles, shadow, camera) */
#ifdef __AVR__
#include <avr/pgmspace.h>
#define RD8(p)   pgm_read_byte(p)
#define RD16(p)  ((int16_t)pgm_read_word(p))
#define RD32(p)  ((int32_t)pgm_read_dword(p))
#else
#define PROGMEM
#define RD8(p)   (*(const uint8_t *)(p))
#define RD16(p)  (*(const int16_t *)(p))
#define RD32(p)  (*(const int32_t *)(p))
#endif
typedef unsigned char BYTE; typedef uint16_t WORD; typedef uint32_t DWORD; typedef int BOOL;
typedef uint32_t UINT; typedef int32_t LONG;
typedef uint32_t D3DCOLOR; typedef long HRESULT; typedef wchar_t WCHAR;
#define TRUE 1
#define FALSE 0
#define D3DCOLOR_XRGB(r,g,b) ((D3DCOLOR)(((uint32_t)(r)<<16)|((uint32_t)(g)<<8)|(uint32_t)(b)))
struct D3DXVECTOR3 { float x,y,z; D3DXVECTOR3(){} D3DXVECTOR3(float a,float b,float c):x(a),y(b),z(c){} };
struct IDirect3DDevice9;
struct IDirectSoundBuffer8;
void scr_sfx_play(const IDirectSoundBuffer8 *b);       /* port: sound effects (harness.cpp / the game) */
struct IDirectSoundBuffer8 { void Play(int,int,int){ scr_sfx_play(this); } void Stop(){} void SetVolume(long){} void SetFrequency(long){}
                             void SetCurrentPosition(int){} long GetCurrentPosition(DWORD*,DWORD*){return 0;} };
typedef struct { long x, y; } POINT;
#define DSBPLAY_LOOPING 1
#define MessageBox(a,b,c,d) ((void)0)
#define MB_OK 0
struct CXBOXController { CXBOXController(int){} bool IsConnected(){return false;} };
/* deterministic random numbers: identical on PC and AVR */
extern "C" int scr_rand(void);
#define rand() scr_rand()
#define srand(x) ((void)0)
/* integer maths (scr_math.cpp) */
short scr_sin(long angle);
long scr_atan_angle(long o, long a);
unsigned long scr_isqrt(unsigned long v);
long scr_atan2(long y, long x);
