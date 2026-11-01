// subtest <file> <trackIndex|auto[:audioLang]> <t1> [t2 ...] [--png out.png]
// Lists subtitle tracks, selects one, and prints the cues active at each time
// (times may jump around, like seeks).  --png renders the overlay for the last
// time over a grey 1920x1080 "video" so the drawing can be inspected.
#import <Cocoa/Cocoa.h>
#import "../src/Subtitles.h"

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: subtest file track t1 [t2...] [--png out.png]\n"); return 2; }
    Subtitles *s = [[Subtitles alloc] initWithPath:@(argv[1])];
    for (NSUInteger i = 0; i < s.tracks.count; i++)
        printf("track %lu: %s  [lang %s%s]\n", (unsigned long)i, s.tracks[i].label.UTF8String,
               s.tracks[i].language.UTF8String ?: "-", s.tracks[i].forced ? ", forced" : "");
    if (!strncmp(argv[2], "auto", 4)) {
        NSString *audio = argv[2][4] == ':' ? @(argv[2] + 5) : nil;
        SubtitleTrack *t = [s autoTrackForAudioLanguage:audio];
        [s selectTrack:t];
        printf("auto (audio %s): %s\n", audio.UTF8String ?: "unknown", t.label.UTF8String ?: "off");
    } else [s selectTrack:s.tracks[atoi(argv[2])]];
    NSString *png = nil; NSArray *last = @[];
    for (int a = 3; a < argc; a++) {
        if (!strcmp(argv[a], "--png") && a + 1 < argc) { png = @(argv[++a]); continue; }
        double t = atof(argv[a]);
        NSDate *t0 = [NSDate date];
        NSArray<SubtitleCue *> *cues = @[];
        while (-t0.timeIntervalSinceNow < 1.5) { cues = [s cuesAt:t]; [NSThread sleepForTimeInterval:0.05]; }   // let the reader catch up
        printf("t=%.2f:", t);
        if (!cues.count) printf(" (none)");
        for (SubtitleCue *c in cues) {
            if (c.text) printf(" [%.3f-%.3f] \"%s\"", c.start, c.end, [[c.text stringByReplacingOccurrencesOfString:@"\n" withString:@" / "] UTF8String]);
            else printf(" [%.3f-%.3f] image %.0fx%.0f at %.0f,%.0f on %.0fx%.0f", c.start, c.end, c.imageRect.size.width, c.imageRect.size.height,
                        c.imageRect.origin.x, c.imageRect.origin.y, c.canvas.width, c.canvas.height);
        }
        printf("\n");
        last = cues;
    }
    if (png) {
        NSRect r = NSMakeRect(0, 0, 1920, 1080);
        NSView *bg = [[NSView alloc] initWithFrame:r]; bg.wantsLayer = YES; bg.layer.backgroundColor = NSColor.darkGrayColor.CGColor;
        SubtitleView *v = [[SubtitleView alloc] initWithFrame:r];
        v.videoRect = NSMakeRect(0, 140, 1920, 800);   // letterboxed 2.4:1 picture
        v.cues = last;
        [bg addSubview:v];
        NSBitmapImageRep *rep = [bg bitmapImageRepForCachingDisplayInRect:r];
        [bg cacheDisplayInRect:r toBitmapImageRep:rep];
        [v cacheDisplayInRect:r toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:png atomically:YES];
        printf("wrote %s\n", png.UTF8String);
    }
    [s stop];
    return 0;
}}
