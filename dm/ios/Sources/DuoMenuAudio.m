// 設定音效獨立於客體混音器；客體暫停後才播放，繼續前先停止。
// Settings audio is independent of the guest mixer; start after guest pause and stop before resume.
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#import "duo_shell.h"

@interface DuoMenuAudio : NSObject
@property (nonatomic) BOOL open, interrupted;
@property (nonatomic, strong) AVAudioPlayer *music;
@property (nonatomic, strong) NSMutableDictionary<NSString *, AVAudioPlayer *> *effects;
@end

@implementation DuoMenuAudio
- (instancetype)init {
    if ((self = [super init])) {
        _effects = [NSMutableDictionary dictionary];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(inactive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(active:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
    }
    return self;
}
- (AVAudioPlayer *)load:(NSString *)role {
    NSString *path = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[NSString stringWithFormat:@"duo/menu_%@.wav", role]];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSError *error = nil;
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&error];
    if (!player) fprintf(stderr, "【紅】duo: menu audio: %s\n", error.localizedDescription.UTF8String);
    [player prepareToPlay];
    return player;
}
- (BOOL)canPlay { return _open && !_interrupted && UIApplication.sharedApplication.applicationState == UIApplicationStateActive; }
- (void)update {
    if (!self.canPlay || [NSUserDefaults.standardUserDefaults boolForKey:@"MenuMusicMuted"]) { [_music stop]; return; }
    if (!_music) { _music = [self load:@"music"]; _music.numberOfLoops = -1; }
    if (!_music) return;
    if (!_music.playing) {
        NSError *error = nil;
        if (![AVAudioSession.sharedInstance setActive:YES error:&error]) {
            fprintf(stderr, "【紅】duo: menu audio session: %s\n", error.localizedDescription.UTF8String); return;
        }
        _music.volume = 0; [_music play]; [_music setVolume:0.55 fadeDuration:0.010];
    }
}
- (void)stop {
    [_music stop];
    for (AVAudioPlayer *p in _effects.allValues) [p stop];
}
- (void)inactive:(NSNotification *)note { (void)note; [self stop]; }
- (void)active:(NSNotification *)note { (void)note; [self update]; }
- (void)interruption:(NSNotification *)note {
    // 音頻通知不保證在主線程；與 HOME 及生命週期在同一條佇列處理。
    // Audio notifications need not use the main thread; serialize with HOME and lifecycle events.
    NSDictionary *info = note.userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
            self.interrupted = YES; [self stop];
        } else {
            self.interrupted = NO;
            if ([info[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume) [self update];
        }
    });
}
@end

static DuoMenuAudio *menu_audio(void) {
    static DuoMenuAudio *audio; static dispatch_once_t once;
    dispatch_once(&once, ^{ audio = [DuoMenuAudio new]; });
    return audio;
}
void duo_menu_audio_open(BOOL open) {
    DuoMenuAudio *a = menu_audio(); a.open = open;
    if (open) [a update]; else [a stop];
}
void duo_menu_audio_refresh(void) {
    DuoMenuAudio *a = menu_audio();
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"MenuSoundsMuted"]) for (AVAudioPlayer *p in a.effects.allValues) [p stop];
    [a update];
}
void duo_menu_audio_effect(NSString *role) {
    DuoMenuAudio *a = menu_audio();
    if (!a.canPlay || [NSUserDefaults.standardUserDefaults boolForKey:@"MenuSoundsMuted"]) return;
    AVAudioPlayer *p = a.effects[role];
    if (!p) { p = [a load:role]; if (p) a.effects[role] = p; }
    p.currentTime = 0; p.volume = 0.65; [p play];
}
void duo_menu_audio_close(void (^completion)(void)) {
    DuoMenuAudio *a = menu_audio(); a.open = NO;
    // 只用 10 毫秒收邊；先完全靜音，才讓客體繼續，絕不交叉淡化。
    // Use only 10 ms to soften the cut; reach silence before guest resume, never crossfade.
    [a.music setVolume:0 fadeDuration:0.010];
    for (AVAudioPlayer *p in a.effects.allValues) [p setVolume:0 fadeDuration:0.010];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [a stop];
        if (completion) completion();
    });
}
