/*
 * H.26L/H.264/AVC/JVT/14496-10/... encoder/decoder
 * Copyright (c) 2003 Michael Niedermayer <michaelni@gmx.at>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * Context Adaptive Binary Arithmetic Coder inline functions
 */

#ifndef AVCODEC_CABAC_FUNCTIONS_H
#define AVCODEC_CABAC_FUNCTIONS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <math.h>

#include "libavutil/attributes.h"
#include "libavutil/intmath.h"
#include "cabac.h"
#include "config.h"

#define ABRANS_VSW_LEN      6
#define ABRANS_VSW_ONE      (1 << (ABRANS_VSW_LEN * 2))
#define ABRANS_VSW_HALF     (1 << (ABRANS_VSW_LEN * 2 - 1))
#define ABRANS_RANS_BYTE_L  (1u << 23)
#define ABRANS_PROB_BITS    14
#define ABRANS_PROB_SCALE   (1 << ABRANS_PROB_BITS)
#define ABRANS_PROB_SCALE_M1 ((1 << ABRANS_PROB_BITS) - 1)
#define ABRANS_WSHIFT       (ABRANS_PROB_BITS - ABRANS_VSW_LEN * 2)

static av_always_inline uint16_t abrans_vsw_from_cabac(uint8_t cs)
{
    uint32_t mps = cs & 1;
    uint32_t k   = cs >> 1;
    double p_lps = 0.5 * pow(0.0375, k / 63.0);
    double p1_f  =   mps ? (1.0 - p_lps) : p_lps;
    uint32_t vsw = (uint32_t)(p1_f * ABRANS_VSW_ONE + 0.5);
    if (vsw == 0) vsw = 1;
    if (vsw >= (uint32_t)ABRANS_VSW_ONE) vsw = ABRANS_VSW_ONE - 1;
    return (uint16_t)vsw;
}

#ifndef UNCHECKED_BITSTREAM_READER
#define UNCHECKED_BITSTREAM_READER !CONFIG_SAFE_BITSTREAM_READER
#endif

#if ARCH_AARCH64
#   include "aarch64/cabac.h"
#endif
#if ARCH_ARM
#   include "arm/cabac.h"
#endif
#if ARCH_X86
#   include "x86/cabac.h"
#endif
#if ARCH_MIPS
#   include "mips/cabac.h"
#endif
#if ARCH_LOONGARCH64
#   include "loongarch/cabac.h"
#endif

static const uint8_t * const ff_h264_norm_shift = ff_h264_cabac_tables + H264_NORM_SHIFT_OFFSET;
static const uint8_t * const ff_h264_lps_range = ff_h264_cabac_tables + H264_LPS_RANGE_OFFSET;
static const uint8_t * const ff_h264_mlps_state = ff_h264_cabac_tables + H264_MLPS_STATE_OFFSET;
static const uint8_t * const ff_h264_last_coeff_flag_offset_8x8 = ff_h264_cabac_tables + H264_LAST_COEFF_FLAG_OFFSET_8x8_OFFSET;

#if !defined(get_cabac_bypass) || !defined(get_cabac_terminate)
static void refill(CABACContext *c){
#if CABAC_BITS == 16
        c->low+= (c->bytestream[0]<<9) + (c->bytestream[1]<<1);
#else
        c->low+= c->bytestream[0]<<1;
#endif
    c->low -= CABAC_MASK;
#if !UNCHECKED_BITSTREAM_READER
    if (c->bytestream < c->bytestream_end)
#endif
        c->bytestream += CABAC_BITS / 8;
}
#endif

#ifndef get_cabac_terminate
static inline void renorm_cabac_decoder_once(CABACContext *c){
    int shift= (uint32_t)(c->range - 0x100)>>31;
    c->range<<= shift;
    c->low  <<= shift;
    if(!(c->low & CABAC_MASK))
        refill(c);
}
#endif

#ifndef get_cabac_inline
static void refill2(CABACContext *c){
    int i;
    unsigned x;
#if !HAVE_FAST_CLZ
    x= c->low ^ (c->low-1);
    i= 7 - ff_h264_norm_shift[x>>(CABAC_BITS-1)];
#else
    i = ff_ctz(c->low) - CABAC_BITS;
#endif

    x= -CABAC_MASK;

#if CABAC_BITS == 16
        x+= (c->bytestream[0]<<9) + (c->bytestream[1]<<1);
#else
        x+= c->bytestream[0]<<1;
#endif

    c->low += x<<i;
#if !UNCHECKED_BITSTREAM_READER
    if (c->bytestream < c->bytestream_end)
#endif
        c->bytestream += CABAC_BITS/8;
}
#endif

#ifndef get_cabac_inline
static av_always_inline int get_cabac_inline(CABACContext *c, uint8_t * const state, uint8_t * const start)
{
    int ffctx = start ? (int)(state - start) : -1;
    int ctx = (ffctx >= 0 && ffctx < 199) ? ffctx : 0;
    uint32_t p1 = (uint32_t)c->abrans_vsw[ctx] << ABRANS_WSHIFT;
    if (p1 == 0) p1 = 1;
    if (p1 >= (uint32_t)ABRANS_PROB_SCALE) p1 = ABRANS_PROB_SCALE - 1;
    uint32_t p0 = ABRANS_PROB_SCALE - p1;

    uint32_t cumcurr = c->abrans_rans & ABRANS_PROB_SCALE_M1;
    int bit;
    if (cumcurr < p0) {
        bit = 0;
        c->abrans_rans = p0 * (c->abrans_rans >> ABRANS_PROB_BITS) + cumcurr;
        c->abrans_vsw[ctx] -= c->abrans_vsw[ctx] >> ABRANS_VSW_LEN;
    } else {
        bit = 1;
        c->abrans_rans = p1 * (c->abrans_rans >> ABRANS_PROB_BITS) + cumcurr - p0;
        c->abrans_vsw[ctx] += (uint16_t)((ABRANS_VSW_ONE - c->abrans_vsw[ctx]) >> ABRANS_VSW_LEN);
    }
    if (c->abrans_rans < ABRANS_RANS_BYTE_L)
        c->abrans_rans = (c->abrans_rans << 8) | *c->abrans_ptr++;
    return bit;
}
#endif

av_noinline static int get_cabac_noinline(CABACContext *c, uint8_t * const state){
    return get_cabac_inline(c, state, NULL);
}

static int get_cabac(CABACContext *c, uint8_t * const state){
    return get_cabac_inline(c, state, NULL);
}

#ifndef get_cabac_bypass
static av_always_inline int get_cabac_bypass(CABACContext *c)
{
    uint32_t rans = c->abrans_rans;
    int bit = (rans >> (ABRANS_PROB_BITS - 1)) & 1;
    rans = ((rans >> 1) & ~(uint32_t)(ABRANS_PROB_SCALE / 2 - 1)) |
           (rans & (uint32_t)(ABRANS_PROB_SCALE / 2 - 1));
    if (rans < ABRANS_RANS_BYTE_L)
        rans = (rans << 8) | *c->abrans_ptr++;
    c->abrans_rans = rans;
    return bit;
}
#endif

#ifndef get_cabac_bypass_sign
static av_always_inline int get_cabac_bypass_sign(CABACContext *c, int val)
{
    return get_cabac_bypass(c) ? val : -val;
}
#endif

/**
 * @return the number of bytes read or 0 if no end
 */
#ifndef get_cabac_terminate
av_unused static int get_cabac_terminate(CABACContext *c)
{
    uint32_t p1 = (uint32_t)c->abrans_vsw[199] << ABRANS_WSHIFT;
    if (p1 == 0) p1 = 1;
    if (p1 >= (uint32_t)ABRANS_PROB_SCALE) p1 = ABRANS_PROB_SCALE - 1;
    uint32_t p0 = ABRANS_PROB_SCALE - p1;

    uint32_t cumcurr = c->abrans_rans & ABRANS_PROB_SCALE_M1;
    int bit;
    if (cumcurr < p0) {
        bit = 0;
        c->abrans_rans = p0 * (c->abrans_rans >> ABRANS_PROB_BITS) + cumcurr;
        c->abrans_vsw[199] -= c->abrans_vsw[199] >> ABRANS_VSW_LEN;
    } else {
        bit = 1;
        c->abrans_rans = p1 * (c->abrans_rans >> ABRANS_PROB_BITS) + cumcurr - p0;
        c->abrans_vsw[199] += (uint16_t)((ABRANS_VSW_ONE - c->abrans_vsw[199]) >> ABRANS_VSW_LEN);
    }
    if (c->abrans_rans < ABRANS_RANS_BYTE_L)
        c->abrans_rans = (c->abrans_rans << 8) | *c->abrans_ptr++;
    return bit;
}
#endif

/**
 * Skip @p n bytes and reset the decoder.
 * @return the address of the first skipped byte or NULL if there's less than @p n bytes left
 */
#ifndef skip_bytes
av_unused static const uint8_t* skip_bytes(CABACContext *c, int n) {
    const uint8_t *ptr = c->bytestream;

    if (c->low & 0x1)
        ptr--;
#if CABAC_BITS == 16
    if (c->low & 0x1FF)
        ptr--;
#endif
    if ((int) (c->bytestream_end - ptr) < n)
        return NULL;
    if (ff_init_cabac_decoder(c, ptr + n, c->bytestream_end - ptr - n) < 0)
        return NULL;

    return ptr;
}
#endif

#endif /* AVCODEC_CABAC_FUNCTIONS_H */
