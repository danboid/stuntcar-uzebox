/* Headless profiling harness for cuzebox (instruction trace + video rows). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cu_avr.h"
#include "filesys.h"
#include "cu_spir.h"
#include "cu_spisd.h"
#include "cu_ufile.h"
#include "cu_hfile.h"

extern auint prof_irq_vect, prof_irq_cycle;
extern void (*prof_hook)(auint pc, auint c0, auint c1);

static FILE* tf;
static FILE* af;
typedef struct { unsigned short pc, cy, vect, entry; } rec_t;

static int watch_addr = -1, watch_last = -1, watch_n = 0;
static auint watch_prevpc;
static unsigned min_sp = 0xFFFFU, min_sp_pc;
static unsigned lat_hist[64]; static auint tov_cycle; static int tov_armed;
static unsigned lat_ctx[64][2];
static int late_pc = -1, late_n = 0; static auint last_entry_cycle, last_tov_cycle; static unsigned last_entry_tcnt;
static unsigned short pc_minsp[65536];
static unsigned long long phase_cycles[8];
static unsigned long long phase2_pc[65536];
static unsigned phase_min[8] = {0xFFFFU,0xFFFFU,0xFFFFU,0xFFFFU,0xFFFFU,0xFFFFU,0xFFFFU,0xFFFFU}, phase_pc[8];
static void hook(auint pc, auint c0, auint c1)
{
 rec_t r;
 { cu_state_cpu_t* st = cu_avr_get_state();
   /* overflow-interrupt latency: TOV1 rise (at instruction granularity) -> IT entry */
   { static unsigned prev_tifr = 0; static auint ppc = 0;
     unsigned tifr = st->iors[CU_IO_TIFR1];
     if ((tifr & 1U) && !(prev_tifr & 1U)){ tov_cycle = c0; tov_armed = 1; }
     if (prof_irq_vect != 0xFFFFU && tov_armed && (prof_irq_vect == 15U || prof_irq_vect == 30U)){
      unsigned l = (unsigned)(prof_irq_cycle - tov_cycle); if (l > 63U) l = 63U;
      lat_hist[l]++; lat_ctx[l][0] = ppc; tov_armed = 0;
      last_entry_cycle = prof_irq_cycle; last_tov_cycle = tov_cycle;
      last_entry_tcnt = st->iors[0x84U] | ((unsigned)st->iors[0x85U] << 8);
     }
     prev_tifr = st->iors[CU_IO_TIFR1]; ppc = pc;
     { static int upc = -2, un = 0; static unsigned addrs[8]; int k;
       if (upc == -2){ upc = getenv("UNDERRUN_PC") ? (int)strtol(getenv("UNDERRUN_PC"), 0, 0) : -1;
         if (getenv("UNDERRUN_VARS")){ char const* p = getenv("UNDERRUN_VARS"); for (k = 0; k < 8 && *p; k++){ addrs[k] = (unsigned)strtol(p, (char**)&p, 0); if (*p == ',') p++; } } }
       if (upc >= 0 && (int)pc == upc && un < 40){
        fprintf(stderr, "UNDERRUN cycle %u r5 %u:", (unsigned)c0, st->iors[5]);
        for (k = 0; k < 8; k++) if (addrs[k]) fprintf(stderr, " %u", st->sram[addrs[k] & 0xFFFU]);
        fprintf(stderr, "\n"); un++; } }
     if (late_pc < 0) late_pc = getenv("ISLATE") ? (int)strtol(getenv("ISLATE"), 0, 0) : 0;
     if (late_pc && (int)pc == late_pc && late_n < 12){   /* late_dump */
      fprintf(stderr, "ISLATE: entry %u cycles after TOV1; TCNT1 at entry %u; now %u\n",
              (unsigned)(last_entry_cycle - last_tov_cycle), last_entry_tcnt,
              st->iors[0x84U] | ((unsigned)st->iors[0x85U] << 8));
      late_n++;
     } }
   unsigned sp = st->iors[CU_IO_SPL] | ((unsigned)st->iors[CU_IO_SPH] << 8);
   /* sample SP only after instructions that legitimately lower it (push, call, rcall, icall,
      out SPL) or at an interrupt entry: frame prologues write SPH first, SP is bogus until SPL */
   { static auint prev_pc = 0; static int prev_irq = 0;
     unsigned op = st->crom[(prev_pc * 2U) & 0xFFFFU] | ((unsigned)st->crom[(prev_pc * 2U + 1U) & 0xFFFFU] << 8);
     int ok = prev_irq || (op & 0xFE0FU) == 0x920FU || (op & 0xFE0EU) == 0x940EU || (op & 0xF000U) == 0xD000U ||
              op == 0x9509U || ((op & 0xF800U) == 0xB800U && ((((op >> 5) & 0x30U) | (op & 0x0FU)) == 0x3DU));
     if (!ok) sp = 0xFFFFU;
     prev_pc = pc; prev_irq = (prof_irq_vect != 0xFFFFU); }
   if (sp != 0xFFFFU && sp < min_sp){ min_sp = sp; min_sp_pc = pc; }
   { static int pa = -2; if (pa == -2) pa = getenv("PHASE") ? (int)strtol(getenv("PHASE"), 0, 0) : -1;
     if (pa >= 0){ unsigned ph_ = st->sram[pa & 0xFFFU] & 7U; phase_cycles[ph_] += (c1 - c0);
       if (ph_ == 2U) phase2_pc[pc & 0xFFFFU] += (c1 - c0); }   /* phase_fn */
     if (pa >= 0 && sp != 0xFFFFU){ unsigned ph = st->sram[pa & 0xFFFU] & 7U; if (sp < phase_min[ph]){ phase_min[ph] = sp; phase_pc[ph] = pc; }
       if (ph == 2 && (pc_minsp[pc & 0xFFFFU] == 0 || sp < pc_minsp[pc & 0xFFFFU])) pc_minsp[pc & 0xFFFFU] = (unsigned short)sp; } }
   { static int crossed = 0; static int lim = -1;
     if (lim < 0) lim = getenv("CROSS") ? (int)strtol(getenv("CROSS"), 0, 0) : 0;
     if (!crossed && lim && sp < (unsigned)lim){
      unsigned a;
      crossed = 1;
      fprintf(stderr, "CROSS sp 0x%x pc byte 0x%x; stack words:", sp, pc * 2);
      for (a = sp + 1; a < 0x10FFU; a++){           /* return addresses: big-endian word pairs */
       unsigned w = ((unsigned)st->sram[a & 0xFFFU] << 8) | st->sram[(a + 1) & 0xFFFU];
       if (w > 0x40 && w < 0x7A00) fprintf(stderr, " %x@%x", w * 2, a);
      }
      fprintf(stderr, "\n");
     } } }
 if (watch_addr >= 0){                 /* report the instruction that changed a RAM byte */
  int v = cu_avr_get_state()->sram[watch_addr & 0xFFFU];
  if (v != watch_last && watch_n < 40){
   fprintf(stderr, "WATCH 0x%x: %02x -> %02x after pc 0x%x (byte 0x%x)\n", watch_addr, watch_last & 0xFF, v, watch_prevpc, watch_prevpc * 2);
   watch_n++;
  }
  watch_last = v;
 }
 watch_prevpc = pc;
 r.pc = (unsigned short)pc;
 if (prof_irq_vect != 0xFFFFU){
  r.vect  = (unsigned short)prof_irq_vect;
  r.entry = (unsigned short)(c1 - prof_irq_cycle);      /* IT entry cycles */
  r.cy    = (unsigned short)(prof_irq_cycle - c0);      /* the instruction itself */
 }else{
  r.vect = 0xFFFF; r.entry = 0; r.cy = (unsigned short)(c1 - c0);
 }
 fwrite(&r, sizeof(r), 1, tf);
}

int main(int argc, char** argv)
{
 cu_ufile_header_t h;
 cu_state_cpu_t* cpu;
 auint skip, nfr, fr = 0, ret, i;
 FILE* vf;
 if (argc < 5){ fprintf(stderr, "usage: prof game.uze skipframes traceframes outprefix\n"); return 1; }
 skip = atoi(argv[2]); nfr = atoi(argv[3]);
 cpu = cu_avr_get_state();
 {
  size_t L = strlen(argv[1]);
  static char tstr[256];
  filesys_setpath(argv[1], &(tstr[0]), 200U);   /* SD card = the program's folder */
  if (L > 4 && strcmp(argv[1] + L - 4, ".hex") == 0){
   if (!cu_hfile_load(&(tstr[0]), &(cpu->crom[0]))){ fprintf(stderr, "load failed\n"); return 1; }
  }else if (!cu_ufile_load(&(tstr[0]), &(cpu->crom[0]), &h)){ fprintf(stderr, "load failed\n"); return 1; }
 }
 cpu->wd_seed = 12345;
 cu_avr_autofuse(0);
 cu_spir_set_size(2U);
 { cu_spisd_model_t m;           /* SD timing model as the cuzebox-ex front end (default NORMAL) */
   cu_spisd_model_preset(getenv("SDPRESET") ? (auint)strtoul(getenv("SDPRESET"), 0, 0) : CU_SPISD_PRESET_NORMAL, &m);
   cu_spisd_model_set(&m); }          /* 128 KB SPI RAM (23LC1024), as the cuzebox-ex front end */
 cu_avr_reset();
 { cu_spisd_model_t m;           /* SD timing model as the cuzebox-ex front end (default NORMAL) */
   cu_spisd_model_preset(getenv("SDPRESET") ? (auint)strtoul(getenv("SDPRESET"), 0, 0) : CU_SPISD_PRESET_NORMAL, &m);
   cu_spisd_model_set(&m); }
 { char fn[256]; sprintf(fn, "%s.trace", argv[4]); tf = fopen(fn, "wb");
   sprintf(fn, "%s.video", argv[4]); vf = fopen(fn, "wb");
   sprintf(fn, "%s.audio", argv[4]); af = fopen(fn, "wb"); }
 if (getenv("WATCH")) watch_addr = (int)strtol(getenv("WATCH"), 0, 0);
 while (fr < skip + nfr){
  if (fr == skip && !prof_hook){
   rec_t m = {0xFFFE, 0, 0, 0}; prof_hook = hook; fwrite(&m, sizeof(m), 1, tf);
  }
  ret = cu_avr_run();
  if (prof_hook && (ret & CU_GET_ROW)){
   cu_row_t const* row = cu_avr_get_row();
   unsigned short pno = (unsigned short)row->pno;
   fwrite(&pno, 2, 1, vf); fwrite(row->pixels, 1, 2032, vf);
   fputc(cpu->iors[CU_IO_OCR2A], af);                    /* the sound output, once per line */
  }
  if (ret & CU_GET_FRAME){
   fr++;
   if (prof_hook){ rec_t m = {0xFFFE, 0, 0, 0}; fwrite(&m, sizeof(m), 1, tf); }
  }
 }
 fclose(tf); fclose(vf); fclose(af);
 { int k; fprintf(stderr, "LATENCY (TOV1 rise -> IT entry, cycles: count [last interrupted pc]):");
   for (k = 0; k < 64; k++) if (lat_hist[k]) fprintf(stderr, " %d:%u[%x]", k, lat_hist[k], lat_ctx[k][0] * 2);
   fprintf(stderr, "\n"); }
 fprintf(stderr, "MINSP 0x%x at pc 0x%x (byte 0x%x)\n", min_sp, min_sp_pc, min_sp_pc * 2);
 { FILE* f = fopen("pc_minsp.bin", "wb"); fwrite(pc_minsp, 2, 65536, f); fclose(f); }
 { FILE* f = fopen("phase2_pc.bin", "wb"); fwrite(phase2_pc, 8, 65536, f); fclose(f); }
 { int k; for (k = 0; k < 8; k++) if (phase_cycles[k]) fprintf(stderr, "PHASECYC %d %llu\n", k, phase_cycles[k]); }
 { int k; for (k = 0; k < 8; k++) if (phase_min[k] != 0xFFFFU) fprintf(stderr, "PHASE %d: min sp 0x%x (depth %u) at byte 0x%x\n", k, phase_min[k], 0x10FFU - phase_min[k], phase_pc[k] * 2); }
 { char fn[256]; FILE* sf; sprintf(fn, "%s.sram", argv[4]); sf = fopen(fn, "wb"); for (i = 0; i < 4096U; i++){ fputc(cpu->sram[i], sf); } fclose(sf); }
 if (getenv("SPIR_DUMP")){ FILE* f = fopen(getenv("SPIR_DUMP"), "wb"); fwrite(cu_spir_get_state()->ram, 0x20000U, 1, f); fclose(f); }
 return 0;
}
