// PlayAtmos — minimal macOS player for MKV files with Dolby Atmos (E-AC-3 JOC).
//
// Pipeline: MKV --(libavformat demux, stream copy)--> HLS fMP4 segments made on
// demand --(127.0.0.1 HTTP)--> AVPlayer --> Apple's Atmos renderer --> the
// Core Audio output device's speaker layout (e.g. 7.1.4).
#import <Cocoa/Cocoa.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import "Segmenter.h"
#import "HLSServer.h"
#import "Subtitles.h"
#import <os/log.h>

// ---------------------------------------------------------------------------
@interface DropView : NSView
@property (copy) void (^onDrop)(NSURL *);
@end
@implementation DropView
- (instancetype)initWithFrame:(NSRect)r {
    if ((self = [super initWithFrame:r])) [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    return self;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)s { return NSDragOperationCopy; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)s {
    NSURL *u = [NSURL URLFromPasteboard:s.draggingPasteboard];
    if (u && self.onDrop) self.onDrop(u);
    return u != nil;
}
@end

// ---------------------------------------------------------------------------
@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation AppDelegate {
    NSWindow *_win;
    AVPlayerView *_pv;
    NSTextField *_hint;
    AVPlayer *_player;
    Segmenter *_seg;
    HLSServer *_server;
    NSString *_deviceUID;       // nil = follow system default output
    NSMenu *_outputMenu;
    NSURL *_pendingOpen;
    Subtitles *_subs;
    SubtitleView *_subView;
    NSMenu *_subMenu;
    id _timeObs;
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self buildMenus];
    _win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 540)
                                       styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                                         backing:NSBackingStoreBuffered defer:NO];
    _win.title = @"PlayAtmos";
    _win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _win.releasedWhenClosed = NO;
    DropView *root = [[DropView alloc] initWithFrame:_win.contentView.bounds];
    __weak AppDelegate *ws = self;
    root.onDrop = ^(NSURL *u) { [ws openURL:u]; };
    _pv = [[AVPlayerView alloc] initWithFrame:root.bounds];
    _pv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _pv.controlsStyle = AVPlayerViewControlsStyleFloating;
    _pv.showsFullScreenToggleButton = YES;
    [root addSubview:_pv];
    _subView = [[SubtitleView alloc] initWithFrame:_pv.contentOverlayView.bounds];
    _subView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_pv.contentOverlayView addSubview:_subView];
    _hint = [NSTextField labelWithString:@"Open an MKV file (⌘O) or drop it here"];
    _hint.textColor = NSColor.secondaryLabelColor;
    _hint.font = [NSFont systemFontOfSize:18];
    [_hint sizeToFit];
    _hint.frame = NSMakeRect((root.bounds.size.width - _hint.frame.size.width) / 2, root.bounds.size.height / 2, _hint.frame.size.width, _hint.frame.size.height);
    _hint.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [root addSubview:_hint];
    _win.contentView = root;
    [_win center];
    [_win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (_pendingOpen) { [self openURL:_pendingOpen]; _pendingOpen = nil; }
}

- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls {
    if (!_win) { _pendingOpen = urls.firstObject; return; }
    [self openURL:urls.firstObject];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }

// --- Menus -----------------------------------------------------------------
static NSMenuItem *item(NSString *t, SEL a, NSString *k) { return [[NSMenuItem alloc] initWithTitle:t action:a keyEquivalent:k]; }

- (void)buildMenus {
    NSMenu *bar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItem:item(@"Quit PlayAtmos", @selector(terminate:), @"q")];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [NSMenuItem new]; [bar addItem:fileItem];
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [file addItem:item(@"Open…", @selector(openDocument:), @"o")];
    [file addItem:item(@"Close Window", @selector(performClose:), @"w")];
    fileItem.submenu = file;

    NSMenuItem *playItem = [NSMenuItem new]; [bar addItem:playItem];
    NSMenu *play = [[NSMenu alloc] initWithTitle:@"Playback"];
    [play addItem:item(@"Play/Pause", @selector(togglePlay:), @" ")];
    play.itemArray.lastObject.keyEquivalentModifierMask = 0;
    NSString *right = [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey];
    NSString *left = [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey];
    NSMenuItem *f = item(@"Skip Forward 10 s", @selector(skipForward:), right); f.keyEquivalentModifierMask = 0; [play addItem:f];
    NSMenuItem *b = item(@"Skip Back 10 s", @selector(skipBack:), left); b.keyEquivalentModifierMask = 0; [play addItem:b];
    playItem.submenu = play;

    NSMenuItem *audioItem = [NSMenuItem new]; [bar addItem:audioItem];
    _outputMenu = [[NSMenu alloc] initWithTitle:@"Audio Output"];
    _outputMenu.delegate = self;   // rebuilt each time it opens
    audioItem.submenu = _outputMenu;

    NSMenuItem *subItem = [NSMenuItem new]; [bar addItem:subItem];
    _subMenu = [[NSMenu alloc] initWithTitle:@"Subtitles"];
    _subMenu.delegate = self;
    subItem.submenu = _subMenu;

    NSMenuItem *viewItem = [NSMenuItem new]; [bar addItem:viewItem];
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *fs = item(@"Enter Full Screen", @selector(toggleFullScreen:), @"f");
    fs.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    [view addItem:fs];
    viewItem.submenu = view;
    NSApp.mainMenu = bar;
}

// Audio Output menu: system default + every device with output channels.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    if (menu == _subMenu) {
        NSMenuItem *off = item(@"Off", @selector(chooseSubtitle:), @"");
        off.state = _subs.selectedTrack == nil ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:off];
        if (_subs.tracks.count) [menu addItem:[NSMenuItem separatorItem]];
        for (SubtitleTrack *t in _subs.tracks) {
            NSMenuItem *it = item(t.label, @selector(chooseSubtitle:), @"");
            it.representedObject = t;
            it.state = t == _subs.selectedTrack ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:it];
        }
        return;
    }
    NSMenuItem *def = item(@"System Default", @selector(chooseOutput:), @"");
    def.representedObject = nil;
    def.state = _deviceUID == nil ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:def];
    [menu addItem:[NSMenuItem separatorItem]];
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &sz)) return;
    AudioDeviceID *ids = malloc(sz);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &sz, ids);
    for (UInt32 i = 0; i < sz / sizeof(AudioDeviceID); i++) {
        AudioObjectPropertyAddress sc = { kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain };
        UInt32 bsz = 0;
        if (AudioObjectGetPropertyDataSize(ids[i], &sc, 0, NULL, &bsz) || bsz == 0) continue;
        AudioBufferList *bl = malloc(bsz);
        AudioObjectGetPropertyData(ids[i], &sc, 0, NULL, &bsz, bl);
        UInt32 ch = 0; for (UInt32 k = 0; k < bl->mNumberBuffers; k++) ch += bl->mBuffers[k].mNumberChannels;
        free(bl);
        if (ch == 0) continue;
        CFStringRef name = NULL, uid = NULL; UInt32 s = sizeof(CFStringRef);
        AudioObjectPropertyAddress pn = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyData(ids[i], &pn, 0, NULL, &s, &name);
        pn.mSelector = kAudioDevicePropertyDeviceUID;
        AudioObjectGetPropertyData(ids[i], &pn, 0, NULL, &s, &uid);
        if (!uid) { if (name) CFRelease(name); continue; }
        NSString *u = CFBridgingRelease(uid), *nm = name ? CFBridgingRelease(name) : u;
        NSMenuItem *it = item([NSString stringWithFormat:@"%@  (%u ch)", nm, ch], @selector(chooseOutput:), @"");
        it.representedObject = u;
        it.state = [_deviceUID isEqualToString:u] ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:it];
    }
    free(ids);
}

- (void)chooseSubtitle:(NSMenuItem *)sender {
    [_subs selectTrack:sender.representedObject];
    _subView.cues = @[]; [_subView setNeedsDisplay:YES];
}

- (void)chooseOutput:(NSMenuItem *)sender {
    _deviceUID = sender.representedObject;
    _player.audioOutputDeviceUniqueID = _deviceUID;
}

// --- Actions ---------------------------------------------------------------
- (void)openDocument:(id)sender {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = NO;
    if ([p runModal] == NSModalResponseOK) [self openURL:p.URL];
}
- (void)togglePlay:(id)s { if (!_player) return; _player.rate == 0 ? [_player play] : [_player pause]; }
- (void)skipBy:(double)d {
    if (!_player) return;
    CMTime t = CMTimeAdd(_player.currentTime, CMTimeMakeWithSeconds(d, 600));
    if (CMTimeGetSeconds(t) < 0) t = kCMTimeZero;
    [_player seekToTime:t];
}
- (void)skipForward:(id)s { [self skipBy:10]; }
- (void)skipBack:(id)s { [self skipBy:-10]; }
- (void)toggleFullScreen:(id)s { [_win toggleFullScreen:s]; }

- (void)fail:(NSString *)msg {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Cannot play this file";
    a.informativeText = msg;
    [a beginSheetModalForWindow:_win completionHandler:nil];
}

- (void)openURL:(NSURL *)url {
    if (!url) return;
    [_win makeKeyAndOrderFront:nil];
    [_player pause];
    if (_timeObs) { [_player removeTimeObserver:_timeObs]; _timeObs = nil; }
    _pv.player = nil; _player = nil;
    [_server stop]; _server = nil; _seg = nil;
    [_subs stop]; _subs = nil;
    _subView.cues = @[]; [_subView setNeedsDisplay:YES];
    _win.title = url.lastPathComponent;
    _win.subtitle = @"Opening…";
    NSString *path = url.path;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err;
        Segmenter *seg = [Segmenter segmenterWithPath:path error:&err];
        Subtitles *subs = seg ? [[Subtitles alloc] initWithPath:path] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!seg) { self->_win.subtitle = @""; [self fail:err.localizedDescription]; return; }
            self->_subs = subs;
            [subs selectTrack:subs.defaultTrack];
            [self startWithSegmenter:seg];
        });
    });
}

- (void)startWithSegmenter:(Segmenter *)seg {
    NSError *err;
    HLSServer *srv = [[HLSServer alloc] initWithSegmenter:seg];
    if (![srv start:&err]) { [self fail:@"Could not start local HLS server."]; return; }
    _seg = seg; _server = srv;
    _hint.hidden = YES;
    _player = [AVPlayer playerWithURL:srv.playlistURL];
    _player.audioOutputDeviceUniqueID = _deviceUID;
    const char *vol = getenv("PLAYATMOS_VOLUME");   // test hook: quiet automated runs
    if (vol) _player.volume = (float)atof(vol);
    _pv.player = _player;
    _win.subtitle = seg.audioSummary;
    // Subtitles follow the player clock (item time == source time; see Segmenter).
    __weak AppDelegate *wself = self;
    _timeObs = [_player addPeriodicTimeObserverForInterval:CMTimeMake(1, 30) queue:dispatch_get_main_queue() usingBlock:^(CMTime t) {
        AppDelegate *s = wself;
        if (!s || !s->_subs) return;
        NSArray *cues = [s->_subs cuesAt:CMTimeGetSeconds(t)];
        NSRect vr = [s->_subView convertRect:s->_pv.videoBounds fromView:s->_pv];
        if (![cues isEqualToArray:s->_subView.cues] || !NSEqualRects(vr, s->_subView.videoRect)) {
            s->_subView.cues = cues; s->_subView.videoRect = vr; [s->_subView setNeedsDisplay:YES];
        }
    }];
    os_log(OS_LOG_DEFAULT, "PlayAtmos: video %{public}s; audio %{public}s; %lu segments", seg.videoSummary.UTF8String, seg.audioSummary.UTF8String, (unsigned long)seg.segmentCount);

    __weak AppDelegate *ws = self;
    AVPlayerItem *it = _player.currentItem;
    [NSNotificationCenter.defaultCenter addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:it queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [ws fail:[n.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] localizedDescription] ?: @"Playback failed."]; }];
    [self waitForReady:it];
}

// Poll item status (simple; avoids KVO boilerplate), then report what AVPlayer
// recognised and fit the window to the video's aspect ratio.
- (void)waitForReady:(AVPlayerItem *)it {
    if (it != _player.currentItem) return;
    if (it.status == AVPlayerItemStatusUnknown) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self waitForReady:it]; });
        return;
    }
    if (it.status == AVPlayerItemStatusFailed) { [self fail:it.error.localizedDescription ?: @"AVPlayer could not open the stream."]; return; }
    BOOL joc = NO;
    for (AVPlayerItemTrack *t in it.tracks)
        for (id fd in t.assetTrack.formatDescriptions) {
            size_t n = 0;
            const AudioFormatListItem *fl = CMAudioFormatDescriptionGetFormatList((__bridge CMAudioFormatDescriptionRef)fd, &n);
            for (size_t i = 0; fl && i < n / sizeof *fl; i++) if (fl[i].mASBD.mFormatID == 'ec+3') joc = YES;
        }
    _win.subtitle = [NSString stringWithFormat:@"%@%@", _seg.audioSummary,
                     _seg.atmosPassthrough ? (joc ? @" — Atmos recognised by AVPlayer" : @" — WARNING: AVPlayer did not report Atmos") : @""];
    os_log(OS_LOG_DEFAULT, "PlayAtmos: ready: %{public}s", _win.subtitle.UTF8String);
    CGSize ps = it.presentationSize;
    if (ps.width > 0 && ps.height > 0 && !(_win.styleMask & NSWindowStyleMaskFullScreen)) {
        NSRect vis = _win.screen.visibleFrame;
        CGFloat w = MIN(ps.width, vis.size.width * 0.8), h = w * ps.height / ps.width;
        if (h > vis.size.height * 0.8) { h = vis.size.height * 0.8; w = h * ps.width / ps.height; }
        NSRect fr = [_win frameRectForContentRect:NSMakeRect(0, 0, w, h)];
        fr.origin = NSMakePoint(NSMidX(vis) - fr.size.width / 2, NSMidY(vis) - fr.size.height / 2);
        [_win setFrame:fr display:YES animate:YES];
        _win.contentAspectRatio = ps;
    }
    // Test hooks (automated checks without screen recording):
    //   PLAYATMOS_SEEK=<sec>      start playback there
    //   PLAYATMOS_SNAPSHOT=<png>  3 s after start, render the subtitle overlay to a PNG
    const char *seek = getenv("PLAYATMOS_SEEK"), *snap = getenv("PLAYATMOS_SNAPSHOT");
    if (seek) [_player seekToTime:CMTimeMakeWithSeconds(atof(seek), 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    if (snap) {
        NSString *path = @(snap);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SubtitleView *v = self->_subView;
            NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
            [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            NSMutableArray *texts = [NSMutableArray array];
            for (SubtitleCue *c in v.cues) [texts addObject:c.text ?: @"<image>"];
            os_log(OS_LOG_DEFAULT, "PlayAtmos: snapshot t=%.3f track=%{public}s videoRect=%{public}s overlay=%{public}s cues=%{public}s",
                   CMTimeGetSeconds(self->_player.currentTime), self->_subs.selectedTrack.label.UTF8String ?: "off",
                   NSStringFromRect(self->_subView.videoRect).UTF8String, NSStringFromRect(v.bounds).UTF8String,
                   [texts componentsJoinedByString:@" | "].UTF8String);
        });
    }
    [_player play];
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *d = [AppDelegate new];
        app.delegate = d;
        [app run];
    }
    return 0;
}
