// © 雾月星辰 & MLXC · github@XingChenRS
// XRCClock.m — 时间基准：真实时间单一实现 + warp 计算 + freeze。

#import <Foundation/Foundation.h>
#import "XRCLog.h"          // 拒绝非法 rate 时留痕
#include "XRCClock.h"
#include <mach/mach_time.h>

static _Atomic(uint64_t) s_t0_real_us = 0;
static _Atomic(uint64_t) s_t0_warp_us = 0;
static _Atomic(uint32_t) s_rate_x1000  = 1000;
static _Atomic(int32_t)  s_freeze_count = 0;
static _Atomic(uint64_t) s_frozen_us    = 0;

// ---- 单调钟 warp 通道（ticks 域）----
static _Atomic(uint64_t) s_mt0_real_ticks = 0;
static _Atomic(uint64_t) s_mt0_warp_ticks = 0;
static _Atomic(uint64_t) s_mfrozen_ticks  = 0;
static double s_tb_ratio = 0.0;   // ticks → ns 系数（mach_timebase_info 缓存）

uint64_t (*xrc_clock_orig_mach_absolute_time)(void) = NULL;
int      (*xrc_clock_orig_clock_gettime)(int, struct timespec *) = NULL;
uint64_t (*xrc_clock_orig_steady_now)(void) = NULL;

int (*xrc_clock_orig_gettimeofday)(struct timeval *, void *) = NULL;

static double s_tb(void) {
    if (s_tb_ratio == 0.0) {
        mach_timebase_info_data_t info = {0};
        if (mach_timebase_info(&info) == KERN_SUCCESS && info.denom != 0)
            s_tb_ratio = (double)info.numer / (double)info.denom;
        if (s_tb_ratio == 0.0) s_tb_ratio = 1.0;
    }
    return s_tb_ratio;
}

static uint64_t s_ticks_to_ns(uint64_t t) { return (uint64_t)((double)t * s_tb()); }
static uint64_t s_ns_to_ticks(uint64_t ns) { double r = s_tb(); return r > 0 ? (uint64_t)((double)ns / r) : ns; }

static uint64_t s_compute_warp_ticks(uint64_t ticks) {
    double rate = xrc_clock_get_rate();
    uint64_t t0r = atomic_load(&s_mt0_real_ticks);
    uint64_t t0w = atomic_load(&s_mt0_warp_ticks);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return ticks;
    if (ticks <= t0r) return t0w;
    return t0w + (uint64_t)((double)(ticks - t0r) * rate);
}

uint64_t xrc_clock_mach_absolute_time(void) {
    uint64_t t = xrc_clock_orig_mach_absolute_time ? xrc_clock_orig_mach_absolute_time() : 0;
    if (atomic_load(&s_freeze_count) > 0) {
        uint64_t f = atomic_load(&s_mfrozen_ticks);
        return f ? f : t;
    }
    return s_compute_warp_ticks(t);
}

int xrc_clock_clock_gettime(int clk_id, struct timespec *tp) {
    if (!tp) return xrc_clock_orig_clock_gettime ? xrc_clock_orig_clock_gettime(clk_id, tp) : -1;
    int r = xrc_clock_orig_clock_gettime ? xrc_clock_orig_clock_gettime(clk_id, tp) : -1;
    if (r != 0 || clk_id != CLOCK_MONOTONIC) return r;
    uint64_t ns = (uint64_t)tp->tv_sec * 1000000000ULL + (uint64_t)tp->tv_nsec;
    uint64_t wns;
    if (atomic_load(&s_freeze_count) > 0) {
        uint64_t f = atomic_load(&s_mfrozen_ticks);
        wns = f ? s_ticks_to_ns(f) : ns;
    } else {
        wns = s_ticks_to_ns(s_compute_warp_ticks(s_ns_to_ticks(ns)));
    }
    tp->tv_sec  = (time_t)(wns / 1000000000ULL);
    tp->tv_nsec = (long)(wns % 1000000000ULL);
    return r;
}

uint64_t xrc_clock_steady_now(void) {
    uint64_t ns = xrc_clock_orig_steady_now ? xrc_clock_orig_steady_now() : 0;
    if (atomic_load(&s_freeze_count) > 0) {
        uint64_t f = atomic_load(&s_mfrozen_ticks);
        return f ? s_ticks_to_ns(f) : ns;
    }
    return s_ticks_to_ns(s_compute_warp_ticks(s_ns_to_ticks(ns)));
}

uint64_t xrc_real_now_us(void) {
    struct timeval tv = {0};
    if (xrc_clock_orig_gettimeofday && xrc_clock_orig_gettimeofday(&tv, NULL) == 0)
        return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
    if (gettimeofday(&tv, NULL) == 0)
        return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
    return 0;
}

// ---- now_ms 域 warp（BRK 站点 time_now 返回钩;谱面钟时间源）----
static _Atomic(uint64_t) s_ms_t0_real = 0;
static _Atomic(uint64_t) s_ms_t0_warp = 0;
static _Atomic(uint64_t) s_ms_frozen  = 0;

// dylib 自算毫秒(与游戏 now_ms 同基:mach ticks → ns → ms)。
static uint64_t s_ms_now(void) {
    return s_ticks_to_ns(mach_absolute_time()) / 1000000ULL;
}

static uint64_t s_compute_warp_ms(uint64_t ms) {
    double rate = xrc_clock_get_rate();
    uint64_t t0r = atomic_load(&s_ms_t0_real);
    uint64_t t0w = atomic_load(&s_ms_t0_warp);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return ms;
    if (ms <= t0r) return t0w;
    return t0w + (uint64_t)((double)(ms - t0r) * rate);
}

uint64_t xrc_clock_warp_ms(uint64_t ms) {
    if (atomic_load(&s_freeze_count) > 0) {
        uint64_t f = atomic_load(&s_ms_frozen);
        return f ? f : ms;
    }
    return s_compute_warp_ms(ms);
}

double xrc_clock_get_rate(void) {
    return (double)atomic_load(&s_rate_x1000) / 1000.0;
}

static uint64_t s_compute_warp_us(uint64_t real_us) {
    double rate = xrc_clock_get_rate();
    uint64_t t0r = atomic_load(&s_t0_real_us);
    uint64_t t0w = atomic_load(&s_t0_warp_us);
    if (t0r == 0 || (rate >= 0.999 && rate <= 1.001)) return real_us;
    if (real_us <= t0r) return t0w;
    return t0w + (uint64_t)((double)(real_us - t0r) * rate);
}

void xrc_clock_warp_reset(void) {
    uint64_t real_now = xrc_real_now_us();
    uint64_t warp_now = s_compute_warp_us(real_now);
    atomic_store(&s_t0_real_us, real_now);
    atomic_store(&s_t0_warp_us, warp_now);
    // 单调钟通道同步重锚
    if (xrc_clock_orig_mach_absolute_time) {
        uint64_t mt = xrc_clock_orig_mach_absolute_time();
        atomic_store(&s_mt0_real_ticks, mt);
        atomic_store(&s_mt0_warp_ticks, s_compute_warp_ticks(mt));
    }
    // now_ms 通道同步重锚（谱面钟）
    {
        uint64_t ms = s_ms_now();
        atomic_store(&s_ms_t0_real, ms);
        atomic_store(&s_ms_t0_warp, ms);
    }
}

void xrc_clock_set_rate(double rate) {
    if (rate <= 0.001) { xrc_logd(XRCLC_BOOT, @"clock rate rejected: %.4f", rate); return; }
    xrc_clock_warp_reset();
    atomic_store(&s_rate_x1000, (uint32_t)(rate * 1000.0 + 0.5));
}

void xrc_clock_freeze_inc(void) {
    int32_t prev = atomic_fetch_add(&s_freeze_count, 1);
    xrc_logd(XRCLC_BOOT, @"[clock] freeze inc %d→%d", prev, prev + 1);
    if (prev == 0) {
        atomic_store(&s_frozen_us, s_compute_warp_us(xrc_real_now_us()));
        if (xrc_clock_orig_mach_absolute_time)
            atomic_store(&s_mfrozen_ticks, s_compute_warp_ticks(xrc_clock_orig_mach_absolute_time()));
        atomic_store(&s_ms_frozen, s_ms_now());
    }
}

void xrc_clock_freeze_dec(void) {
    int32_t prev = atomic_fetch_sub(&s_freeze_count, 1);
    if (prev <= 0) {
        atomic_store(&s_freeze_count, 0);
        xrc_logd(XRCLC_BOOT, @"[clock] freeze dec %d→0（未配对，已夹紧）", prev);
        return;
    }
    xrc_logd(XRCLC_BOOT, @"[clock] freeze dec %d→%d", prev, prev - 1);
    if (prev == 1) {
        uint64_t real_now = xrc_real_now_us();
        uint64_t frozen = atomic_load(&s_frozen_us);
        atomic_store(&s_t0_real_us, real_now);
        atomic_store(&s_t0_warp_us, frozen ? frozen : real_now);
        if (xrc_clock_orig_mach_absolute_time) {
            uint64_t mt = xrc_clock_orig_mach_absolute_time();
            uint64_t mf = atomic_load(&s_mfrozen_ticks);
            atomic_store(&s_mt0_real_ticks, mt);
            atomic_store(&s_mt0_warp_ticks, mf ? mf : mt);
        }
        {
            uint64_t ms = s_ms_now();
            uint64_t mf = atomic_load(&s_ms_frozen);
            atomic_store(&s_ms_t0_real, ms);
            atomic_store(&s_ms_t0_warp, mf ? mf : ms);
        }
    }
}

int32_t xrc_clock_freeze_count(void) {
    return atomic_load(&s_freeze_count);
}

int xrc_clock_gettimeofday(struct timeval *tv, void *tz) {
    if (!tv) return xrc_clock_orig_gettimeofday ? xrc_clock_orig_gettimeofday(tv, tz) : gettimeofday(tv, tz);
    int r = xrc_clock_orig_gettimeofday ? xrc_clock_orig_gettimeofday(tv, tz) : gettimeofday(tv, tz);
    if (r != 0) return r;
    uint64_t real_us = (uint64_t)tv->tv_sec * 1000000ULL + (uint64_t)tv->tv_usec;
    uint64_t warp_us;
    if (atomic_load(&s_freeze_count) > 0) {
        uint64_t f = atomic_load(&s_frozen_us);
        warp_us = f ? f : real_us;
    } else {
        warp_us = s_compute_warp_us(real_us);
    }
    if (warp_us == real_us) return r;
    tv->tv_sec  = (time_t)(warp_us / 1000000ULL);
    tv->tv_usec = (suseconds_t)(warp_us % 1000000ULL);
    return r;
}
