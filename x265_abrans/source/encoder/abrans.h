#pragma once

#include <stdint.h>
#include <math.h>

#define ABRANS_VSW_LEN   6
#define ABRANS_VSW_ONE   (1 << (ABRANS_VSW_LEN * 2))        // 4096
#define ABRANS_VSW_HALF  (1 << (ABRANS_VSW_LEN * 2 - 1))    // 2048

#define ABRANS_RANS_BYTE_L      (1u << 23)
#define ABRANS_PROB_BITS        14
#define ABRANS_PROB_SCALE       (1 << ABRANS_PROB_BITS)       // 16384
#define ABRANS_PROB_SCALE_M1    ((1 << ABRANS_PROB_BITS) - 1) // 16383
#define ABRANS_XMAX_SHIFT       (23 - ABRANS_PROB_BITS + 8)   // 17
#define ABRANS_WSHIFT           (ABRANS_PROB_BITS - ABRANS_VSW_LEN * 2) // 2

#define ABRANS_NUM_CTX  161
 
static inline uint16_t abrans_vsw_from_cabac(uint8_t cs)
{
    uint32_t mps = cs & 1;
    uint32_t k   = cs >> 1;
    double p_lps = 0.5 * pow(0.0375, k / 63.0);
    double p1_f  = mps ? (1.0 - p_lps) : p_lps;
    uint32_t vsw = (uint32_t)(p1_f * ABRANS_VSW_ONE + 0.5);
    if (vsw == 0) vsw = 1;
    if (vsw >= (uint32_t)ABRANS_VSW_ONE) vsw = ABRANS_VSW_ONE - 1;
    return (uint16_t)vsw;
}

extern uint32_t g_abrans_recip[ABRANS_PROB_SCALE];
void abrans_init_tables();
