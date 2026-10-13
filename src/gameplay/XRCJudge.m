// © 雾月星辰 & MLXC · github@XingChenRS
// XRCJudge.m — 改判：静态桩（trampoline v2）+ dylib 完全接管 handler。
//
// 判定核 sub_10091E684（7.0.255，image base 0x100000000）逐条语义见
// 逆向笔记 §1/§4。
// 本文件是该语义的 C 复刻——**每一条出口都必须与反汇编一一对应**：
//
//   judge(note_group, note, ts):
//     if (note->vtable[64](note) & 1) return 0;      // 前置门 1
//     if (note->vtable[48](note) & 1) return 0;      // 前置门 2
//     w8  = *(int*)(note + 0x18);                    // note 时间
//     clk = *(void**)(note_group + 0x30);
//     分支 B（clk[45]==1）: w10=*(int*)(clk+0x20); w11=*(int*)(clk+0x28);
//                           delta=|w8-w10+w11|;  dir=(w10-w11>=w8)?2:1
//     分支 A:               w10=*(int*)(clk+0x34); lead=(w10>0)?0:3000;
//                           delta=|w8-w10+*(int*)(clk+0x28)+lead|;
//                           dir=((w10-*(int*)(clk+0x28))+(w10>0?0:-3000) >= w8)?2:1
//     delta <  T_pure → commit(grade 0, dir=0, judge_time=w4, input_time=ts) + fx[1](fx,note,0,dir); return 1
//     delta <  T_far  → commit(grade 1, dir,   judge_time=w4, input_time=ts) + fx[1](fx,note,1,dir); return 1
//     delta <  T_lost → commit(grade 2, dir,   judge_time=w4, input_time=ts) + fx[1](fx,note,2,dir); return 1
//     delta <= T_miss → commit_ln(ng+0x38, note, w4) + fx[0](fx,note);                              return 1
//     else                                                                                          return 0
//
// 记分对象 = *(ng+0x38)，特效对象 = *(ng+0x40)（调用时现场读取，不缓存）。
// commit = sub_100ACB880（6 参）。
// ⚠ commit 实参序（对 7.0 出口汇编逐条复核 + 外部参考实现 autoplay/on_miss 实参交叉验证）：
//   commit(stats, note, grade, dir, judge_time = w4（现算时钟值 = cur−base±lead）,
//          input_time = 入口 X2（ts；合成/无输入时 = −1）)
//   实证：游戏纯出口 0x10091E790 `W2=0; W3=0; X4=w4; X5=X21(入口X2)`；远/失出口同构；
//        外部参考实现 on_miss 强制 Pure 直调同样为 (…, 0, dir', judge_time, -1)。
// commit_ln = sub_100ACB6A4(3 参，首指令是 note->vtable[56](note, 1) 门)。
// 时间基：delta 用 note+0x18 与时钟现算；judge_time = w4。
//
// 约束：不写任何 __TEXT；出口逐条对齐；参数按 trampoline v2 契约（X3=X6）。

#import <Foundation/Foundation.h>
#import "XRCLog.h"    // xrc_log
#include "XRCJudge.h"
#include "XRCProfile.h"
#include "XRCRuntime.h"
#include "xrc_abi.h"

// 阈值/自动演奏开关：**必须在条件块外声明**——set_windows/get_windows/set_autoplay
// 无条件编译并引用它们（XRC_HAS_JUDGE_STUB=0 时亦然）。
static _Atomic(int)  s_th[4] = {25, 50, 100, 120};
static _Atomic(bool) s_autoplay = false;   // 开：一切判定强制 Pure（含漏扫 ts=-1）

#if XRC_HAS_JUDGE_STUB
extern uint64_t xrc_image_base(void);   // Tweak.x 提供

typedef uint64_t (*xrc_fn1_t)(uint64_t);                      // 前置门（note 单参）
typedef void (*xrc_fx0_t)(uint64_t, uint64_t);                // 特效 vtable[0](fx, note)
typedef void (*xrc_fx1_t)(uint64_t, uint64_t, uint64_t, uint64_t);  // vtable[1](fx,note,grade,dir)
typedef uint64_t (*xrc_commit_t)(uint64_t, uint64_t, uint64_t, uint64_t,
                                 uint64_t, uint64_t);         // sub_100ACB880
typedef uint64_t (*xrc_commit_ln_t)(uint64_t, uint64_t, uint64_t);  // sub_100ACB6A4

static xrc_commit_t    s_commit    = NULL;   // = image_base + XRC_OFF_JUDGE_COMMIT_FN
static xrc_commit_ln_t s_commit_ln = NULL;   // = image_base + XRC_OFF_JUDGE_COMMIT_LN_FN

static _Atomic(uint32_t) s_call_total = 0;
static _Atomic(uint32_t) s_stat_pure = 0, s_stat_far = 0, s_stat_lost = 0,
                         s_stat_ln = 0, s_stat_miss = 0, s_stat_gated = 0;

static inline uint64_t rd64(uint64_t a) { return *(const uint64_t *)a; }
static inline int32_t  rd32(uint64_t a) { return *(const int32_t *)a; }
static inline uint8_t  rd8(uint64_t a)  { return *(const uint8_t *)a; }

// 判定核 handler（trampoline v2 契约：X0=ng, X1=note, X2=ts, X3=caller X6）
static uint64_t s_xrc_judge_handler(uint64_t ng, uint64_t note, int64_t ts, uint64_t a6) {
    uint32_t n = atomic_fetch_add(&s_call_total, 1);
    if (!ng || !note) { atomic_fetch_add(&s_stat_gated, 1); return 0; }

    // ---- 1. 前置门（与反汇编 loc_10091E6B4/E6C8 一致）----
    uint64_t vt = rd64(note);
    if (vt) {
        uint64_t f64 = rd64(vt + 0x40);            // vtable[64]：(result & 1) → 提前 0
        if (f64 && (((xrc_fn1_t)f64)(note) & 1)) {
            atomic_fetch_add(&s_stat_gated, 1);
            return 0;
        }
        // 门2（vtable 槽 6）：TBZ W0,#0 → bit0==0 继续判定；bit0==1 → return 0。
        // 极性注意：bit0==1 → return 0；写反会拒掉所有可判音符。
        uint64_t f48 = rd64(vt + 0x30);
        if (f48 && (((xrc_fn1_t)f48)(note) & 1)) {
            atomic_fetch_add(&s_stat_gated, 1);
            return 0;
        }
    }

    // ---- 2. 时间差 / 方向 ----
    int32_t note_ms = rd32(note + XRC_NOTE_TIME_OFF);
    uint64_t clk = rd64(ng + XRC_CLOCK_IN_NOTEGROUP_OFF);
    if (!clk) { atomic_fetch_add(&s_stat_gated, 1); return 0; }
    int32_t delta, dir, w4;   // w4 = 现算时钟值（= commit 的 judge_time）
    uint32_t dirv;   // LN 落账的第 3 参：原始比较值（不是 1/2），零扩展 32 位
    if (rd8(clk + XRC_CLK_FLAG45_OFF) == 1) {
        int32_t cur = rd32(clk + XRC_CLK_ALT_START_OFF);   // [clk+32]
        int32_t base = rd32(clk + XRC_CLK_BASE_OFF);       // [clk+40]
        int32_t d = note_ms - cur + base;
        delta = d < 0 ? -d : d;
        w4 = cur - base;                                   // SUB W4,W10,W11（=judge_time）
        dirv = (uint32_t)w4;
        dir = (w4 >= note_ms) ? 2 : 1;
    } else {
        int32_t cur = rd32(clk + XRC_CLK_CUR_OFF);         // [clk+52]
        int32_t base = rd32(clk + XRC_CLK_BASE_OFF);
        int32_t lead = cur > 0 ? 0 : -XRC_CLK_NEG_LEAD_MS; // +3000（delta 用）
        int32_t d = note_ms - cur + base + lead;
        delta = d < 0 ? -d : d;
        int32_t lead2 = cur > 0 ? 0 : XRC_CLK_NEG_LEAD_MS; // -3000（dir 用）
        w4 = (cur - base) + lead2;                         // （=judge_time）
        dirv = (uint32_t)w4;
        dir = (w4 >= note_ms) ? 2 : 1;
    }

    // ---- 2.5 自动演奏（autoplay）：一切判定（含漏扫 ts=-1）强制 Pure ----
    // 关键事实（静态实证）：未被触摸的音符由漏扫 sub_10091F688 在
    // note时间+120ms 处以 ts=-1 直调判定核 —— 亦即同样流经本 handler。
    // 参数按 外部参考实现强制 Pure 配方（离线样本实参交叉验证）：
    //   commit(stats, note, grade=0, dir=0, judge_time=音符自身时间, input_time=-1)
    //   · judge_time 用 note+0x18：判定落在"精确命中"时刻（门必过、视觉时序正确）
    //   · input_time = -1 = 合成输入哨兵（外部参考实现与 Android kInputTimeSynth 逐值一致）
    if (atomic_load(&s_autoplay)) {
        xrc_judge_autoplay_pure(ng, note, note_ms);
        return 1;
    }

    // ---- 3. 出口（阈值运行时读；调用对象现场读取）----
    int t_pure = atomic_load(&s_th[0]);
    int t_far  = atomic_load(&s_th[1]);
    int t_lost = atomic_load(&s_th[2]);
    int t_miss = atomic_load(&s_th[3]);

    int grade = -1;
    if (delta < t_pure)      grade = 0;
    else if (delta < t_far)  grade = 1;
    else if (delta < t_lost) grade = 2;
    else if (delta <= t_miss) grade = 3;   // LN/近失落账路径（非 Miss）

    if (grade == 3) {
        // loc_10091E850：commit_ln(*(ng+0x38), note, w4) + fx[0](fx, note)
        // w4 = 原始比较值（零扩展），不是 1/2 —— 见笔记 §1.2。
        uint64_t stats = rd64(ng + XRC_OFF_JUDGE_COMMIT_OBJ);
        uint64_t fx    = rd64(ng + XRC_OFF_JUDGE_FX_OBJ);
        if (s_commit_ln && stats) s_commit_ln(stats, note, (uint64_t)dirv);
        if (fx) {
            uint64_t f0 = rd64(rd64(fx));       // vtable[0](fx, note)：无 grade/dir
            if (f0) ((xrc_fx0_t)f0)(fx, note);
        }
        atomic_fetch_add(&s_stat_ln, 1);
        return 1;
    }
    if (grade >= 0) {
        // loc_10091E790/E7D4/E818：commit(*(ng+0x38), note, grade, dir, ts, a6)
        //                          + fx[1](fx, note, grade, dir); return 1
        uint64_t stats = rd64(ng + XRC_OFF_JUDGE_COMMIT_OBJ);
        uint64_t fx    = rd64(ng + XRC_OFF_JUDGE_FX_OBJ);
        // commit 第 4 参：Pure 恒 0，Far/Lost 传 dir（照抄 10091e79c / e7e4 / e824）。
        // 第 5/6 参：judge_time = w4（现算时钟值）、input_time = 入口 X2。
        uint64_t a4 = (grade == 0) ? 0 : (uint64_t)(uint32_t)dir;
        if (s_commit && stats)
            s_commit(stats, note, (uint64_t)(uint32_t)grade, a4,
                     (uint64_t)(uint32_t)w4, (uint64_t)ts);
        if (fx) {
            uint64_t f1 = rd64(rd64(fx) + 8);   // vtable[1](fx, note, grade, dir)
            if (f1) ((xrc_fx1_t)f1)(fx, note, (uint64_t)(uint32_t)grade,
                                    (uint64_t)(uint32_t)dir);
        }
        if (grade == 0)      atomic_fetch_add(&s_stat_pure, 1);
        else if (grade == 1) atomic_fetch_add(&s_stat_far, 1);
        else                 atomic_fetch_add(&s_stat_lost, 1);
        if (n < 30)
            xrc_logd(XRCLC_JUDGE, @"[judge] #%u d=%d g=%d dir=%d th=%d/%d/%d/%d",
                     n, delta, grade, dir, t_pure, t_far, t_lost, t_miss);
        return 1;
    }

    // 超界 → Miss（原函数 return 0，不消费、不落账、无特效）
    atomic_fetch_add(&s_stat_miss, 1);
    if (n < 20)
        xrc_logd(XRCLC_JUDGE, @"[judge] #%u MISS passthru d=%d th=%d/%d/%d/%d",
                 n, delta, t_pure, t_far, t_lost, t_miss);
    return 0;
}

// 强制 Pure 落账 + 特效——自动演奏的统一出口（autoplay 站点处理器复用）。
// 配方出处（外部参考实现实件交叉验证）：
//   commit(stats, note, grade=0, dir=0, judge_time, input_time=-1)
//   · judge_time：调用方给定（判定核路径 = 音符自身时间；窗口站点 = 音符窗口时刻）
//   · input_time = -1 = 合成输入哨兵（外部参考实现与 Android kInputTimeSynth 逐值一致）
void xrc_judge_autoplay_pure(uint64_t ng, uint64_t note, int32_t judge_time) {
    uint64_t stats = rd64(ng + XRC_OFF_JUDGE_COMMIT_OBJ);
    uint64_t fx    = rd64(ng + XRC_OFF_JUDGE_FX_OBJ);
    if (s_commit && stats)
        s_commit(stats, note, 0 /*Pure*/, 0 /*dir*/,
                 (uint64_t)(uint32_t)judge_time, 0xFFFFFFFFULL /*input=-1*/);
    if (fx) {
        uint64_t f1 = rd64(rd64(fx) + 8);   // vtable[1](fx, note, grade, dir)
        if (f1) ((xrc_fx1_t)f1)(fx, note, 0, 0);
    }
    atomic_fetch_add(&s_stat_pure, 1);
}

void xrc_judge_log_stats(void) {
    xrc_logd(XRCLC_JUDGE, @"[judge] calls=%u pure=%u far=%u lost=%u ln=%u miss=%u gated=%u",
             atomic_load(&s_call_total), atomic_load(&s_stat_pure),
             atomic_load(&s_stat_far), atomic_load(&s_stat_lost),
             atomic_load(&s_stat_ln), atomic_load(&s_stat_miss),
             atomic_load(&s_stat_gated));
}
#endif

#if !XRC_HAS_JUDGE_STUB
// 未启用判定桩时提供空实现，保证 XRCHook.m 的 autoplay 站点处理器可链接。
void xrc_judge_autoplay_pure(uint64_t ng, uint64_t note, int32_t judge_time) {
    (void)ng; (void)note; (void)judge_time;
}
// Tweak.x 无条件调用基线统计——桩关闭时同样给空实现。
void xrc_judge_log_stats(void) {
}
#endif

static _Atomic(bool) s_judge_active = false;

bool xrc_judge_is_active(void) {
    return atomic_load(&s_judge_active);
}

bool xrc_judge_install(uint64_t image_base) {
#if XRC_HAS_JUDGE_STUB
    uint64_t slot_va = g_xrc.judge_slot;
    if (!slot_va) {
        xrc_logd(XRCLC_JUDGE, @"judge stub: slot anchor missing (stub not injected?)");
        return false;
    }
    // 落账/特效函数：绝对地址 = image_base + 静态偏移（thin 二进制无 slice 差）
    s_commit    = (xrc_commit_t)(image_base + XRC_OFF_JUDGE_COMMIT_FN);
    s_commit_ln = (xrc_commit_ln_t)(image_base + XRC_OFF_JUDGE_COMMIT_LN_FN);
    // 校验落账函数 prologue 特征（跨版本防护）：sub_100ACB880 首指令 LDR X8,[X0]
    // 后跟 vtable[32] 门；这里只做"非零 + 可读"的最低校验，避免误注册。
    if (!s_commit || !s_commit_ln) return false;

    struct xrc_slot *slot = (struct xrc_slot *)slot_va;
    slot->handler = (void *)&s_xrc_judge_handler;
    atomic_store(&s_judge_active, true);
    xrc_logd(XRCLC_JUDGE, @"judge handler installed: slot=%p commit=%p commit_ln=%p",
             (void *)slot, (void *)s_commit, (void *)s_commit_ln);
    return true;
#else
    (void)image_base;
    return false;
#endif
}

void xrc_judge_set_windows(int max_ms, int pure_ms, int far_ms, int lost_ms) {
    // UI 四档语义 → 判定级联阈值：
    //   Max  → Pure 上界（默认 25）
    //   Pure → Far  上界（默认 50）
    //   Far  → Lost 上界（默认 100）
    //   Lost → 近失/Miss 分界（默认 120）
    atomic_store(&s_th[0], max_ms);
    atomic_store(&s_th[1], pure_ms);
    atomic_store(&s_th[2], far_ms);
    atomic_store(&s_th[3], lost_ms);
}

void xrc_judge_get_windows(int *max_ms, int *pure_ms, int *far_ms, int *lost_ms) {
    if (max_ms)  *max_ms  = atomic_load(&s_th[0]);
    if (pure_ms) *pure_ms = atomic_load(&s_th[1]);
    if (far_ms)  *far_ms  = atomic_load(&s_th[2]);
    if (lost_ms) *lost_ms = atomic_load(&s_th[3]);
}

void xrc_judge_set_autoplay(bool on) { atomic_store(&s_autoplay, on); }
bool xrc_judge_autoplay(void)        { return atomic_load(&s_autoplay); }
