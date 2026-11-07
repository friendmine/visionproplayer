#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface VPPSeekThumbnails : NSObject
- (instancetype)initWithURL:(NSURL *)url;
- (instancetype)initWithURL:(NSURL *)url networkCredentials:(NSDictionary<NSString *, NSString *> *)networkCredentials;
- (void)fetchAtSeconds:(double)seconds completion:(void (^)(NSData * _Nullable, double))completion
    NS_SWIFT_NAME(fetch(at:completion:));
@end
NS_ASSUME_NONNULL_END
