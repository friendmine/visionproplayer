#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
/// Uses the public libVLC C API shipped inside the pinned official VLCKit framework.
/// Call control methods on the main thread. Pixel callbacks use a bounded mailbox.
@interface VPPVLCSession : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url stereo:(BOOL)stereo steadyClock:(BOOL)steadyClock error:(NSError **)error;
- (void)attachDrawable:(UIView *)view;
- (void)play;
- (void)setPaused:(BOOL)paused;
- (void)seekToFraction:(double)fraction;
/// Completion fires on the main queue after decoder callbacks have stopped and resources are released.
- (void)closeWithCompletion:(void (^)(void))completion;
- (nullable CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *audioTracks;
@property (nonatomic, readonly) NSArray<NSDictionary<NSString *, id> *> *subtitleTracks;
- (void)selectAudioTrack:(NSString *)identifier NS_SWIFT_NAME(selectAudioTrack(_:));
- (void)selectSubtitleTrack:(NSString *)identifier NS_SWIFT_NAME(selectSubtitleTrack(_:));
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) double elapsedSeconds;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL usesSteadyClock;
@property (nonatomic, readonly) BOOL seekable;
@property (nonatomic, readonly) NSString *stateText;
@property (nonatomic, readonly) BOOL failed;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *clockDiagnostics;
#if DEBUG
/// Events: 0 output ready, 1 presentation starts, 2 snapshot ready, 3 consumed, 4 subtitle selection.
- (NSArray *)decoderDiagnostics;
- (void)beginFrameDiagnostics;
- (NSArray<NSArray<NSNumber *> *> *)endFrameDiagnostics;
#endif
@end
NS_ASSUME_NONNULL_END
