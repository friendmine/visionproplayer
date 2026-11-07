#import <Foundation/Foundation.h>
#import <VLCKit/vlc/vlc.h>

// Credentials stay out of URLs, JSON and diagnostics. Only these fixed SMB
// options are accepted; caller values cannot introduce arbitrary VLC options.
static inline void VPPApplyNetworkCredentials(libvlc_media_t *media, NSDictionary<NSString *, NSString *> *credentials) {
    for (NSString *key in @[@"smb-user", @"smb-pwd", @"smb-domain"]) {
        NSString *value = credentials[key];
        if (value) {
            NSString *option = [NSString stringWithFormat:@":%@=%@", key, value];
            libvlc_media_add_option_flag(media, option.UTF8String, libvlc_media_option_trusted);
        }
    }
}
