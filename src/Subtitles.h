// Subtitles: read, decode and draw subtitles independently of the AVPlayer
// audio/video path (which must stay untouched for Atmos rendering).
//
// A second libavformat reader opens the same file, reads only the selected
// subtitle stream around the playhead, and decodes cues with libavcodec:
// text (SubRip, ASS/SSA, WebVTT, mov_text) and bitmaps (PGS, VobSub, DVB).
// External .srt/.ass files next to the video are offered too.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SubtitleTrack : NSObject
@property (readonly) NSString *label;     // menu title
@property (readonly) BOOL forced;
@end

@interface SubtitleCue : NSObject
@property (readonly) double start, end;   // seconds, source timeline
@property (readonly, nullable) NSString *text;
@property (readonly, nullable) CGImageRef image;
@property (readonly) CGRect imageRect;    // in canvas coordinates (top-left origin)
@property (readonly) CGSize canvas;
@end

@interface Subtitles : NSObject
- (instancetype)initWithPath:(NSString *)videoPath;
@property (readonly) NSArray<SubtitleTrack *> *tracks;
/// Track to show by default: the first forced track, else nil (off).
@property (readonly, nullable) SubtitleTrack *defaultTrack;
@property (readonly, nullable) SubtitleTrack *selectedTrack;
- (void)selectTrack:(nullable SubtitleTrack *)track;
/// Cues active at time t (seconds).  Also tells the reader where the playhead is.
- (NSArray<SubtitleCue *> *)cuesAt:(double)t;
- (void)stop;
@end

/// Transparent overlay that draws cues inside `videoRect`.
@interface SubtitleView : NSView
@property (copy) NSArray<SubtitleCue *> *cues;
@property NSRect videoRect;               // in this view's coordinates
@end

NS_ASSUME_NONNULL_END
