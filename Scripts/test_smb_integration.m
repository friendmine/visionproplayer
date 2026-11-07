#import <Foundation/Foundation.h>
#import "../VisionProPlayer/Bridge/VPPNetworkBrowser.h"
#import "../VisionProPlayer/Bridge/VPPNetworkAuthentication.h"
#import "../VisionProPlayer/Bridge/VPPSeekThumbnails.h"

static BOOL waitUntil(BOOL (^condition)(void), double timeout) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && [end timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return condition();
}
static NSArray *browse(NSURL *url, NSDictionary *credentials, BOOL cancel) {
    VPPNetworkBrowser *browser = [VPPNetworkBrowser new];
    __block BOOL done = NO; __block NSArray *entries = nil;
    [browser listURL:url credentials:credentials completion:^(NSArray *value, NSError *error) { entries = value; done = YES; }];
    if (cancel) [browser cancel];
    if (!waitUntil(^BOOL{ return done; }, 20)) { [browser cancel]; return nil; }
    return entries;
}
static void stateChanged(void *opaque, libvlc_state_t state) {
    if (state == libvlc_Stopped) dispatch_semaphore_signal((__bridge dispatch_semaphore_t)opaque);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 2;
        NSDictionary *fixture = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
        NSURL *url = [NSURL URLWithString:fixture[@"url"]];
        NSDictionary *credentials = @{@"smb-user": fixture[@"username"], @"smb-pwd": fixture[@"password"], @"smb-domain": @""};
        NSMutableArray *checks = [NSMutableArray array];
        void (^check)(NSString *, BOOL) = ^(NSString *name, BOOL passed) { [checks addObject:@{@"name": name, @"passed": @(passed)}]; printf("%s %s\n", passed ? "PASS" : "FAIL", name.UTF8String); fflush(stdout); };
        NSMutableDictionary *bad = [credentials mutableCopy]; bad[@"smb-pwd"] = @"deliberately-wrong";
        check(@"bad-password-rejected-before-authenticated-session", browse(url, bad, NO) == nil);
        NSArray *root = browse(url, credentials, NO);
        check(@"authenticated-directory-list", root.count >= 2);
        NSDictionary *folder = nil, *movie = nil;
        for (NSDictionary *entry in root) {
            if ([entry[@"directory"] boolValue]) folder = entry;
            else if ([[NSURL URLWithString:entry[@"url"]].pathExtension isEqualToString:@"mp4"]) movie = entry;
        }
        check(@"unicode-directory-and-movie", folder != nil && movie != nil);
        if (folder) check(@"nested-directory-list", browse([NSURL URLWithString:folder[@"url"]], credentials, NO).count == 1);
        else check(@"nested-directory-list", NO);
        bad[@"smb-user"] = @"nonexistent-fixture-user";
        check(@"unknown-account-rejected", browse(url, bad, NO) == nil);
        check(@"missing-share-rejected", browse([NSURL URLWithString:@"../Missing/" relativeToURL:url].absoluteURL, credentials, NO) == nil);
        check(@"cancelled-directory-request", browse(url, credentials, YES) == nil);
        NSURL *movieURL = movie ? [NSURL URLWithString:movie[@"url"]] : [url URLByAppendingPathComponent:@"测试 #1.mp4"];
        VPPSeekThumbnails *reader = [[VPPSeekThumbnails alloc] initWithURL:movieURL networkCredentials:credentials];
        __block BOOL thumbDone = NO; __block BOOL thumbOK = NO;
        [reader fetchAtSeconds:2 completion:^(NSData *data, double time) {
            dispatch_async(dispatch_get_main_queue(), ^{ thumbOK = data.length > 100 && fabs(time-2) < 1; thumbDone = YES; });
        }];
        waitUntil(^BOOL{ return thumbDone; }, 10);
        check(@"authenticated-seek-preview-decodes-frame", thumbOK);
        const char *args[] = {"--vout=dummy", "--aout=dummy", "--no-video-title-show", "--avcodec-hw=none"};
        libvlc_instance_t *instance = libvlc_new(4, args);
        dispatch_semaphore_t stopped = dispatch_semaphore_create(0);
        static const struct libvlc_media_player_cbs callbacks = { .on_state_changed = stateChanged };
        libvlc_media_player_t *player = libvlc_media_player_new(instance, &callbacks, (__bridge void *)stopped);
        libvlc_media_t *media = libvlc_media_new_location(movieURL.absoluteString.UTF8String);
        VPPApplyNetworkCredentials(media, credentials);
        libvlc_media_player_set_media(player, media);
        libvlc_media_release(media);
        libvlc_media_player_play(player);
        BOOL playing = waitUntil(^BOOL{ return libvlc_media_player_get_time(player) > 500000; }, 10);
        check(@"authenticated-video-time-advances", playing);
        libvlc_media_player_set_time(player, 5000000, false);
        check(@"network-seek", waitUntil(^BOOL{ libvlc_time_t t = libvlc_media_player_get_time(player); return t >= 4800000 && t < 7000000; }, 5));
        libvlc_media_player_set_pause(player, true);
        check(@"network-pause", waitUntil(^BOOL{ return libvlc_media_player_get_state(player) == libvlc_Paused; }, 3));
        libvlc_time_t paused = libvlc_media_player_get_time(player);
        libvlc_media_player_set_pause(player, false);
        check(@"network-resume", waitUntil(^BOOL{ return libvlc_media_player_get_time(player) > paused + 300000; }, 3));
        if (libvlc_media_player_stop_async(player) == 0) dispatch_semaphore_wait(stopped, DISPATCH_TIME_FOREVER);
        libvlc_media_player_release(player); libvlc_release(instance);
        BOOL passed = YES;
        for (NSDictionary *c in checks) if (![c[@"passed"] boolValue]) passed = NO;
        NSDictionary *report = @{@"environment": @"macOS-loopback-SMB2-fixture", @"passed": @(passed), @"checks": checks,
            @"scope": @"Actual shipped VLC browser/authentication/thumbnail code and headless libVLC playback. Synthetic generated video, random test credentials; no NAS addresses, credentials or media content recorded. Not Vision Pro validation."};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil] writeToFile:@(argv[2]) atomically:YES];
        return passed ? 0 : 1;
    }
}
