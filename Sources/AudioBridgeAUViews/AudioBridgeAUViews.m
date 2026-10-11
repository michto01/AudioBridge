#import "AudioBridgeAUViews.h"
#import <AudioToolbox/AUCocoaUIView.h>
NSView *ABCreateCocoaEditor(AudioUnit unit, NSSize size) {
    UInt32 bytes = 0;
    if (AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &bytes, NULL) != noErr
        || bytes < sizeof(AudioUnitCocoaViewInfo) || bytes > 65536) return nil;
    AudioUnitCocoaViewInfo *info = calloc(1, bytes);
    if (!info) return nil;
    UInt32 received = bytes;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, info, &received) != noErr) { free(info); return nil; }
    NSUInteger count = received >= sizeof(CFURLRef) ? (MIN(received, bytes) - sizeof(CFURLRef)) / sizeof(CFStringRef) : 0;
    NSView *view = nil;
    @try {
        NSURL *url = (__bridge NSURL *)info->mCocoaAUViewBundleLocation;
        NSBundle *bundle = url ? [NSBundle bundleWithURL:url] : nil;
        if ([bundle load]) {
            for (NSUInteger i = 0; i < count && !view; i++) {
                NSString *name = (__bridge NSString *)info->mCocoaAUViewClass[i];
                Class cls = name ? [bundle classNamed:name] : Nil;
                if ([cls conformsToProtocol:@protocol(AUCocoaUIBase)]) {
                    id<AUCocoaUIBase> factory = [[cls alloc] init];
                    view = [factory uiViewForAudioUnit:unit withSize:size];
                }
            }
        }
    } @catch (NSException *exception) { view = nil; }
    if (info->mCocoaAUViewBundleLocation) CFRelease(info->mCocoaAUViewBundleLocation);
    for (NSUInteger i = 0; i < count; i++) if (info->mCocoaAUViewClass[i]) CFRelease(info->mCocoaAUViewClass[i]);
    free(info);
    return view;
}
