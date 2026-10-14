// © 雾月星辰 & MLXC · github@XingChenRS
// XRCAudio.m — 音乐变速实现。设计与依据见 XRCAudio.h 顶部。
//
// 调用纪律：所有 FMOD 调用都先判空（入口未解析 / system 未就绪 / 播放器未创建都可能发生），
// 失败一律记日志并保持"至少速度跟上"的降级行为，绝不抛给调用方。
#import "XRCAudio.h"
#include "XRCLog.h"
#include "XRCProfile.h"
#include "XRCClock.h"
#include "XRCPlayer.h"

#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

extern uint64_t xrc_image_base(void);

// ---------------- FMOD 入口（偏移见 XRCProfile.h） ----------------
typedef int32_t (*fmod_cc_set_pitch_t)(void *cc, float pitch);
typedef int32_t (*fmod_cc_get_pitch_t)(void *cc, float *pitch);
typedef int32_t (*fmod_cc_add_dsp_t)(void *cc, int32_t index, void *dsp);
typedef int32_t (*fmod_create_dsp_t)(uint64_t system, int32_t type, void **dsp);
typedef int32_t (*fmod_dsp_set_f_t)(void *dsp, int32_t index, float value);
typedef int32_t (*fmod_dsp_get_f_t)(void *dsp, int32_t index, float *value, char *valuestr, int32_t valuestrlen);
// ⚠ FMOD 2.x 的 C API：name 是**调用者给的缓冲区**（内层 strlcpy(name, …, 32)），不是 char**
typedef int32_t (*fmod_dsp_info_t)(void *dsp, char *name, uint32_t *version,
                                   int32_t *channels, int32_t *confw, int32_t *confh);
typedef int32_t (*fmod_dsp_release_t)(void *dsp);
typedef int32_t (*fmod_ch_getpos_t)(void *ch, uint32_t *pos, uint32_t unit);
typedef int32_t (*fmod_ch_setpos_t)(void *ch, uint32_t pos, uint32_t unit);

static fmod_cc_set_pitch_t p_set_pitch;
static fmod_cc_add_dsp_t   p_add_dsp;
static fmod_create_dsp_t   p_create_dsp;
static fmod_dsp_set_f_t    p_dsp_set;
static fmod_dsp_get_f_t    p_dsp_get;
static fmod_dsp_info_t     p_dsp_info;
static fmod_dsp_release_t  p_dsp_release;
static fmod_ch_getpos_t    p_ch_getpos;
static fmod_ch_setpos_t    p_ch_setpos;

static void s_resolve(void) {
    static atomic_int done;
    if (atomic_exchange(&done, 1)) return;
    uint64_t mb = xrc_image_base();
    if (!mb) return;
    // 偏移 0 = 未重定位（4.3.0）：保持 NULL，调用点据此降级。
    if (XRC_OFF_FMOD_CC_SET_PITCH)        p_set_pitch   = (fmod_cc_set_pitch_t)(mb + XRC_OFF_FMOD_CC_SET_PITCH);
    if (XRC_OFF_FMOD_CC_ADD_DSP)          p_add_dsp     = (fmod_cc_add_dsp_t)  (mb + XRC_OFF_FMOD_CC_ADD_DSP);
    if (XRC_OFF_FMOD_CREATE_DSP_BY_TYPE)  p_create_dsp  = (fmod_create_dsp_t)  (mb + XRC_OFF_FMOD_CREATE_DSP_BY_TYPE);
    if (XRC_OFF_FMOD_DSP_SET_PARAM_FLOAT) p_dsp_set     = (fmod_dsp_set_f_t)   (mb + XRC_OFF_FMOD_DSP_SET_PARAM_FLOAT);
    if (XRC_OFF_FMOD_DSP_GET_PARAM_FLOAT) p_dsp_get     = (fmod_dsp_get_f_t)   (mb + XRC_OFF_FMOD_DSP_GET_PARAM_FLOAT);
    if (XRC_OFF_FMOD_DSP_GET_INFO)        p_dsp_info    = (fmod_dsp_info_t)    (mb + XRC_OFF_FMOD_DSP_GET_INFO);
    if (XRC_OFF_FMOD_DSP_RELEASE)         p_dsp_release = (fmod_dsp_release_t) (mb + XRC_OFF_FMOD_DSP_RELEASE);
    if (XRC_OFF_CH_GET_POSITION)          p_ch_getpos   = (fmod_ch_getpos_t)   (mb + XRC_OFF_CH_GET_POSITION);
    if (XRC_OFF_CH_SET_POSITION)          p_ch_setpos   = (fmod_ch_setpos_t)   (mb + XRC_OFF_CH_SET_POSITION);
}

static BOOL s_ptr_ok(void *p) {
    uintptr_t v = (uintptr_t)p;
    return v > 0x100000000ULL && v < 0x800000000000ULL;
}

static uint64_t s_system(void) {
    uint64_t mb = xrc_image_base();
    if (!mb || !XRC_OFF_FMOD_SYSTEM_GLOBAL) return 0;
    uint64_t v = *(volatile uint64_t *)(uintptr_t)(mb + XRC_OFF_FMOD_SYSTEM_GLOBAL);
    return s_ptr_ok((void *)v) ? v : 0;
}

static void *s_bgm_group(void) {
    void *player = xrc_player_get();
    if (!player) return NULL;
    void *g = *(void **)((char *)player + XRC_PLAYER_BGM_GROUP_OFF);
    return s_ptr_ok(g) ? g : NULL;
}

static void *s_channel0(void) {
    void *player = xrc_player_get();
    if (!player) return NULL;
    char *tbl = *(char **)((char *)player + XRC_PLAYER_CHANNELS_OFF);
    if (!tbl) return NULL;
    void *c = *(void **)(tbl + XRC_CHANNEL_ENTRY_PTR_OFF);
    return s_ptr_ok(c) ? c : NULL;
}

// ---------------- 状态 ----------------
static void *s_dsp;
static void *s_dsp_group;          // DSP 当前挂在哪个组（换歌会换组）
static int   s_dsp_type;           // 探测到的内置移调 DSP 类型号（0 = 未找到）
static float s_dsp_lat_ms;         // 该 DSP 的固有延迟（由 FFTSIZE 参数换算）
static double s_applied_rate = 1.0;
static void *s_applied_group;
static uint32_t s_last_pos_ms;     // 位置回退检测（seek/retry 后要重新补偿）
static atomic_bool s_enabled = true;

void xrc_audio_speed_set_enabled(BOOL on) {
    bool prev = atomic_exchange(&s_enabled, (bool)on);
    if (prev && !on) xrc_audio_speed_apply(1.0);   // 关：立刻复位（DSP 留在链上，参数归 0 半音 = 全程透明）
}
BOOL xrc_audio_speed_enabled(void) { return atomic_load(&s_enabled) ? YES : NO; }

// 探测内置移调 DSP：枚举类型建出来 → getInfo 读名字含 "Pitch" 的那个（不写死类型号）
static void *s_make_pitch_dsp(void) {
    uint64_t sys = s_system();
    if (!sys || !p_create_dsp) return NULL;
    if (s_dsp_type) {
        void *d = NULL;
        return (p_create_dsp(sys, s_dsp_type, &d) == 0 && s_ptr_ok(d)) ? d : NULL;
    }
    for (int32_t t = 9; t <= 18; t++) {
        void *d = NULL;
        if (p_create_dsp(sys, t, &d) != 0 || !s_ptr_ok(d)) continue;
        char nm[64] = {0};                                      // getInfo 的 name 是缓冲区（最多写 32B）
        uint32_t ver = 0;
        int32_t nch = 0, cw = 0, chh = 0;                       // 其余四个出参也必须给真地址
        if (p_dsp_info && p_dsp_info(d, nm, &ver, &nch, &cw, &chh) == 0 && strstr(nm, "Pitch")) {
            s_dsp_type = t;
            float fft = 0; char vs[64] = {0};                   // getParameterFloat 是 5 参（valuestr 给真缓冲）
            if (p_dsp_get && p_dsp_get(d, 1, &fft, vs, (int32_t)sizeof(vs)) == 0 && fft > 0)
                s_dsp_lat_ms = fft / 48.0f;                     // fft/48000*1000
            xrc_logd(XRCLC_BOOT, @"[audio] 移调 DSP 命中：type=%d name=%s fft=%.0f lat=%.1fms",
                     t, nm, fft, s_dsp_lat_ms);
            return d;
        }
        if (p_dsp_release) p_dsp_release(d);
    }
    xrc_logw(XRCLC_BOOT, @"[audio] 未找到内置移调 DSP —— 音乐变速退化为磁带效应（音高随速度升降）");
    return NULL;
}

// 延迟补偿：把通道位置前移 rate·L（一次性；此后"内容位置"与"听到的声音"恒差 L）。
// 只在挂载/位置回退时做 —— 每次改速度都补会叠加偏移。
static void s_compensate(void *ch, double rate) {
    if (!ch || s_dsp_lat_ms <= 0.05f || !p_ch_getpos || !p_ch_setpos) return;
    uint32_t pos = 0;
    if (p_ch_getpos(ch, &pos, 1 /*FMOD_TIMEUNIT_MS*/) != 0) return;   // 拿不到就放弃补偿
    uint32_t bump = (uint32_t)(rate * (double)s_dsp_lat_ms + 0.5);
    if (bump) p_ch_setpos(ch, pos + bump, 1);
}

// 移调 DSP 的参数单位是**比率**（FMOD 2.x：0.5..2.0，默认 1.0 = 不改变音高；
// 0.5 = 低一个八度、2.0 = 高一个八度）；FMOD 1.x 的半音语义（−12..12）不适用。
// 本机 DSP 描述串是权威证据：
//   0x1013d7711  "Pitch value.  0.5 to 2.0.  Default = 1.0. 0.5 = one octave down,
//                 2.0 = one octave up.  1.0 does not change the pitch."
//   （同段还有 "FFT size" 0x1013d7787 / "Max channels" 0x1013d78df，
//    源文件串 fmod_dsp_pitchshift.cpp 0x1013d79a8，确系移调器无疑。）
// 所以要补的比率就是 1/rate，直接传即可；只在越出量程时截断并告警
// （量程对应 rate ∈ 0.5..2.0；配置档位 0.6..1.5，不会触发）。
static float s_pitch_ratio(double rate) {
    if (rate <= 0.0) return 1.0f;
    double r = 1.0 / rate;
    if (r > 2.0) { xrc_logw(XRCLC_BOOT, @"[audio] 移调量程外：rate=%.3f 需比率 %.3f，截到 2.0", rate, r); r = 2.0; }
    if (r < 0.5) { xrc_logw(XRCLC_BOOT, @"[audio] 移调量程外：rate=%.3f 需比率 %.3f，截到 0.5", rate, r); r = 0.5; }
    return (float)r;
}

void xrc_audio_speed_apply(double rate) {
    s_resolve();
    if (!p_set_pitch) return;
    if (!atomic_load(&s_enabled)) rate = 1.0;            // 关着：只保证音高复位，不跟随
    if (rate < 0.05) rate = 0.05;
    if (rate > 4.0) rate = 4.0;
    void *group = s_bgm_group();
    if (!group) return;                                  // 还没进对局 / 组还没建：无从下手

    int32_t rc_pitch = p_set_pitch(group, (float)rate);  // ① 音乐跟着速度走
    s_applied_rate = rate;
    s_applied_group = group;

    if (rate > 0.999 && rate < 1.001) {                  // 原速：移调参数必须是 **1.0（比率）**
        if (s_dsp && p_dsp_set) p_dsp_set(s_dsp, 0, 1.0f);
        xrc_logd(XRCLC_BOOT, @"[audio] 原速：setPitch=%.3f rc=%d，移调归 1.0", rate, rc_pitch);
        return;
    }
    if (!s_dsp) s_dsp = s_make_pitch_dsp();             // ② 音高补偿 DSP（按需建一次）
    if (!s_dsp) return;                                  // 退化：至少速度跟上了
    float pr = s_pitch_ratio(rate);
    int32_t rc_set = p_dsp_set ? p_dsp_set(s_dsp, 0, pr) : -1;
    if (s_dsp_group != group) {                          // 挂到当前 BGM 组（换歌会换组）
        int32_t rc = p_add_dsp ? p_add_dsp(group, 0, s_dsp) : -1;
        xrc_logd(XRCLC_BOOT, @"[audio] 移调 DSP 挂载：group=%p rc=%d rate=%.3f ratio=%.3f rc_set=%d lat=%.1fms rc_pitch=%d",
                 group, rc, rate, pr, rc_set, s_dsp_lat_ms, rc_pitch);
        s_dsp_group = group;
        s_compensate(s_channel0(), rate);                // ③ 延迟补偿
    } else {
        xrc_logd(XRCLC_BOOT, @"[audio] 变速 rate=%.3f ratio=%.3f rc_set=%d rc_pitch=%d",
                 rate, pr, rc_set, rc_pitch);
    }
}

void xrc_audio_speed_tick(void) {
    s_resolve();
    if (!p_set_pitch) return;
    if (!atomic_load(&s_enabled)) return;    // 关：set_enabled 已复位音高，这里不再动（也不补偿）
    void *group = s_bgm_group();
    double rate = xrc_clock_get_rate();

    // seek/retry 检测：位置回退 ⇒ 重新做一次延迟补偿（补偿是一次性偏移，会被 seek 冲掉）
    if (s_dsp && s_dsp_group && s_dsp_lat_ms > 0.05f) {
        void *ch = s_channel0();
        uint32_t pos = 0;
        if (ch && p_ch_getpos && p_ch_getpos(ch, &pos, 1) == 0) {
            if (pos + 500 < s_last_pos_ms) s_compensate(ch, rate);
            s_last_pos_ms = pos;
        }
    }
    if (rate == s_applied_rate && group == s_applied_group) return;   // 去重：每帧只做一次比较
    xrc_audio_speed_apply(rate);
}

NSString *xrc_audio_speed_status(void) {
    void *group = s_bgm_group();
    return [NSString stringWithFormat:@"音乐变速：%s ｜ rate %.2f ｜ 组%@ ｜ 移调 DSP %@",
            (group ? "就绪" : "待进对局"),
            xrc_clock_get_rate(),
            group ? @"✓" : @"—",
            s_dsp ? [NSString stringWithFormat:@"✓(type=%d lat=%.0fms)", s_dsp_type, s_dsp_lat_ms]
                  : (s_dsp_type == 0 && group ? @"未找到" : @"未挂")];
}
