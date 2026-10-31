#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
/// Uses the public libVLC C API shipped inside the pinned official VLCKit framework.
/// Call control methods on the main thread. Pixel callbacks use a bounded mailbox.
@interface VPPVLCSession : NSObject
- (nullable instancetype)initWithURL:(NSURL *)url stereo:(BOOL)stereo error:(NSError **)error;
- (void)attachDrawable:(UIView *)view;
- (void)play;
- (void)setPaused:(BOOL)paused;
- (void)seekToFraction:(double)fraction;
/// Completion fires on the main queue after decoder callbacks have stopped and resources are released.
- (void)closeWithCompletion:(void (^)(void))completion;
- (nullable CVPixelBufferRef)copyLatestPixelBuffer CF_RETURNS_RETAINED;
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) double elapsedSeconds;
@property (nonatomic, readonly) double durationSeconds;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL seekable;
@property (nonatomic, readonly) NSString *stateText;
@property (nonatomic, readonly) BOOL failed;
@end
NS_ASSUME_NONNULL_END
