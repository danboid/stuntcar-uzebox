#pragma once
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef unsigned char BYTE; typedef uint16_t WORD; typedef uint32_t DWORD; typedef int BOOL;
typedef const wchar_t *LPCWSTR; typedef void *HMODULE; typedef void *HWND; typedef long HRESULT;
typedef uint32_t D3DCOLOR; struct D3DXVECTOR3 { float x,y,z; D3DXVECTOR3(){} D3DXVECTOR3(float a,float b,float c):x(a),y(b),z(c){} };
typedef struct { float _11,_12,_13,_14,_21,_22,_23,_24,_31,_32,_33,_34,_41,_42,_43,_44; } D3DXMATRIX;
struct IDirect3DDevice9; struct IDirect3DVertexBuffer9; struct IDirect3DTexture9;
#define TRUE 1
#define FALSE 0
#define D3DCOLOR_XRGB(r,g,b) ((D3DCOLOR)(((r)<<16)|((g)<<8)|(b)))
#define S_OK 0
#define WCHAR wchar_t
struct IDirectSoundBuffer8 { void Play(int,int,int){} void Stop(){} void SetVolume(long){} void SetFrequency(long){} void SetCurrentPosition(int){} long GetCurrentPosition(DWORD*,DWORD*){return 0;} };
typedef struct { long x, y; } POINT;
typedef uint32_t UINT; typedef int32_t LONG; typedef void VOID;
#define DSBPLAY_LOOPING 1
#define CALLBACK
#include <math.h>
struct CXBOXController { CXBOXController(int){} bool IsConnected(){return false;} };
#define MessageBox(a,b,c,d) ((void)0)
#define MB_OK 0
/* deterministic random numbers, identical on the PC and the AVR (15-bit, like MSVC rand) */
#ifdef __cplusplus
extern "C" {
#endif
int scr_rand(void);
#ifdef __cplusplus
}
#endif
#define rand() scr_rand()
#define srand(x) ((void)0)
