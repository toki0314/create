// © 雾月星辰 & MLXC · github@XingChenRS
// XRCClock.h — 时间基准：真实时间单一实现 + warp 计算 + freeze。
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/time.h>

// 唯一真实时间实现。返回值 0 表示失败。
uint64_t xrc_real_now_us(void);

// 时间 warp：t0 重设（换速/解冻时由调用方决定语义）。
void xrc_clock_warp_reset(void);
void xrc_clock_set_rate(double rate);
double xrc_clock_get_rate(void);

// freeze 计数（>0 时 warp 冻结在 frozen_us）。
void xrc_clock_freeze_inc(void);
void xrc_clock_freeze_dec(void);
int32_t xrc_clock_freeze_count(void);

// fishhook 入口（gettimeofday 拦截），供 Tweak.x 注册。
int xrc_clock_gettimeofday(struct timeval *tv, void *tz);
// 原 gettimeofday（fishhook 保存），XRCGameplay 的 retime 用。
extern int (*xrc_clock_orig_gettimeofday)(struct timeval *, void *);

// 单调钟 warp 通道（6.8 shell / 4.3.0：谱面钟走单调钟，不走 gettimeofday）。
// mach_absolute_time(ticks) / clock_gettime(CLOCK_MONOTONIC) / chrono steady_clock::now(ns)
// 三个入口共用同一套 ticks 域 warp 与 freeze。
uint64_t xrc_clock_mach_absolute_time(void);
int      xrc_clock_clock_gettime(int clk_id, struct timespec *tp);
uint64_t xrc_clock_steady_now(void);
extern uint64_t (*xrc_clock_orig_mach_absolute_time)(void);
extern int      (*xrc_clock_orig_clock_gettime)(int, struct timespec *);
extern uint64_t (*xrc_clock_orig_steady_now)(void);

// now_ms 域 warp（BRK 站点 time_now 返回钩用）：对游戏的毫秒时间值做同 rate 扭曲。
uint64_t xrc_clock_warp_ms(uint64_t ms);
