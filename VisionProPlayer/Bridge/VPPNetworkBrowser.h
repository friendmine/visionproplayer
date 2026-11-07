#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// One cancellable request per instance, with bounded network parsing off-main.
@interface VPPNetworkBrowser : NSObject
- (void)listURL:(NSURL *)url credentials:(NSDictionary<NSString *, NSString *> *)credentials
    completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable, NSError * _Nullable))completion
    NS_SWIFT_NAME(list(url:credentials:completion:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
