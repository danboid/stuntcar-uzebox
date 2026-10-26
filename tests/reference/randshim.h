#include <stdlib.h>
#ifdef __cplusplus
extern "C" int scr_rand(void);
#else
int scr_rand(void);
#endif
#define rand() scr_rand()
