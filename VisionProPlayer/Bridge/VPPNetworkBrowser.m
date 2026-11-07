#import "VPPNetworkBrowser.h"
#import "VPPNetworkAuthentication.h"

@interface VPPDirectoryResult : NSObject
@property (nonatomic, strong) dispatch_semaphore_t finished;
@property (nonatomic) libvlc_parser_status_t status;
@end
@implementation VPPDirectoryResult
@end
static void directoryParsed(void *opaque, libvlc_parser_task *task, libvlc_parser_status_t status) {
    VPPDirectoryResult *result = (__bridge VPPDirectoryResult *)opaque;
    result.status = status;
    dispatch_semaphore_signal(result.finished);
}

@implementation VPPNetworkBrowser {
    BOOL _cancelled;
    libvlc_parser_t *_activeParser;
}
- (void)cancel {
    @synchronized (self) {
        _cancelled = YES;
        if (_activeParser) libvlc_parser_cancel_request(_activeParser, NULL);
    }
}
- (void)listURL:(NSURL *)url credentials:(NSDictionary<NSString *,NSString *> *)credentials completion:(void (^)(NSArray<NSDictionary<NSString *, id> *> * _Nullable, NSError * _Nullable))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        libvlc_instance_t *instance = libvlc_new(0, NULL);
        libvlc_media_t *media = libvlc_media_new_location(url.absoluteString.UTF8String);
        struct libvlc_parser_cfg cfg = { .max_parser_threads = 1, .timeout = 15000000 };
        libvlc_parser_t *parser = instance ? libvlc_parser_new(instance, &cfg) : NULL;
        NSMutableArray *entries = nil;
        BOOL tooManyEntries = NO;
        VPPDirectoryResult *result = [VPPDirectoryResult new];
        result.finished = dispatch_semaphore_create(0); result.status = libvlc_parser_status_failed;
        if (media && parser) {
            VPPApplyNetworkCredentials(media, credentials);
            // Read one level only; never recursively parse video contents.
            libvlc_media_add_option_flag(media, ":recursive=none", libvlc_media_option_trusted);
            libvlc_parser_request_t request = { .media = media, .parse_flags = libvlc_media_parse };
            static const struct libvlc_parser_cbs callbacks = { .on_parsed = directoryParsed };
            libvlc_parser_task *task = libvlc_parser_task_new_parse(parser, &request, &callbacks, (__bridge void *)result);
            BOOL submitted = NO;
            @synchronized (self) {
                if (!self->_cancelled && task) {
                    self->_activeParser = parser;
                    submitted = libvlc_parser_submit(parser, task) == 0;
                }
            }
            if (submitted) dispatch_semaphore_wait(result.finished, DISPATCH_TIME_FOREVER);
            @synchronized (self) {
                self->_activeParser = NULL;
                if (self->_cancelled) result.status = libvlc_parser_status_cancelled;
            }
            if (task) libvlc_parser_task_release(task);
            if (result.status == libvlc_parser_status_done) {
                entries = [NSMutableArray array];
                libvlc_media_list_t *children = libvlc_media_subitems(media);
                if (children) {
                    libvlc_media_list_lock(children);
                    int count = libvlc_media_list_count(children);
                    // A large directory is bounded and reported, never silently truncated.
                    if (count > 10000) { entries = nil; tooManyEntries = YES; }
                    else for (int i = 0; i < count; ++i) {
                        libvlc_media_t *child = libvlc_media_list_item_at_index(children, i);
                        if (!child) continue;
                        char *mrl = libvlc_media_get_mrl(child);
                        if (mrl) {
                            NSURLComponents *parts = [NSURLComponents componentsWithString:@(mrl)];
                            if ([parts.scheme.lowercaseString isEqualToString:@"smb2"]) parts.scheme = @"smb";
                            if (parts.URL) [entries addObject:@{@"url": parts.URL.absoluteString, @"directory": @(libvlc_media_get_type(child) == libvlc_media_type_directory)}];
                            libvlc_free(mrl);
                        }
                        libvlc_media_release(child);
                    }
                    libvlc_media_list_unlock(children);
                    libvlc_media_list_release(children);
                }
            }
        }
        if (parser) libvlc_parser_destroy(parser);
        if (media) libvlc_media_release(media);
        if (instance) libvlc_release(instance);
        NSError *error = entries ? nil : [NSError errorWithDomain:@"VisionPlayer.Network" code:result.status
            userInfo:@{NSLocalizedDescriptionKey: tooManyEntries ? @"目录项目超过 10000 个，请将服务器地址设为更具体的共享文件夹。" : result.status == libvlc_parser_status_timeout ? @"读取超时，请检查 NAS 连接后重试。" : @"无法读取共享目录，请检查网络、共享名称和登录信息。"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(entries, error); });
    });
}
@end
