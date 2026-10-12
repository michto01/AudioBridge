#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
NSView * _Nullable ABCreateCocoaEditor(AudioUnit _Nonnull unit, NSSize preferredSize);

// Prepare and release on AppKit's thread. Apply the cached realtime observer
// at a render boundary, without fetching an Objective-C AU property there.
void * _Nullable ABCreateRenderContextObserver(AUAudioUnit * _Nonnull unit);
void ABApplyRenderContextObserver(void * _Nonnull observer, const void * _Nullable workgroup);
void ABDestroyRenderContextObserver(void * _Nonnull observer);
