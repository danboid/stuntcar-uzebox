#include <stdio.h>
#include <stdlib.h>
extern long log_state[16];
extern int run_race(long track, long ticks);
void log_tick(long tick)
{
	printf("%ld", tick);
	for (int i = 0; i < 13; i++) printf(" %ld", log_state[i]);
	printf("\n");
}
int main(int argc, char **argv)
{
	long track = argc > 1 ? atol(argv[1]) : 0, ticks = argc > 2 ? atol(argv[2]) : 600;
	return run_race(track, ticks) ? 0 : 1;
}
