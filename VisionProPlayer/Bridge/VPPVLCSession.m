#import "VPPResumeClockGuard.h"
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

// Track the output clock: the polling getters can retain the pre-seek time
// while paused even after VLC has displayed the newly sought picture.
@interface VPPOutputClock : NSObject {
    os_unfair_lock _lock;
    libvlc_media_player_time_point_t _point;
    libvlc_time_t _pausedDate;
    BOOL _valid;
}
- (void)update:(const libvlc_media_player_time_point_t *)point;
- (NSDictionary *)snapshot;
- (void)pauseAt:(libvlc_time_t)date;
- (BOOL)readTime:(libvlc_time_t *)time position:(double *)position;
@end
@implementation VPPOutputClock
- (instancetype)init { if ((self = [super init])) _lock = OS_UNFAIR_LOCK_INIT; return self; }
- (void)update:(const libvlc_media_player_time_point_t *)point {
    os_unfair_lock_lock(&_lock);
    _point = *point; _valid = point->ts_us >= 0; _pausedDate = 0;
    os_unfair_lock_unlock(&_lock);
}
- (void)pauseAt:(libvlc_time_t)date {
    os_unfair_lock_lock(&_lock);
    _pausedDate = date;
    if (date <= 0) _valid = NO;
    os_unfair_lock_unlock(&_lock);
}
- (NSDictionary *)snapshot {
    os_unfair_lock_lock(&_lock);
    NSDictionary *result = @{@"ts": @(_point.ts_us), @"systemDate": @(_point.system_date_us), @"rate": @(_point.rate), @"pausedDate": @(_pausedDate), @"valid": @(_valid), @"now": @(libvlc_clock())};
    os_unfair_lock_unlock(&_lock);
    return result;
}
- (BOOL)readTime:(libvlc_time_t *)time position:(double *)position {
    os_unfair_lock_lock(&_lock);
    libvlc_media_player_time_point_t point = _point;
    libvlc_time_t pausedDate = _pausedDate;
    BOOL valid = _valid;
    os_unfair_lock_unlock(&_lock);
    return valid && libvlc_media_player_time_point_interpolate(&point,
        pausedDate > 0 ? pausedDate : libvlc_clock(), time, position) == 0;
}
@end
static void VPPClockUpdated(void *opaque, const libvlc_media_player_time_point_t *point) {
    [(__bridge VPPOutputClock *)opaque update:point];
}
static void VPPClockPaused(void *opaque, libvlc_time_t date) {
    [(__bridge VPPOutputClock *)opaque pauseAt:date];
}
static const struct libvlc_media_player_watch_time_cbs VPPClockCallbacks = {
    .version = 0, .on_update = VPPClockUpdated, .on_paused = VPPClockPaused,
};

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

// libVLC may present the same picture repeatedly while paused. Compare only
// visible BGRA bytes: row padding is not image content and may be uninitialized.
static BOOL VPPFramesEqual(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!a || !b || CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b)
        || CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b)
        || CVPixelBufferGetPixelFormatType(a) != CVPixelBufferGetPixelFormatType(b)) return NO;
    if (CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly); return NO;
    }
    BOOL equal = YES;
    size_t bytes = CVPixelBufferGetWidth(a) * 4;
    for (size_t y = 0; y < CVPixelBufferGetHeight(a); y++) {
        const uint8_t *rowA = CVPixelBufferGetBaseAddress(a) + y * CVPixelBufferGetBytesPerRow(a);
        const uint8_t *rowB = CVPixelBufferGetBaseAddress(b) + y * CVPixelBufferGetBytesPerRow(b);
        if (memcmp(rowA, rowB, bytes) != 0) { equal = NO; break; }
    }
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    return equal;
}

@implementation VPPVLCSession {
    libvlc_instance_t *_instance;
    libvlc_media_player_t *_player;
    VPPFrameMailbox *_mailbox;
    UIView *_drawable;
    BOOL _closing;
    CVPixelBufferRef _pausedFrame;
    VPPPlaybackEvents *_events;
    VPPOutputClock *_clock;
    BOOL _watchingTime;
    BOOL _pausedSeekPending;
    libvlc_time_t _resumeAnchorDate, _resumeAnchorTime;
    double _resumeAnchorPosition;
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
    _clock = [VPPOutputClock new];
    _watchingTime = libvlc_media_player_watch_time(_player, 0, &VPPClockCallbacks, (__bridge void *)_clock) == 0;
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
- (void)clearPausedFrame {
    if (_pausedFrame) { CVPixelBufferRelease(_pausedFrame); _pausedFrame = NULL; }
}
- (void)play {
    [self clearPausedFrame];
    if (_player) {
        _resumeAnchorDate = 0;
        if (_pausedSeekPending && libvlc_media_player_get_state(_player) == libvlc_Paused
            && [_clock readTime:&_resumeAnchorTime position:&_resumeAnchorPosition]) {
            _resumeAnchorDate = libvlc_clock();
        }
        _pausedSeekPending = NO;
        _events.failed = NO;
        if (libvlc_media_player_play(_player) != 0) _events.failed = YES;
        else if (_resumeAnchorDate > 0) {
            // Re-align all tracks with the paused picture after a vout step;
            // buffered input can otherwise resume ahead of that picture.
            libvlc_media_player_set_time(_player, _resumeAnchorTime, false);
        }
    }
}
- (void)setPaused:(BOOL)paused { if (_player) libvlc_media_player_set_pause(_player, paused); }
- (void)seekToFraction:(double)fraction {
    // Let a paused seek publish even if its first frame is visually identical.
    [self clearPausedFrame];
    _resumeAnchorDate = 0; _pausedSeekPending = NO;
    if (_player && self.seekable) {
        BOOL wasPaused = libvlc_media_player_get_state(_player) == libvlc_Paused;
        int result = libvlc_media_player_set_position(_player, MAX(0, MIN(1, fraction)), false);
        // A paused vout may keep redisplaying its old picture until stepped.
        // Decode one frame at the requested position without resuming audio.
        if (result == 0 && wasPaused && _mailbox) {
            _pausedSeekPending = YES;
            libvlc_media_player_next_frame(_player);
        }
    }
}
- (NSArray<NSDictionary<NSString *, id> *> *)tracksForType:(libvlc_track_type_t)type {
    if (!_player) return @[];
    libvlc_media_tracklist_t *list = libvlc_media_player_get_tracklist(_player, type, false);
    if (!list) return @[];
    NSMutableArray *result = [NSMutableArray array];
    for (size_t i = 0; i < libvlc_media_tracklist_count(list); i++) {
        libvlc_media_track_t *track = libvlc_media_tracklist_at(list, i);
        if (!track->psz_id) continue;
        NSString *name = track->psz_name ? [NSString stringWithUTF8String:track->psz_name] : nil;
        NSString *language = track->psz_language ? [NSString stringWithUTF8String:track->psz_language] : nil;
        [result addObject:@{@"id": [NSString stringWithUTF8String:track->psz_id],
                            @"title": name ?: language ?: [NSString stringWithFormat:@"轨道 %zu", i+1],
                            @"selected": @(track->selected)}];
    }
    libvlc_media_tracklist_delete(list);
    return result;
}
- (NSArray *)audioTracks { return [self tracksForType:libvlc_track_audio]; }
- (NSArray *)subtitleTracks { return [self tracksForType:libvlc_track_text]; }
- (void)selectAudioTrack:(NSString *)identifier {
    if (_player) libvlc_media_player_select_tracks_by_ids(_player, libvlc_track_audio, identifier.UTF8String);
}
- (void)selectSubtitleTrack:(NSString *)identifier {
    if (_player) libvlc_media_player_select_tracks_by_ids(_player, libvlc_track_text, identifier.UTF8String);
}
- (NSDictionary *)clockDiagnostics {
    return @{@"watch": [_clock snapshot] ?: @{}, @"pollTime": @(_player ? libvlc_media_player_get_time(_player) : -1),
             @"resumeAnchorDate": @(_resumeAnchorDate), @"resumeAnchorTime": @(_resumeAnchorTime),
             @"pausedSeekPending": @(_pausedSeekPending), @"playerState": @(_player ? libvlc_media_player_get_state(_player) : -1)};
}
// The output watcher supplies the displayed paused frame. During playback the
// polling clock catches up sooner after seeks. Briefly hold a confirmed paused
// frame's position if resuming still exposes the pre-seek polling value.
- (void)readCurrentTime:(libvlc_time_t *)time position:(double *)position {
    *time = 0; *position = 0;
    if (!_player) return;
    if (libvlc_media_player_get_state(_player) == libvlc_Paused
        && [_clock readTime:time position:position]) return;
    *time = libvlc_media_player_get_time(_player);
    *position = libvlc_media_player_get_position(_player);
    VPPFilterResumeClock(libvlc_clock(), &_resumeAnchorDate, _resumeAnchorTime,
                        _resumeAnchorPosition, time, position);
}
- (double)position {
    libvlc_time_t time; double position;
    [self readCurrentTime:&time position:&position];
    return MAX(0, MIN(1, position));
}
- (double)elapsedSeconds {
    libvlc_time_t time; double position;
    [self readCurrentTime:&time position:&position];
    return MAX(0, time) / 1000000.0;
}
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
- (CVPixelBufferRef)copyLatestPixelBuffer {
    CVPixelBufferRef next = [_mailbox take];
    BOOL paused = _player && libvlc_media_player_get_state(_player) == libvlc_Paused;
    if (!paused) { [self clearPausedFrame]; return next; }
    if (!next) return NULL;
    if (VPPFramesEqual(next, _pausedFrame)) { CVPixelBufferRelease(next); return NULL; }
    [self clearPausedFrame];
    _pausedFrame = CVPixelBufferRetain(next);
    return next;
}
- (void)closeWithCompletion:(void (^)(void))completion {
    if (_closing) return;
    _closing = YES;
    [self clearPausedFrame];
    libvlc_media_player_t *player = _player;
    libvlc_instance_t *instance = _instance;
    _player = NULL; _instance = NULL;
    // Keep the callback context and drawable alive through asynchronous libVLC 4 shutdown.
    VPPFrameMailbox *mailbox = _mailbox;
    UIView *drawable = _drawable;
    VPPPlaybackEvents *events = _events;
    VPPOutputClock *clock = _clock;
    BOOL watchingTime = _watchingTime;
    _clock = nil; _watchingTime = NO;
    dispatch_semaphore_t stopped = events.stopped;
    _mailbox = nil; _drawable = nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __attribute__((objc_precise_lifetime)) VPPFrameMailbox *retainedMailbox = mailbox;
        __attribute__((objc_precise_lifetime)) UIView *retainedDrawable = drawable;
        __attribute__((objc_precise_lifetime)) VPPPlaybackEvents *retainedEvents = events;
        __attribute__((objc_precise_lifetime)) VPPOutputClock *retainedClock = clock;
        if (player) {
            if (watchingTime) libvlc_media_player_unwatch_time(player);
            while (dispatch_semaphore_wait(stopped, DISPATCH_TIME_NOW) == 0) {}
            if (libvlc_media_player_stop_async(player) == 0) {
                dispatch_semaphore_wait(stopped, DISPATCH_TIME_FOREVER);
            }
            libvlc_media_player_set_nsobject(player, NULL);
            libvlc_media_player_release(player);
        }
        if (instance) libvlc_release(instance);
        // Captures are intentionally referenced after player release.
        (void)retainedMailbox; (void)retainedDrawable; (void)retainedEvents; (void)retainedClock;
        dispatch_async(dispatch_get_main_queue(), completion);
    });
}
- (void)dealloc {
    // Normal teardown goes through closeWithCompletion; this also handles initialization failure.
    if (_pausedFrame) CVPixelBufferRelease(_pausedFrame);
    if (_player && _watchingTime) libvlc_media_player_unwatch_time(_player);
    if (_player) libvlc_media_player_release(_player);
    if (_instance) libvlc_release(_instance);
}
@end
