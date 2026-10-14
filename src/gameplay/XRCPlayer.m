// © 雾月星辰 & MLXC · github@XingChenRS
// XRCPlayer.m — 音频：registry/player/channel/进度/曲长（单一数据源）。
// 位置跟踪：hook 为唯一更新源；Tweak.x 轮询仅做兜底捕获。

#import <Foundation/Foundation.h>
#import "XRCLog.h"    // xrc_log
#include <limits.h>
#include "XRCPlayer.h"
#include "XRCGameplay.h"   // xrc_swizzle_vtable（同 dylib 内跨模块）
#include "XRCRuntime.h"
#include "XRCProfile.h"

typedef void *(*get_registry_fn)(void);
typedef int    (*get_current_sound_fn)(void *channel, void **outSound);
typedef int    (*get_sound_length_fn)(void *sound, uint32_t *outLen, int unit);
typedef int    (*ch_get_position_fn)(void *channel, uint32_t *out_ms, int unit);

static get_registry_fn      s_get_registry      = NULL;
static get_current_sound_fn s_get_current_sound = NULL;
static get_sound_length_fn  s_get_sound_length  = NULL;
static ch_get_position_fn   s_ch_get_position   = NULL;

static _Atomic(void *)   s_bgm_player  = NULL;
static _Atomic(uint32_t) s_last_pos_ms = 0;
static _Atomic(uint32_t) s_max_seen_ms = 0;
static _Atomic(uint32_t) s_song_len_ms = 0;
// 上次解出曲长用的是哪个 Sound。曲长按 Sound 缓存：换了 Sound（换歌）才重解。
static _Atomic(void *)   s_len_snd     = NULL;

// MTP getpos vtable hook（位置缓存唯一更新源）。7.0 单参 (self, channel)。
static uint32_t (*s_orig_mtp_getpos)(void *self, int channel) = NULL;

static uint32_t s_tw_mtp_getpos(void *self, int channel) {
    uint32_t raw = s_orig_mtp_getpos ? s_orig_mtp_getpos(self, channel) : 0;
    if (channel == 0)
        xrc_player_update_position(self, raw);
    return raw;
}

// ---- 安装（Tweak.x 引导时调用一次） ----
void xrc_player_install(uint64_t image_base) {
    if (g_xrc.mtp_vtable && g_xrc.mtp_getpos) {
        // 运行时锚点（info blob 重定位）优先
        int slot = xrc_swizzle_vtable(g_xrc.mtp_vtable,
                                      g_xrc.mtp_getpos - g_xrc.image_base,
                                      (void *)s_tw_mtp_getpos,
                                      (void **)&s_orig_mtp_getpos);
        if (slot != INT_MIN)
            xrc_logd(XRCLC_BOOT, @"mtp.getpos vtable installed slot=%d (runtime anchor)", slot);
    } else if (XRC_OFF_MTP_VTABLE != 0 && XRC_OFF_MTP_GETPOS != 0) {
        // 编译期 profile fallback。注：7.0.255 这两个常量恒非零 ⇒ 本分支恒成立
        //（"两条路都不可用"的 else 会被 clang 当死代码消掉，无需编写）。
        extern uint64_t xrc_image_base(void);
        int slot = xrc_swizzle_vtable(xrc_image_base() + XRC_OFF_MTP_VTABLE,
                                      XRC_OFF_MTP_GETPOS,
                                      (void *)s_tw_mtp_getpos,
                                      (void **)&s_orig_mtp_getpos);
        if (slot != INT_MIN)
            xrc_logd(XRCLC_BOOT, @"mtp.getpos vtable installed slot=%d (profile fallback)", slot);
    }
    if (XRC_OFF_CH_GET_POSITION)   s_ch_get_position   = (ch_get_position_fn)  (image_base + XRC_OFF_CH_GET_POSITION);
    if (XRC_OFF_GET_CURRENT_SOUND) s_get_current_sound = (get_current_sound_fn)(image_base + XRC_OFF_GET_CURRENT_SOUND);
    if (XRC_OFF_GET_SOUND_LENGTH)  s_get_sound_length  = (get_sound_length_fn) (image_base + XRC_OFF_GET_SOUND_LENGTH);
    if (XRC_OFF_GET_REGISTRY)      s_get_registry      = (get_registry_fn)     (image_base + XRC_OFF_GET_REGISTRY);
}

void *xrc_player_get(void) {
    void *p = atomic_load(&s_bgm_player);
    if (p) return p;
    if (!s_get_registry) return NULL;
    void *reg = s_get_registry();
    if (!reg) return NULL;
    void *mtp = *(void **)((char *)reg + XRC_REG_PLAYER_OFF);
    if (mtp) atomic_store(&s_bgm_player, mtp);
    return mtp;
}

// vtable hook（MTP getpos 槽）专用：更新缓存 + 换歌检测。
void xrc_player_update_position(void *self, uint32_t pos) {
    atomic_store(&s_bgm_player, self);
    atomic_store(&s_last_pos_ms, pos);
    uint32_t prev = atomic_load(&s_max_seen_ms);
    if (prev > 100 && pos < 100) {
        // 位置回退到开头 = 换歌 / 重开：曲长作废，等下次 tick 重新解
        atomic_store(&s_song_len_ms, 0);
        atomic_store(&s_len_snd, NULL);
        atomic_store(&s_max_seen_ms, pos);
        return;
    }
    // 取真正的最大值：先读 prev 再比较写回（若先 exchange 写入，比较将恒假）。
    if (pos > prev) atomic_store(&s_max_seen_ms, pos);
}

uint32_t xrc_player_song_length_ms(void) {
    uint32_t len = atomic_load(&s_song_len_ms);
    return len ? len : atomic_load(&s_max_seen_ms);
}

uint32_t xrc_player_position_ms(void) {
    return atomic_load(&s_last_pos_ms);
}

void xrc_player_try_capture_length(void *player) {
    if (!player) return;
    void *channels = *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF);
    if (!channels) return;
    void *ch0 = *(void **)((char *)channels + XRC_CHANNEL_ENTRY_PTR_OFF);
    if (!ch0) return;
    void *snd = NULL;
    if (!s_get_current_sound) return;
    if (s_get_current_sound(ch0, &snd) != 0 || !snd) return;
    // 判据用 Sound 身份（s_len_snd）：player/channels 指针跨歌不变，不能当换歌信号，
    // 否则曲长会停留在第一首歌。
    if (snd == atomic_load(&s_len_snd) && atomic_load(&s_song_len_ms) != 0) return;
    uint32_t len = 0;
    if (s_get_sound_length && s_get_sound_length(snd, &len, 1) == 0 &&
        len > 0 && len < 0x7FFFFFFFu) {
        atomic_store(&s_len_snd, snd);
        atomic_store(&s_song_len_ms, len);
        return;
    }
    // 静态 get_sound_length 未定位 → 运行时 vtable 尝试
    // （6.13 已验证 Sound 对象 vtable 槽 19 = getLength(sound, out, unit)）
    void **svt = *(void ***)snd;
    if (!svt) return;
    typedef int (*sound_len_fn)(void *, uint32_t *, int);
    sound_len_fn fn = (sound_len_fn)svt[19];
    if (fn && fn(snd, &len, 1) == 0 && len > 0 && len < 0x7FFFFFFFu) {
        atomic_store(&s_len_snd, snd);
        atomic_store(&s_song_len_ms, len);
    }
}

// 位置轮询兜底：channel 0 的 get_position（getpos hook 不频繁触发时的补充）
void xrc_player_poll_position(void *player) {
    if (!player || !s_ch_get_position) return;
    void *channels = *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF);
    if (!channels) return;
    void *ch0 = *(void **)((char *)channels + XRC_CHANNEL_ENTRY_PTR_OFF);
    if (!ch0) return;
    uint32_t pos = 0;
    if (s_ch_get_position(ch0, &pos, 1) == 0) {
        atomic_store(&s_last_pos_ms, pos);
        uint32_t prev = atomic_load(&s_max_seen_ms);
        if (pos > prev) atomic_store(&s_max_seen_ms, pos);
    }
}

bool xrc_player_detect_change(void *player) {
    static void *s_last_player = NULL;
    static void *s_last_channels = NULL;
    void *channels = player ? *(void **)((char *)player + XRC_PLAYER_CHANNELS_OFF) : NULL;
    if (player == s_last_player && channels == s_last_channels) return false;
    atomic_store(&s_song_len_ms, 0);
    atomic_store(&s_len_snd, NULL);
    atomic_store(&s_max_seen_ms, 0);
    atomic_store(&s_last_pos_ms, 0);
    s_last_player = player;
    s_last_channels = channels;
    return true;
}

bool xrc_player_seek_ms(void *self, uint32_t ms) {
    if (!self || XRC_PLAYER_SEEK_SLOT_OFF == 0) return false;   // 槽未重定位 ⇒ 禁用（槽 0 是析构器，会崩）
    typedef void (*seek_fn)(void *, uint32_t, int);
    void **vtable = *(void ***)self;
    if (!vtable) return false;
    seek_fn fn = (seek_fn)vtable[XRC_PLAYER_SEEK_SLOT_OFF / sizeof(void *)];
    if (!fn) return false;
    fn(self, ms, 0);
    return true;
}

// 暂停/恢复（冻结式 seek 的“静默”环节）。
// 链路出处：外部参考实现的 set_audio_paused（PRAC_16）→ 主程序 FMOD_Channel_SetPaused；
// 7.0 本地反汇编核对：MTP vtable 槽 6 即该 C-API 入口（本体 0x1010E2CCC：
// resolver 0x1010E846C → 对象 vt[+0x10]；内层实现 0x1010E84A0 与 6.13 该 28 字节逐字节相同）。
// index=0 ⇒ 默认通道 handle = *(mtp+0x18)（= mainBGMGroup 句柄，XRC_PLAYER_BGM_GROUP_OFF）。
bool xrc_player_pause(bool paused) {
    void *self = xrc_player_get();
    if (!self || XRC_PLAYER_PAUSE_SLOT_OFF == 0) return false;  // 槽未重定位 ⇒ 禁用（槽 0 是析构器，会崩）
    void **vtable = *(void ***)self;
    if (!vtable) return false;
    typedef int (*pause_fn)(void *, int, int);
    pause_fn fn = (pause_fn)vtable[XRC_PLAYER_PAUSE_SLOT_OFF / sizeof(void *)];
    if (!fn) return false;
    return fn(self, paused ? 1 : 0, 0) == 0;
}

// 暂停持有计数（多来源共用；单一实现在此，理由见头文件注释）。
static _Atomic(int) s_pause_holds = 0;
bool xrc_player_pause_hold(bool hold) {
    if (hold) {
        int prev = atomic_fetch_add(&s_pause_holds, 1);
        if (prev == 0) {
            bool ok = xrc_player_pause(true);
            if (!ok) atomic_fetch_sub(&s_pause_holds, 1);   /* 暂停失败：不虚占计数 */
            return ok;
        }
        return true;                                        /* 已暂停：计数即可 */
    }
    int prev = atomic_fetch_sub(&s_pause_holds, 1);
    if (prev <= 0) {                                        /* 未持有：无害空操作 */
        atomic_store(&s_pause_holds, 0);
        return false;
    }
    if (prev == 1) return xrc_player_pause(false);          /* 最后一个持有者：恢复 */
    return true;
}
