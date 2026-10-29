/* Headless cuzebox runner: load a .hex, run until SRAM[done] == 0xA5 (or a cycle limit),
 * then dump the 4 KB SRAM image (index = address & 0xFFF, as cuzebox stores it). */
#include <stdio.h>
#include <stdlib.h>
#include "cu_avr.h"
#include "cu_hfile.h"
#include "cu_spir.h"
#include "filesys.h"
#include "cu_spisd.h"
extern void (*prof_hook)(auint pc, auint c0, auint c1);
extern auint prof_irq_vect, prof_irq_cycle;
static unsigned long pcy[32768];
static void hook(auint pc, auint c0, auint c1){ pcy[pc & 0x7FFFU] += c1 - c0; }

int main(int argc, char** argv)
{
 cu_state_cpu_t* cpu;
 unsigned done_addr, i;
 unsigned long chunks = 0;
 FILE* f;
 if (argc < 4){ fprintf(stderr, "usage: runtest prog.hex done_addr_hex sram.bin\n"); return 1; }
 done_addr = strtoul(argv[2], 0, 16) & 0xFFFU;
 cpu = cu_avr_get_state();
 static char tstr[256];
 filesys_setpath(argv[1], &(tstr[0]), 200U);   /* SD card = the program's folder, as in main.c */
 if (!cu_hfile_load(&(tstr[0]), &(cpu->crom[0]))){ fprintf(stderr, "hex load failed\n"); return 1; }
 cu_avr_autofuse(1);
 cu_spir_set_size(getenv("SPIR_BANKS") ? (unsigned)atoi(getenv("SPIR_BANKS")) : 2U);   /* SPIR_BANKS=1: a 64 KB chip */
 { cu_spisd_model_t m;           /* SD timing model as the cuzebox-ex front end (default NORMAL) */
   cu_spisd_model_preset(getenv("SDPRESET") ? (auint)strtoul(getenv("SDPRESET"), 0, 0) : CU_SPISD_PRESET_NORMAL, &m);
   cu_spisd_model_set(&m); }          /* 128 KB SPI RAM (23LC1024), as the cuzebox-ex front end */
 cu_avr_reset();
 { cu_spisd_model_t m;           /* SD timing model as the cuzebox-ex front end (default NORMAL) */
   cu_spisd_model_preset(getenv("SDPRESET") ? (auint)strtoul(getenv("SDPRESET"), 0, 0) : CU_SPISD_PRESET_NORMAL, &m);
   cu_spisd_model_set(&m); }
 if (argc > 4) prof_hook = hook;
 while (cpu->sram[done_addr] != 0xA5U){
  cu_avr_run();
  if (++chunks > (getenv("RT_LIMIT") ? strtoul(getenv("RT_LIMIT"), 0, 0) : 2000000UL)){
   fprintf(stderr, "timeout, stuck at word address 0x%x; SD state %u cmd %u evcnt %u ena %u crc %u\n", (unsigned)cpu->pc, (unsigned)cu_spisd_get_state()->state, (unsigned)cu_spisd_get_state()->cmd, (unsigned)cu_spisd_get_state()->evcnt, (unsigned)cu_spisd_get_state()->ena, (unsigned)cu_spisd_get_state()->crc);
   f = fopen(argv[3], "wb"); for (i = 0; i < 4096U; i++){ fputc(cpu->sram[i], f); } fclose(f);
   if (getenv("SPIR_DUMP")){ f = fopen(getenv("SPIR_DUMP"), "wb"); fwrite(cu_spir_get_state()->ram, 0x20000U, 1, f); fclose(f); }
   return 2;
  }
 }
 f = fopen(argv[3], "wb");
 for (i = 0; i < 4096U; i++){ fputc(cpu->sram[i], f); }
 fclose(f);
 if (argc > 4){ f = fopen(argv[4], "wb"); fwrite(pcy, sizeof(pcy), 1, f); fclose(f); }
 if (getenv("SPIR_DUMP")){ f = fopen(getenv("SPIR_DUMP"), "wb"); fwrite(cu_spir_get_state()->ram, 0x20000U, 1, f); fclose(f); }
 printf("done after ~%lu cycles\n", chunks * 1920UL);
 return 0;
}
