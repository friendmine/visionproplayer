#import "VPPVLCSession.h"
#import <VLCKit/vlc/vlc.h>
#import <os/lock.h>

// The callback context owns the pool and the latest frame. There is no unbounded frame queue.
@interface VPPFrameMailbox : NSObject {
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
}
@property (nonatomic) CVPixelBufferPoolRef pool;
@property (nonatomic) CVPixelBufferRef decodeBuffer;
- (void)publish:(CVPixelBufferRef)buffer;
- (CVPixelBufferRef)take CF_RETURNS_RETAINED;
@end
@implementation VPPFrameMailbox
- (instancetype)init { if ((self = [super init])) _lock = OS_UNFAIR_LOCK_INIT; return self; }
- (void)publish:(CVPixelBufferRef)buffer {
    CVPixelBufferRetain(buffer);
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef previous = _latest;
    _latest = buffer;
    os_unfair_lock_unlock(&_lock);
    if (previous) CVPixelBufferRelease(previous);
}
- (CVPixelBufferRef)take {
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef result = _latest;
    _latest = NULL;
    os_unfair_lock_unlock(&_lock);
    return result;
}
- (void)dealloc {
    if (_latest) CVPixelBufferRelease(_latest);
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_decodeBuffer) CVPixelBufferRelease(_decodeBuffer);
}
@end

static unsigned VPPSetup(void **opaque, char *chroma, unsigned *width, unsigned *height,
                         unsigned *pitches, unsigned *lines) {
    VPPFrameMailbox *mailbox = (__bridge VPPFrameMailbox *)*opaque;
    // This proof-of-concept deliberately requests SDR BGRA and caps CPU output at 1920 px.
    // This is not a zero-copy/HDR decoder path. Preserve packed-frame aspect during scaling.
    // libVLC 4 supplies [coded size, visible size]. Decoder padding must not
    // change the displayed aspect ratio (e.g. H.264 visible 360 vs padded 386).
    unsigned visibleWidth = width[1] ? width[1] : width[0];
    unsigned visibleHeight = height[1] ? height[1] : height[0];
    double scale = MIN(1.0, 1920.0 / MAX(visibleWidth, visibleHeight));
    *width = MAX(2, ((unsigned)(visibleWidth * scale) / 2) * 2);
    *height = MAX(2, ((unsigned)(visibleHeight * scale) / 2) * 2);
    memcpy(chroma, "BGRA", 4);
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(*width), (id)kCVPixelBufferHeightKey: @(*height),
        (id)kCVPixelBufferBytesPerRowAlignmentKey: @64,
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    CVPixelBufferPoolRef pool = NULL;
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attrs, &pool) != kCVReturnSuccess) return 0;
    CVPixelBufferRef probe = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(NULL, pool, &probe) != kCVReturnSuccess) {
        CVPixelBufferPoolRelease(pool); return 0;
    }
    pitches[0] = (unsigned)CVPixelBufferGetBytesPerRow(probe);
    lines[0] = *height;
    if (mailbox.decodeBuffer) CVPixelBufferRelease(mailbox.decodeBuffer);
    mailbox.decodeBuffer = probe;
    if (mailbox.pool) CVPixelBufferPoolRelease(mailbox.pool);
    mailbox.pool = pool;
    return 1;
}
static void VPPCleanup(void *opaque) {
    VPPFrameMailbox *mailbox = (__bridge VPPFrameMailbox *)opaque;
    if (mailbox.pool) { CVPixelBufferPoolRelease(mailbox.pool); mailbox.pool = NULL; }
    if (mailbox.decodeBuffer) { CVPixelBufferRelease(mailbox.decodeBuffer); mailbox.decodeBuffer = NULL; }
}
static void *VPPLock(void *opaque, void **planes) {
    VPPFrameMailbox *mailbox = (__bridge VPPFrameMailbox *)opaque;
    CVPixelBufferRef buffer = mailbox.decodeBuffer;
    CVPixelBufferLockBaseAddress(buffer, 0);
    planes[0] = CVPixelBufferGetBaseAddress(buffer);
    return buffer;
}
static void VPPUnlock(void *opaque, void *picture, void *const *planes) {
    CVPixelBufferUnlockBaseAddress((CVPixelBufferRef)picture, 0);
}
static void VPPDisplay(void *opaque, void *picture) {
    VPPFrameMailbox *mailbox = (__bridge VPPFrameMailbox *)opaque;
    // The decoder owns one reusable destination. Snapshot only at presentation time;
    // skipped frames allocate nothing and a slow consumer only retains the newest snapshot.
    CVPixelBufferRef snapshot = NULL;
    if (!mailbox.pool || CVPixelBufferPoolCreatePixelBuffer(NULL, mailbox.pool, &snapshot) != kCVReturnSuccess) return;
    CVPixelBufferRef source = (CVPixelBufferRef)picture;
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(snapshot, 0);
    size_t rowBytes = CVPixelBufferGetWidth(source) * 4;
    for (size_t row = 0; row < CVPixelBufferGetHeight(source); row++) {
        memcpy((uint8_t *)CVPixelBufferGetBaseAddress(snapshot) + row * CVPixelBufferGetBytesPerRow(snapshot),
               (uint8_t *)CVPixelBufferGetBaseAddress(source) + row * CVPixelBufferGetBytesPerRow(source), rowBytes);
    }
    CVPixelBufferUnlockBaseAddress(snapshot, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    [mailbox publish:snapshot];
    CVPixelBufferRelease(snapshot);
}
@interface VPPPlaybackEvents : NSObject
@property (nonatomic, strong) dispatch_semaphore_t stopped;
@property (atomic) BOOL failed;
@end
@implementation VPPPlaybackEvents
@end

static void VPPStateChanged(void *opaque, libvlc_state_t state) {
    VPPPlaybackEvents *events = (__bridge VPPPlaybackEvents *)opaque;
    if (state == libvlc_Error) events.failed = YES;
    if (state == libvlc_Stopped) {
        dispatch_semaphore_signal(events.stopped);
    }
}
static void VPPMediaStopping(void *opaque, libvlc_media_t *media, libvlc_stopping_reason_t reason) {
    // libVLC 4 may already be Stopped by the next UI poll. Keep the error until
    // an explicit retry; otherwise a missing/invalid file looks like normal EOF.
    if (reason == libvlc_stopping_reason_error) {
        ((__bridge VPPPlaybackEvents *)opaque).failed = YES;
    }
}
static const struct libvlc_media_player_cbs VPPCallbacks = {
    .version = 0,
    .on_state_changed = VPPStateChanged,
    .on_media_stopping = VPPMediaStopping,
};

@implementation VPPVLCSession {
    libvlc_instance_t *_instance;
    libvlc_media_player_t *_player;
    VPPFrameMailbox *_mailbox;
    UIView *_drawable;
    BOOL _closing;
    VPPPlaybackEvents *_events;
}
- (instancetype)initWithURL:(NSURL *)url stereo:(BOOL)stereo error:(NSError **)error {
    if (!(self = [super init])) return nil;
    const char *normal[] = {"--no-video-title-show", "--no-osd"};
    const char *sbs[] = {"--no-video-title-show", "--no-osd", "--avcodec-hw=none"};
    _instance = libvlc_new(stereo ? 3 : 2, stereo ? sbs : normal);
    _events = [VPPPlaybackEvents new];
    _events.stopped = dispatch_semaphore_create(0);
    if (_instance) _player = libvlc_media_player_new(_instance, &VPPCallbacks, (__bridge void *)_events);
    if (!_player) {
        if (error) *error = [NSError errorWithDomain:@"VisionPlayer.VLC" code:1 userInfo:@{NSLocalizedDescriptionKey:@"无法初始化 VLCKit"}];
        return nil;
    }
    libvlc_media_t *media = url.isFileURL ? libvlc_media_new_path(url.fileSystemRepresentation) : libvlc_media_new_location(url.absoluteString.UTF8String);
    if (!media) {
        if (error) *error = [NSError errorWithDomain:@"VisionPlayer.VLC" code:2 userInfo:@{NSLocalizedDescriptionKey:@"无法打开视频地址"}];
        return nil;
    }
    libvlc_media_player_set_media(_player, media);
    libvlc_media_release(media);
    if (stereo) {
        _mailbox = [VPPFrameMailbox new];
        libvlc_video_set_callbacks(_player, VPPLock, VPPUnlock, VPPDisplay, (__bridge void *)_mailbox);
        libvlc_video_set_format_callbacks(_player, VPPSetup, VPPCleanup);
    }
    return self;
}
- (void)attachDrawable:(UIView *)view {
    if (!_player || _mailbox) return;
    _drawable = view;
    libvlc_media_player_set_nsobject(_player, (__bridge void *)view);
}
- (void)play {
    if (_player) {
        _events.failed = NO;
        if (libvlc_media_player_play(_player) != 0) _events.failed = YES;
    }
}
- (void)setPaused:(BOOL)paused { if (_player) libvlc_media_player_set_pause(_player, paused); }
- (void)seekToFraction:(double)fraction {
    if (_player && self.seekable) libvlc_media_player_set_position(_player, MAX(0, MIN(1, fraction)), false);
}
- (double)position { return _player ? MAX(0, libvlc_media_player_get_position(_player)) : 0; }
- (double)elapsedSeconds { return _player ? MAX(0, libvlc_media_player_get_time(_player)) / 1000000.0 : 0; }
- (double)durationSeconds { return _player ? MAX(0, libvlc_media_player_get_length(_player)) / 1000000.0 : 0; }
- (BOOL)playing { return _player && libvlc_media_player_is_playing(_player); }
- (BOOL)seekable { return _player && libvlc_media_player_is_seekable(_player); }
- (BOOL)failed { return _player && (_events.failed || libvlc_media_player_get_state(_player) == libvlc_Error); }
- (NSString *)stateText {
    if (!_player) return @"已关闭";
    if (self.failed) return @"播放失败：请检查文件、编码或网络地址";
    switch (libvlc_media_player_get_state(_player)) {
        case libvlc_Opening: return @"正在打开";
        case libvlc_Playing: return @"播放中";
        case libvlc_Paused: return @"已暂停";
        case libvlc_Stopped: return @"已停止 / 播放结束";
        case libvlc_Stopping: return @"正在停止";
        case libvlc_Error: return @"播放失败：请检查文件、编码或网络地址";
        default: return @"准备播放";
    }
}
- (CVPixelBufferRef)copyLatestPixelBuffer { return [_mailbox take]; }
- (void)closeWithCompletion:(void (^)(void))completion {
    if (_closing) return;
    _closing = YES;
    libvlc_media_player_t *player = _player;
    libvlc_instance_t *instance = _instance;
    _player = NULL; _instance = NULL;
    // Keep the callback context and drawable alive through asynchronous libVLC 4 shutdown.
    VPPFrameMailbox *mailbox = _mailbox;
    UIView *drawable = _drawable;
    VPPPlaybackEvents *events = _events;
    dispatch_semaphore_t stopped = events.stopped;
    _mailbox = nil; _drawable = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __attribute__((objc_precise_lifetime)) VPPFrameMailbox *retainedMailbox = mailbox;
        __attribute__((objc_precise_lifetime)) UIView *retainedDrawable = drawable;
        __attribute__((objc_precise_lifetime)) VPPPlaybackEvents *retainedEvents = events;
        if (player) {
            while (dispatch_semaphore_wait(stopped, DISPATCH_TIME_NOW) == 0) {}
            if (libvlc_media_player_stop_async(player) == 0) {
                dispatch_semaphore_wait(stopped, DISPATCH_TIME_FOREVER);
            }
            libvlc_media_player_set_nsobject(player, NULL);
            libvlc_media_player_release(player);
        }
        if (instance) libvlc_release(instance);
        // Captures are intentionally referenced after player release.
        (void)retainedMailbox; (void)retainedDrawable; (void)retainedEvents;
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}
- (void)dealloc {
    // Normal teardown goes through closeWithCompletion; this also handles initialization failure.
    if (_player) libvlc_media_player_release(_player);
    if (_instance) libvlc_release(_instance);
}
@end
