// Test harness.
//   atmostest dump <file> <outdir> [firstSeg] [nSegs]   write playlist/init/segments to disk
//   atmostest play <file> <seekSec> <seconds> [volume] [deviceUID]
//       serve via HLSServer, play with AVPlayer to the device, capture that
//       device's input (Loopback pass-through) and print per-channel RMS.
#import <AVFoundation/AVFoundation.h>
#import "../src/Segmenter.h"
#import "../src/HLSServer.h"
#include "cap.h"

static NSString *const kDefaultUID = @"com.rogueamoeba.Loopback:39FEBD16-3F2D-4064-9FAE-B105143B9734"; // "7.1.4 (atmos)"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: see source\n"); return 2; }
    NSString *mode = @(argv[1]);
    NSError *err;
    NSDate *t0 = [NSDate date];
    Segmenter *s = [Segmenter segmenterWithPath:@(argv[2]) error:&err];
    if (!s) { fprintf(stderr, "open failed: %s\n", err.localizedDescription.UTF8String); return 1; }
    printf("open %.2fs  segments %lu  duration %.1fs\nvideo: %s\naudio: %s\n", -t0.timeIntervalSinceNow,
           (unsigned long)s.segmentCount, s.duration, s.videoSummary.UTF8String, s.audioSummary.UTF8String);

    if ([mode isEqualToString:@"dump"]) {
        NSString *dir = @(argv[3]);
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSUInteger first = argc > 4 ? atoi(argv[4]) : 0, n = argc > 5 ? atoi(argv[5]) : 3;
        // Playlist restricted to the dumped segments so ffprobe/ffmpeg can read the set.
        NSArray *lines = [s.playlist componentsSeparatedByString:@"\n"];
        NSMutableString *pl = [NSMutableString string]; NSUInteger seg = 0; BOOL inSeg = NO;
        for (NSUInteger i = 0; i < lines.count; i++) {
            NSString *L = lines[i];
            if ([L hasPrefix:@"#EXTINF"]) { inSeg = seg >= first && seg < first + n; if (inSeg) [pl appendFormat:@"%@\n", L]; continue; }
            if ([L hasPrefix:@"seg"]) { if (inSeg) [pl appendFormat:@"%@\n", L]; seg++; continue; }
            if (L.length) [pl appendFormat:@"%@\n", L];
        }
        [pl writeToFile:[dir stringByAppendingPathComponent:@"index.m3u8"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [s.initializationSegment writeToFile:[dir stringByAppendingPathComponent:@"init.mp4"] atomically:YES];
        for (NSUInteger k = first; k < first + n && k < s.segmentCount; k++) {
            NSDate *ts = [NSDate date];
            NSData *d = [s mediaSegment:k];
            printf("seg%lu %lu bytes %.3fs\n", (unsigned long)k, (unsigned long)d.length, -ts.timeIntervalSinceNow);
            [d writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"seg%lu.m4s", (unsigned long)k]] atomically:YES];
        }
        return 0;
    }

    double seek = atof(argv[3]), dur = argc > 4 ? atof(argv[4]) : 8;
    float vol = argc > 5 ? atof(argv[5]) : 0.03f;
    NSString *uid = argc > 6 ? @(argv[6]) : kDefaultUID;
    HLSServer *srv = [[HLSServer alloc] initWithSegmenter:s];
    if (![srv start:&err]) { fprintf(stderr, "server failed\n"); return 1; }
    AVPlayer *p = [AVPlayer playerWithURL:srv.playlistURL];
    p.audioOutputDeviceUniqueID = uid; p.volume = vol;
    while (p.currentItem.status == AVPlayerItemStatusUnknown) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (p.currentItem.status != AVPlayerItemStatusReadyToPlay) { fprintf(stderr, "item failed: %s\n", p.currentItem.error.description.UTF8String); return 1; }
    for (AVPlayerItemTrack *t in p.currentItem.tracks)
        for (id fd in t.assetTrack.formatDescriptions) {
            size_t n = 0; const AudioFormatListItem *fl = CMAudioFormatDescriptionGetFormatList((__bridge CMAudioFormatDescriptionRef)fd, &n);
            for (size_t i = 0; fl && i < n / sizeof *fl; i++) { UInt32 f = CFSwapInt32HostToBig(fl[i].mASBD.mFormatID); printf("  format list: %.4s %u ch\n", (char *)&f, fl[i].mASBD.mChannelsPerFrame); }
        }
    __block BOOL seeked = NO;
    [p seekToTime:CMTimeMakeWithSeconds(seek, 600) toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL f) { seeked = YES; }];
    while (!seeked) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    AVPlayerItemVideoOutput *vo = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:nil];
    [p.currentItem addOutput:vo];
    __block int frames = 0; __block double firstT = -1, lastT = -1; __block size_t w = 0, h = 0;
    NSTimer *tm = [NSTimer scheduledTimerWithTimeInterval:1/120.0 repeats:YES block:^(NSTimer *t) {
        CMTime it = [vo itemTimeForHostTime:CACurrentMediaTime()];
        if (![vo hasNewPixelBufferForItemTime:it]) return;
        CVPixelBufferRef pb = [vo copyPixelBufferForItemTime:it itemTimeForDisplay:NULL];
        if (pb) { frames++; w = CVPixelBufferGetWidth(pb); h = CVPixelBufferGetHeight(pb); if (firstT < 0) firstT = CMTimeGetSeconds(it); lastT = CMTimeGetSeconds(it); CVPixelBufferRelease(pb); }
    }];
    if (getenv("CAP_SERIES")) gSeries = 0;
    capStart(uid, 12);
    [p play];
    NSDate *start = [NSDate date];
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:dur]];
    double wall = -start.timeIntervalSinceNow, media = CMTimeGetSeconds(p.currentTime) - seek;
    [p pause]; [tm invalidate];
    printf("video frames %d (%zux%zu) item time %.2f..%.2f => %.2f fps\n", frames, w, h, firstT, lastT, frames > 1 ? (frames - 1) / (lastT - firstT) : 0);
    printf("after seek to %.1f: played %.2fs media in %.2fs wall; stalls? %s; item err %s\n", seek, media, wall,
           p.currentItem.isPlaybackBufferEmpty ? "buffer empty" : "no",
           p.currentItem.error ? p.currentItem.error.description.UTF8String : "none");
    AVPlayerItemErrorLog *el = p.currentItem.errorLog;
    for (AVPlayerItemErrorLogEvent *e in el.events) printf("  errorlog: %ld %s\n", (long)e.errorStatusCode, e.errorComment.UTF8String);
    capReport();
    [srv stop];
    return 0;
}}
