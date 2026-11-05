#import "VPPSeekThumbnails.h"
#import <VLCKit/vlc/vlc.h>

// Dedicated thumbnail decoder. All creation and waits run off the UI thread.
@interface VPPThumbnailResult : NSObject
@property (nonatomic, strong) dispatch_semaphore_t finished;
@property (nonatomic, strong) NSData *jpeg;
@property (nonatomic) double seconds;
@end
@implementation VPPThumbnailResult
@end

static void thumbnailReady(void *opaque, libvlc_parser_task *task, libvlc_picture_t *picture) {
    VPPThumbnailResult *result = (__bridge VPPThumbnailResult *)opaque;
    if (picture && libvlc_picture_type(picture) == libvlc_picture_Jpg) {
        result.seconds = (double)libvlc_picture_get_time(picture) / 1000000.0;
        size_t size = 0;
        const unsigned char *bytes = libvlc_picture_get_buffer(picture, &size);
        if (bytes && size) result.jpeg = [NSData dataWithBytes:bytes length:size];
    }
    dispatch_semaphore_signal(result.finished);
}

@implementation VPPSeekThumbnails {
    NSURL *_url;
    dispatch_queue_t _queue;
    libvlc_instance_t *_instance;
    libvlc_media_t *_media;
    libvlc_parser_t *_parser;
}
- (instancetype)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = url;
        _queue = dispatch_queue_create("com.jeff.visionproplayer.seek-preview", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (BOOL)prepare {
    if (_instance) return _parser && _media;
    _instance = libvlc_new(0, NULL);
    if (!_instance) return NO;
    _media = _url.isFileURL ? libvlc_media_new_path(_url.fileSystemRepresentation)
                            : libvlc_media_new_location(_url.absoluteString.UTF8String);
    struct libvlc_parser_cfg cfg = { .max_thumbnailer_threads = 1, .timeout = 2500000 };
    _parser = libvlc_parser_new(_instance, &cfg);
    return _parser && _media;
}
- (void)fetchAtSeconds:(double)seconds completion:(void (^)(NSData *, double))completion {
    dispatch_async(_queue, ^{
        if (![self prepare]) { completion(nil, seconds); return; }
        libvlc_thumbnailer_request_t request = {0};
        request.media = self->_media;
        request.width = 384; // derive height from source aspect ratio
        request.type = libvlc_picture_Jpg;
        request.seek.type = libvlc_thumbnailer_seek_time;
        request.seek.value.time = (libvlc_time_t)(seconds * 1000000);
        request.seek.speed = libvlc_media_thumbnail_seek_precise;
        static const struct libvlc_thumbnailer_cbs callbacks = { .on_ended = thumbnailReady };
        VPPThumbnailResult *result = [VPPThumbnailResult new];
        result.finished = dispatch_semaphore_create(0);
        libvlc_parser_task *task = libvlc_parser_task_new_thumbnail(self->_parser, &request, &callbacks, (__bridge void *)result);
        if (task) {
            // A successful submit guarantees exactly one callback, including on timeout.
            if (libvlc_parser_submit(self->_parser, task) == 0)
                dispatch_semaphore_wait(result.finished, DISPATCH_TIME_FOREVER);
            libvlc_parser_task_release(task);
        }
        completion(result.jpeg, result.seconds);
    });
}
- (void)dealloc {
    if (_parser) libvlc_parser_destroy(_parser);
    if (_media) libvlc_media_release(_media);
    if (_instance) libvlc_release(_instance);
}
@end
