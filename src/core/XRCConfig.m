// © 雾月星辰 & MLXC · github@XingChenRS
// XRCConfig.m — 配置 plist 读写 + judge 参数。

#import "XRCConfig.h"

static NSString *s_legacy_pref_path(void) {
    // 早期版本的 preference 路径；侧载下仅作迁移源。
    return [NSString stringWithFormat:@"%@/Library/Preferences/moe.low.arc.xrcdemo.plist", NSHomeDirectory()];
}

NSString *xrc_config_path(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs) return nil;
    return [docs stringByAppendingPathComponent:@"xrcdemo.plist"];
}

static void s_migrate_legacy_if_needed(void) {
    NSString *cfg = xrc_config_path();
    if (!cfg || [[NSFileManager defaultManager] fileExistsAtPath:cfg]) return;
    NSMutableDictionary *old = [[NSMutableDictionary alloc] initWithContentsOfFile:s_legacy_pref_path()];
    if (!old || old.count == 0) return;
    [old writeToFile:cfg atomically:YES];
}

static void s_ensure_defaults(NSMutableDictionary *p) {
    if (!p[@"speedKeys"] || ![p[@"speedKeys"] count]) {
        p[@"speedKeys"] = [@[@"speed-1", @"speed-2", @"speed-3", @"speed-4", @"speed-5"] mutableCopy];
        p[@"speed-1"] = @1.00;
        p[@"speed-2"] = @0.80;
        p[@"speed-3"] = @0.60;
        p[@"speed-4"] = @1.25;
        p[@"speed-5"] = @1.50;
    }
    if (!p[@"buttonEnabled"]) p[@"buttonEnabled"] = @YES;
    if (!p[@"toast"])         p[@"toast"]         = @YES;
    if (!p[@"rateIndex"])     p[@"rateIndex"]     = @0;
    if (!p[@"judgeMaxMs"] && p[@"judgeWindowScale"]) {
        float sc = [p[@"judgeWindowScale"] floatValue];
        if (sc < 0.25f) sc = 0.25f;
        if (sc > 4.0f) sc = 4.0f;
        p[@"judgeMaxMs"]  = @((int)lround(25.0f * sc));
        p[@"judgePureMs"] = @((int)lround(50.0f * sc));
        p[@"judgeFarMs"]  = @((int)lround(100.0f * sc));
        p[@"judgeLostMs"] = @((int)lround(120.0f * sc));
    }
    if (!p[@"judgeMaxMs"])  p[@"judgeMaxMs"]  = @25;
    if (!p[@"judgePureMs"]) p[@"judgePureMs"] = @50;
    if (!p[@"judgeFarMs"])  p[@"judgeFarMs"]  = @100;
    if (!p[@"judgeLostMs"]) p[@"judgeLostMs"] = @120;
    // 私服接入：默认关闭；地址留空（面板占位符给示例），需要时自行填写
    if (!p[@"netEnabled"]) p[@"netEnabled"] = @NO;
    if (!p[@"netBase"])    p[@"netBase"]    = @"";
    if (!p[@"netMatch"])   p[@"netMatch"]   = @"";
    // 开关组：默认全关（打开前先确认已了解风险——服务端成绩校验仍会拒）
    if (!p[@"unlockOwn"])  p[@"unlockOwn"]  = @NO;
    if (!p[@"unlockFv"])   p[@"unlockFv"]   = @NO;
    if (!p[@"unlockDo"])   p[@"unlockDo"]   = @NO;
    if (!p[@"gateOpen"])   p[@"gateOpen"]   = @NO;
    // 全条件放行 / 本地内容放行：默认关（源逻辑与 2026-09-28 教训见 XRCProfile.h 同名块）
    if (!p[@"unlockAll"])  p[@"unlockAll"]  = @NO;
    if (!p[@"dlReady"])    p[@"dlReady"]    = @NO;
    // cb 验证链开关：默认关(6.8 shell 适配期:cb 站点尚未重定位,开着可能破坏内容加载)
    if (!p[@"cbBypass"])   p[@"cbBypass"]   = @NO;
    // 存储外置：默认关(6.8 shell 适配期:容器路径与 7.0 不同,外置可能搬坏 cb)
    if (!p[@"externalCb"]) p[@"externalCb"] = @NO;
    // 自动演奏：默认关闭(开启 = 全谱强制 Pure,练习外勿用)
    if (!p[@"autoplay"])   p[@"autoplay"]   = @NO;
    // 音乐变速：默认**开**（4.3.0 的 FMOD 入口已重定位；未定位时模块自行降级为磁带式/不动，不会崩）
    if (!p[@"speedAudio"]) p[@"speedAudio"] = @YES;
    // 回跳重播 / 观测桩轻量：默认关（观测桩轻量为开发构建专用）
    if (!p[@"replayArm"])  p[@"replayArm"]  = @NO;
    if (!p[@"stubsLite"])  p[@"stubsLite"]  = @NO;
    // 日志档位：缺省 INFO + 全部类别（面板可改，持久化到本 plist）
    if (!p[@"logLevel"])   p[@"logLevel"]   = @2;
    if (!p[@"logCats"])    p[@"logCats"]    = @0;
    // 面板位置（0 = 未设置 → 面板用默认位置）
    if (!p[@"panelX"])     p[@"panelX"]     = @0;
    if (!p[@"panelY"])     p[@"panelY"]     = @0;
}

NSMutableDictionary *xrc_config_dict(void) {
    s_migrate_legacy_if_needed();
    NSString *path = xrc_config_path();
    NSMutableDictionary *p = path ? [[NSMutableDictionary alloc] initWithContentsOfFile:path] : nil;
    if (!p) p = [NSMutableDictionary new];
    s_ensure_defaults(p);
    return p;
}

void xrc_config_write_dict(NSDictionary *d) {
    NSString *path = xrc_config_path();
    if (!path) return;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [d writeToFile:path atomically:YES];
}

void xrc_config_set_current_speed(float v) {
    NSMutableDictionary *p = xrc_config_dict();
    NSArray *keys = p[@"speedKeys"];
    NSInteger idx = [p[@"rateIndex"] integerValue];
    if (!keys || idx < 0 || idx >= (NSInteger)keys.count) return;
    p[keys[idx]] = @(v);
    xrc_config_write_dict(p);
}

void xrc_config_normalize_judge(xrc_config_t *c) {
    if (c->judge_max_ms < 1) c->judge_max_ms = 1;
    if (c->judge_max_ms > 2000) c->judge_max_ms = 2000;
    if (c->judge_pure_ms <= c->judge_max_ms) c->judge_pure_ms = c->judge_max_ms + 1;
    if (c->judge_pure_ms > 2000) c->judge_pure_ms = 2000;
    if (c->judge_far_ms <= c->judge_pure_ms) c->judge_far_ms = c->judge_pure_ms + 1;
    if (c->judge_far_ms > 2000) c->judge_far_ms = 2000;
    if (c->judge_lost_ms <= c->judge_far_ms) c->judge_lost_ms = c->judge_far_ms + 1;
    if (c->judge_lost_ms > 2000) c->judge_lost_ms = 2000;
}

void xrc_config_load(xrc_config_t *out) {
    if (!out) return;
    NSMutableDictionary *prefs = xrc_config_dict();
    out->toast          = [prefs[@"toast"] boolValue];
    out->button_enabled = [prefs[@"buttonEnabled"] boolValue];
    NSArray *speed_keys = prefs[@"speedKeys"];
    out->speed_count    = speed_keys.count;
    for (NSInteger i = 0; i < out->speed_count && i < 16; i++)
        out->speeds[i] = [prefs[speed_keys[i]] floatValue];
    out->rate_index     = [prefs[@"rateIndex"] integerValue];
    if (out->rate_index >= out->speed_count) out->rate_index = 0;
    out->judge_max_ms   = [prefs[@"judgeMaxMs"] intValue];
    out->judge_pure_ms  = [prefs[@"judgePureMs"] intValue];
    out->judge_far_ms   = [prefs[@"judgeFarMs"] intValue];
    out->judge_lost_ms  = [prefs[@"judgeLostMs"] intValue];
    xrc_config_normalize_judge(out);
    out->net_enabled    = [prefs[@"netEnabled"] boolValue];
    out->net_base       = [prefs[@"netBase"] length] ? prefs[@"netBase"] : nil;
    out->net_match      = [prefs[@"netMatch"] length] ? prefs[@"netMatch"] : nil;
    out->unlock_own     = [prefs[@"unlockOwn"] boolValue];
    out->unlock_fv      = [prefs[@"unlockFv"] boolValue];
    out->unlock_do      = [prefs[@"unlockDo"] boolValue];
    out->gate_open      = [prefs[@"gateOpen"] boolValue];
    out->unlock_all     = [prefs[@"unlockAll"] boolValue];
    out->dl_ready       = [prefs[@"dlReady"] boolValue];
    // 以下各项缺省由 s_ensure_defaults 单点提供（dict 里必有键）——load 直读，无需重复兜底
    out->cb_bypass      = [prefs[@"cbBypass"] boolValue];
    out->external_cb    = [prefs[@"externalCb"] boolValue];
    out->autoplay       = [prefs[@"autoplay"] boolValue];
    out->speed_audio    = [prefs[@"speedAudio"] boolValue];
    out->replay_arm     = [prefs[@"replayArm"] boolValue];
    out->stubs_lite     = [prefs[@"stubsLite"] boolValue];
    out->log_level      = [prefs[@"logLevel"] intValue];
    out->log_cats       = [prefs[@"logCats"] intValue];
}

void xrc_config_save(const xrc_config_t *c) {
    if (!c) return;
    NSMutableDictionary *p = xrc_config_dict();
    p[@"toast"]         = @(c->toast);
    p[@"buttonEnabled"] = @(c->button_enabled);
    p[@"rateIndex"]     = @(c->rate_index);
    p[@"judgeMaxMs"]    = @(c->judge_max_ms);
    p[@"judgePureMs"]   = @(c->judge_pure_ms);
    p[@"judgeFarMs"]    = @(c->judge_far_ms);
    p[@"judgeLostMs"]   = @(c->judge_lost_ms);
    p[@"netEnabled"]    = @(c->net_enabled);
    p[@"netBase"]       = c->net_base ?: @"";
    p[@"netMatch"]      = c->net_match ?: @"";
    p[@"unlockOwn"]     = @(c->unlock_own);
    p[@"unlockFv"]      = @(c->unlock_fv);
    p[@"unlockDo"]      = @(c->unlock_do);
    p[@"gateOpen"]      = @(c->gate_open);
    p[@"unlockAll"]     = @(c->unlock_all);
    p[@"dlReady"]       = @(c->dl_ready);
    p[@"cbBypass"]      = @(c->cb_bypass);
    p[@"externalCb"]    = @(c->external_cb);
    p[@"autoplay"]      = @(c->autoplay);
    p[@"speedAudio"]    = @(c->speed_audio);
    p[@"replayArm"]     = @(c->replay_arm);
    p[@"stubsLite"]     = @(c->stubs_lite);
    p[@"logLevel"]      = @(c->log_level);
    p[@"logCats"]       = @(c->log_cats);
    xrc_config_write_dict(p);
}
