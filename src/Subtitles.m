#import "Subtitles.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <stdatomic.h>

// How far behind / ahead of the playhead the embedded-track reader works.
static const double kMaxOpenCue = 10.0;   // longest an image cue is shown without a "clear"
static const double kReadBehind = 6.0, kReadAhead = 30.0;   // behind: longer than nearly any cue; keeps seeks fast on high-bitrate files

@interface SubtitleTrack ()
@property (readwrite) NSString *label;
@property (readwrite) BOOL forced;
@property (readwrite, nullable) NSString *language;
@property BOOL bitmap, sdh;
@property int stream;                       // stream index in the video file, -1 = external file
@property (nullable) NSString *externalPath;
@property int externalStream;               // stream inside the external file (VobSub .idx can hold several), -1 = best
@end
@implementation SubtitleTrack
@end

@interface SubtitleCue ()
@property (readwrite) double start, end;
@property (readwrite, nullable) NSString *text;
@property (readwrite) CGRect imageRect;
@property (readwrite) CGSize canvas;
- (void)takeImage:(CGImageRef)i;   // takes ownership
@end
@implementation SubtitleCue { CGImageRef _img; }
- (CGImageRef)image { return _img; }
- (void)takeImage:(CGImageRef)i { CGImageRelease(_img); _img = i; }
- (void)dealloc { CGImageRelease(_img); }
@end

// ASS dialogue line ("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text")
// -> plain text.  libavcodec delivers every text format (SRT included) this way.
static NSString *plainFromASS(const char *ass) {
    const char *p = ass;
    for (int i = 0; i < 8 && p; i++) { p = strchr(p, ','); if (p) p++; }
    if (!p) p = ass;
    NSMutableString *o = [NSMutableString string];
    while (*p) {
        if (*p == '{') {                                    // override block
            const char *e = strchr(p, '}');
            if (!e) break;
            if (strstr(p, "\\p1") && strstr(p, "\\p1") < e) return nil;   // vector drawing, not text
            p = e + 1; continue;
        }
        if (p[0] == '\\' && (p[1] == 'N' || p[1] == 'n')) { [o appendString:@"\n"]; p += 2; continue; }
        if (p[0] == '\\' && p[1] == 'h') { [o appendString:@" "]; p += 2; continue; }
        const char *q = p;
        while (*q && *q != '{' && *q != '\\') q++;
        if (q == p) q++;
        NSString *s = [[NSString alloc] initWithBytes:p length:q - p encoding:NSUTF8StringEncoding];
        if (s) [o appendString:s];
        p = q;
    }
    NSString *t = [o stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return t.length ? t : nil;
}

// Palettised bitmap (PGS/VobSub/DVB) -> CGImage.  Palette entries are ARGB in native order.
static CGImageRef imageFromRect(const AVSubtitleRect *r) {
    if (r->w <= 0 || r->h <= 0 || !r->data[0] || !r->data[1]) return NULL;
    size_t w = r->w, h = r->h;
    uint8_t *buf = malloc(w * h * 4);
    const uint32_t *pal = (const uint32_t *)r->data[1];
    for (size_t y = 0; y < h; y++)
        for (size_t x = 0; x < w; x++) {
            uint32_t c = pal[r->data[0][y * r->linesize[0] + x]];
            uint32_t a = c >> 24, R = (c >> 16) & 255, G = (c >> 8) & 255, B = c & 255;
            uint8_t *px = buf + (y * w + x) * 4;
            px[0] = R * a / 255; px[1] = G * a / 255; px[2] = B * a / 255; px[3] = a;
        }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    CGContextRelease(ctx); CGColorSpaceRelease(cs); free(buf);
    return img;
}

// "eng", "ger", "en-US" ... -> "en", "de", "en"; nil for missing/undetermined.
// Container metadata strings: UTF-8 per spec, but older files (AVI) may carry Latin-1,
// where @(s) would give nil. Latin-1 decoding never fails.
static NSString *tagString(const char *s) {
    if (!s) return nil;
    return [NSString stringWithUTF8String:s] ?: [NSString stringWithCString:s encoding:NSISOLatin1StringEncoding];
}

static NSString *langCode(NSString *tag) {
    if (!tag.length || [tag isEqualToString:@"und"]) return nil;
    NSString *c = [NSLocale localeWithLocaleIdentifier:tag].languageCode;
    return c.length == 2 ? c : nil;
}

static BOOL isBitmapCodec(enum AVCodecID c) {
    return c == AV_CODEC_ID_HDMV_PGS_SUBTITLE || c == AV_CODEC_ID_DVD_SUBTITLE || c == AV_CODEC_ID_DVB_SUBTITLE;
}

@implementation Subtitles {
    NSString *_path;
    AVFormatContext *_fmt;             // owned by the reader thread after init
    CGSize _videoSize;
    NSLock *_lock;                     // guards everything below
    NSMutableArray<SubtitleCue *> *_cues;
    SubtitleTrack *_sel;
    NSUInteger _gen;
    double _play;
    BOOL _stop;
    NSThread *_thread;
    double _readPos;                   // how far the reader has got (guarded by _lock)
    BOOL _readerEOF;
    int _clockSt;                      // video stream read alongside, to pace the reader
    atomic_bool _interrupt;            // set on seek/track change; aborts a blocking read
}

static int interruptCB(void *opaque) {
    Subtitles *s = (__bridge Subtitles *)opaque;
    return atomic_load(&s->_interrupt) ? 1 : 0;
}

- (instancetype)initWithPath:(NSString *)videoPath {
    if (!(self = [super init])) return nil;
    _path = videoPath;
    _lock = [NSLock new];
    _cues = [NSMutableArray array];
    _clockSt = -1;
    NSMutableArray *tracks = [NSMutableArray array];
    if (avformat_open_input(&_fmt, videoPath.fileSystemRepresentation, NULL, NULL) >= 0 &&
        avformat_find_stream_info(_fmt, NULL) >= 0) {
        int ordinal = 0;
        for (unsigned i = 0; i < _fmt->nb_streams; i++) {
            AVStream *st = _fmt->streams[i];
            AVCodecParameters *p = st->codecpar;
            if (p->codec_type == AVMEDIA_TYPE_VIDEO && _videoSize.width == 0 && !(st->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                _videoSize = CGSizeMake(p->width, p->height);
                _clockSt = (int)i;
            }
            if (p->codec_type != AVMEDIA_TYPE_SUBTITLE || !avcodec_find_decoder(p->codec_id)) continue;
            SubtitleTrack *t = [SubtitleTrack new];
            t.stream = (int)i;
            ordinal++;
            t.bitmap = isBitmapCodec(p->codec_id);
            t.forced = (st->disposition & AV_DISPOSITION_FORCED) != 0;
            AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
            AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
            t.language = lang ? langCode(tagString(lang->value)) : nil;
            t.sdh = (st->disposition & AV_DISPOSITION_HEARING_IMPAIRED) || (title && strstr(title->value, "SDH"));
            if (title && strcasestr(title->value, "forced")) t.forced = YES;
            NSMutableArray *parts = [NSMutableArray array];
            NSString *code = lang ? tagString(lang->value) : nil;
            NSString *name = code ? [NSLocale.currentLocale localizedStringForLanguageCode:code] : nil;
            [parts addObject:name ?: code ?: [NSString stringWithFormat:@"Subtitle %d", ordinal]];
            NSString *titleStr = title && title->value[0] ? tagString(title->value) : nil;
            if (titleStr && ![titleStr isEqualToString:name]) [parts addObject:titleStr];
            else if (t.forced) [parts addObject:@"Forced"];
            if (st->disposition & AV_DISPOSITION_HEARING_IMPAIRED && !(title && strstr(title->value, "SDH"))) [parts addObject:@"SDH"];
            if (t.bitmap) [parts addObject:@"image"];
            t.label = [parts componentsJoinedByString:@" · "];
            [tracks addObject:t];
        }
    }
    [self addExternalTracks:tracks forVideo:videoPath];
    _tracks = tracks;
    if (_fmt) {
        _fmt->interrupt_callback = (AVIOInterruptCB){ interruptCB, (__bridge void *)self };
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
        _thread.name = @"subtitles";
        [_thread start];
    }
    return self;
}

// Lowercase, letters/digits only: "Before Sunset 2004" ~ "Before.Sunset.2004".
static NSString *normName(NSString *s) {
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) [o appendFormat:@"%C", c];
    }
    return o.lowercaseString;
}

// Sidecar subtitles: in the video's folder or a Subs/Subtitles subfolder.  A file
// belongs to the video if the folder holds only one video, or its name (ignoring
// case and punctuation) starts with the video's name.  VobSub .idx files expose
// one track per language inside.
- (void)addExternalTracks:(NSMutableArray *)tracks forVideo:(NSString *)videoPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = videoPath.stringByDeletingLastPathComponent;
    NSString *base = normName(videoPath.lastPathComponent.stringByDeletingPathExtension);
    NSArray *videoExts = @[@"mkv", @"mp4", @"m4v", @"avi", @"mov", @"m2ts", @"ts", @"webm"];
    NSArray *subExts = @[@"srt", @"ass", @"ssa", @"vtt", @"idx"];
    NSArray *top = [fm contentsOfDirectoryAtPath:dir error:nil];
    int videos = 0;
    for (NSString *f in top)
        if ([videoExts containsObject:f.pathExtension.lowercaseString] && ![f.lowercaseString containsString:@"sample"]) videos++;
    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    for (NSString *f in top) {
        NSString *full = [dir stringByAppendingPathComponent:f];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir &&
            ([f caseInsensitiveCompare:@"Subs"] == NSOrderedSame || [f caseInsensitiveCompare:@"Subtitles"] == NSOrderedSame)) {
            for (NSString *g in [fm contentsOfDirectoryAtPath:full error:nil]) [cands addObject:[full stringByAppendingPathComponent:g]];
        } else [cands addObject:full];
    }
    [cands sortUsingSelector:@selector(compare:)];
    for (NSString *path in cands) {
        NSString *f = path.lastPathComponent, *ext = f.pathExtension.lowercaseString;
        if (![subExts containsObject:ext]) continue;
        NSString *stem = f.stringByDeletingPathExtension;
        if (videos != 1 && ![normName(stem) hasPrefix:base]) continue;
        // Trailing name parts: language / forced / sdh, e.g. "Movie.Eng.forced.srt"
        NSString *nameLang = nil; BOOL forced = NO, sdh = NO;
        NSArray *parts = [stem componentsSeparatedByString:@"."];
        for (NSInteger i = (NSInteger)parts.count - 1; i >= 1 && i >= (NSInteger)parts.count - 3; i--) {
            NSString *q = parts[i];
            if ([q caseInsensitiveCompare:@"forced"] == NSOrderedSame) forced = YES;
            else if ([q caseInsensitiveCompare:@"sdh"] == NSOrderedSame) sdh = YES;
            else if (!nameLang && (q.length == 2 || q.length == 3)) nameLang = langCode(q);
        }
        if ([ext isEqualToString:@"idx"]) {
            AVFormatContext *x = NULL;
            if (avformat_open_input(&x, path.fileSystemRepresentation, NULL, NULL) < 0) continue;
            avformat_find_stream_info(x, NULL);
            for (unsigned i = 0; i < x->nb_streams; i++) {
                if (x->streams[i]->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
                AVDictionaryEntry *lang = av_dict_get(x->streams[i]->metadata, "language", NULL, 0);
                SubtitleTrack *t = [SubtitleTrack new];
                t.stream = -1; t.externalPath = path; t.externalStream = (int)i; t.bitmap = YES;
                t.language = lang ? langCode(tagString(lang->value)) : nameLang;
                NSString *name = t.language ? [NSLocale.currentLocale localizedStringForLanguageCode:t.language] : nil;
                // Number the entries: one .idx often holds several tracks of the same language.
                t.label = [NSString stringWithFormat:@"%@ · image %u (external %@)", name ?: @"Subtitle", i + 1, f];
                [tracks addObject:t];
            }
            avformat_close_input(&x);
            continue;
        }
        SubtitleTrack *t = [SubtitleTrack new];
        t.stream = -1; t.externalPath = path; t.externalStream = -1;
        t.language = nameLang; t.forced = forced; t.sdh = sdh;
        NSString *name = t.language ? [NSLocale.currentLocale localizedStringForLanguageCode:t.language] : nil;
        t.label = name ? [NSString stringWithFormat:@"%@ (external %@)", name, f] : [NSString stringWithFormat:@"%@ (external)", f];
        [tracks addObject:t];
    }
}

- (SubtitleTrack *)autoTrackForAudioLanguage:(NSString *)audioLanguage {
    NSMutableArray<NSString *> *mine = [NSMutableArray array];
    for (NSString *p in NSLocale.preferredLanguages) { NSString *c = langCode(p); if (c && ![mine containsObject:c]) [mine addObject:c]; }
    NSString *audio = langCode(audioLanguage);
    BOOL multi = [audioLanguage isEqualToString:@"mul"];   // several spoken languages: treat as foreign
    if (multi || (audio && ![mine containsObject:audio])) {
        // Foreign-language audio: full subtitles in my language (prefer non-SDH).
        for (NSString *L in mine) {
            for (SubtitleTrack *t in _tracks) if ([t.language isEqualToString:L] && !t.forced && !t.sdh) return t;
            for (SubtitleTrack *t in _tracks) if ([t.language isEqualToString:L] && !t.forced) return t;
        }
        return nil;
    }
    // Audio in my language (or unknown): only forced lines, in my language or untagged.
    for (NSString *L in mine)
        for (SubtitleTrack *t in _tracks) if (t.forced && [t.language isEqualToString:L]) return t;
    for (SubtitleTrack *t in _tracks) if (t.forced && !t.language) return t;
    return nil;
}

- (void)stop { [_lock lock]; _stop = YES; [_lock unlock]; atomic_store(&_interrupt, true); }

- (SubtitleTrack *)selectedTrack { [_lock lock]; SubtitleTrack *t = _sel; [_lock unlock]; return t; }

- (void)selectTrack:(SubtitleTrack *)track {
    [_lock lock];
    _sel = track; _gen++;
    [_cues removeAllObjects];
    [_lock unlock];
    atomic_store(&_interrupt, true);
}

- (NSArray<SubtitleCue *> *)cuesAt:(double)t {
    NSMutableArray *active = [NSMutableArray array];
    [_lock lock];
    if (t < _play - 1 || t > _play + 3) {          // a seek: drop stale cues, abort any blocking read
        if (_sel && _sel.stream >= 0) [_cues removeAllObjects];   // sidecar files are loaded whole; keep them
        atomic_store(&_interrupt, true);
    }
    _play = t;
    // Until the reader has passed the playhead, a later "clear" may still be unread.
    BOOL caughtUp = _readerEOF || _readPos >= t || (_sel && _sel.stream < 0);
    for (SubtitleCue *c in caughtUp ? _cues : @[]) {
        double end = isinf(c.end) ? c.start + kMaxOpenCue : c.end;   // bitmap cue whose "clear" isn't read yet
        if (c.start <= t && t < end) [active addObject:c];
    }
    [_lock unlock];
    [active sortUsingComparator:^NSComparisonResult(SubtitleCue *a, SubtitleCue *b) { return a.start < b.start ? NSOrderedAscending : a.start > b.start ? NSOrderedDescending : NSOrderedSame; }];
    return active;
}

// Decode one packet into cues (appended under the lock if the selection is still `gen`).
- (void)decode:(AVPacket *)pk with:(AVCodecContext *)dc tb:(AVRational)tb gen:(NSUInteger)gen {
    AVSubtitle sub; int got = 0;
    if (avcodec_decode_subtitle2(dc, &sub, &got, pk) < 0 || !got) return;
    double base = sub.pts != AV_NOPTS_VALUE ? sub.pts / (double)AV_TIME_BASE : pk->pts * av_q2d(tb);
    double start = base + sub.start_display_time / 1000.0, end;
    if (pk->duration > 0) end = (pk->pts + pk->duration) * av_q2d(tb);
    else if (sub.end_display_time > 0 && sub.end_display_time != UINT32_MAX) end = base + sub.end_display_time / 1000.0;
    else end = INFINITY;   // bitmap formats: shown until the next display set
    CGSize canvas = CGSizeMake(dc->width, dc->height);
    if (canvas.width <= 0 || canvas.height <= 0) canvas = _videoSize.width > 0 ? _videoSize : CGSizeMake(1920, 1080);

    NSMutableArray *add = [NSMutableArray array];
    for (unsigned i = 0; i < sub.num_rects; i++) {
        AVSubtitleRect *r = sub.rects[i];
        SubtitleCue *c = [SubtitleCue new];
        c.start = start; c.end = end; c.canvas = canvas;
        if (r->type == SUBTITLE_BITMAP) {
            CGImageRef img = imageFromRect(r);
            if (!img) continue;
            [c takeImage:img];
            c.imageRect = CGRectMake(r->x, r->y, r->w, r->h);
        } else {
            NSString *s = r->ass ? plainFromASS(r->ass) : (r->text ? @(r->text) : nil);
            if (!s) continue;
            c.text = s;
        }
        [add addObject:c];
    }
    avsubtitle_free(&sub);

    [_lock lock];
    if (gen == _gen) {
        for (SubtitleCue *c in _cues) if (isinf(c.end) && c.start < start) c.end = start;   // close open bitmap cues
        // Avoid duplicates when a window is re-read.
        for (SubtitleCue *c in add) {
            BOOL dup = NO;
            for (SubtitleCue *o in _cues) if (o.start == c.start && ((o.text && [o.text isEqualToString:c.text]) || (o.image && CGRectEqualToRect(o.imageRect, c.imageRect)))) { dup = YES; break; }
            if (!dup) [_cues addObject:c];
        }
    }
    [_lock unlock];
}

static AVCodecContext *openDecoder(AVStream *st) {
    const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
    AVCodecContext *dc = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(dc, st->codecpar);
    dc->pkt_timebase = st->time_base;
    if (avcodec_open2(dc, codec, NULL) < 0) avcodec_free_context(&dc);
    return dc;
}

- (void)loadExternal:(SubtitleTrack *)t gen:(NSUInteger)gen {
    AVFormatContext *f = NULL;
    if (avformat_open_input(&f, t.externalPath.fileSystemRepresentation, NULL, NULL) < 0) return;
    avformat_find_stream_info(f, NULL);
    int si = t.externalStream >= 0 ? t.externalStream : av_find_best_stream(f, AVMEDIA_TYPE_SUBTITLE, -1, -1, NULL, 0);
    AVCodecContext *dc = si >= 0 ? openDecoder(f->streams[si]) : NULL;
    AVPacket *pk = av_packet_alloc();
    while (dc && av_read_frame(f, pk) >= 0) {
        if (pk->stream_index == si) [self decode:pk with:dc tb:f->streams[si]->time_base gen:gen];
        av_packet_unref(pk);
    }
    av_packet_free(&pk);
    if (dc) avcodec_free_context(&dc);
    avformat_close_input(&f);
}

// Reader thread: keeps cues for the selected embedded track loaded from
// (playhead - 15 s) to (playhead + 30 s); re-seeks when the playhead jumps.
- (void)run {
    AVCodecContext *dc = NULL;
    SubtitleTrack *tr = nil;
    NSUInteger cur = NSUIntegerMax;
    double winStart = 0, readPos = -1;
    BOOL eof = NO;
    AVPacket *pk = av_packet_alloc();
    for (;;) {
        @autoreleasepool {
            atomic_store(&_interrupt, false);
            [_lock lock];
            BOOL stop = _stop; SubtitleTrack *want = _sel; NSUInteger gen = _gen; double play = _play;
            [_lock unlock];
            if (stop) break;
            if (gen != cur) {
                cur = gen; tr = want; readPos = -1; eof = NO;
                if (dc) avcodec_free_context(&dc);
                if (tr && tr.stream < 0) [self loadExternal:tr gen:gen];
                else if (tr) {
                    for (unsigned i = 0; i < _fmt->nb_streams; i++)
                        _fmt->streams[i]->discard = ((int)i == tr.stream || (int)i == _clockSt) ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
                    dc = openDecoder(_fmt->streams[tr.stream]);
                }
            }
            if (!tr || tr.stream < 0 || !dc) { [NSThread sleepForTimeInterval:0.1]; continue; }
            // Re-seek on a backward jump, or a forward jump past the read-ahead window
            // (smaller forward jumps are covered by reading on sequentially).
            if (readPos < 0 || play < winStart || (!eof && play > readPos + kReadAhead)) {
                double target = MAX(0, play - kReadBehind);
                av_seek_frame(_fmt, -1, (int64_t)(target * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
                avcodec_flush_buffers(dc);
                winStart = target; readPos = target; eof = NO;
                [_lock lock];
                if (gen == _gen) [_cues removeAllObjects];
                _readPos = target; _readerEOF = NO;
                [_lock unlock];
            }
            if (eof || readPos > play + kReadAhead) { [NSThread sleepForTimeInterval:0.1]; continue; }
            int r = av_read_frame(_fmt, pk);
            if (r == AVERROR_EXIT) continue;                 // interrupted by a seek / track change
            if (r < 0) { eof = YES; [_lock lock]; _readerEOF = YES; [_lock unlock]; continue; }
            AVRational tb = _fmt->streams[pk->stream_index]->time_base;
            // Video packets are read only to pace the reader (each read returns
            // within a frame instead of running to the next subtitle packet).
            if (pk->pts != AV_NOPTS_VALUE) {
                readPos = MAX(readPos, pk->pts * av_q2d(tb));
                [_lock lock]; _readPos = readPos; [_lock unlock];
            }
            if (pk->stream_index == tr.stream) [self decode:pk with:dc tb:tb gen:gen];
            av_packet_unref(pk);
        }
    }
    av_packet_free(&pk);
    if (dc) avcodec_free_context(&dc);
    avformat_close_input(&_fmt);
}

@end

// ---------------------------------------------------------------------------
@implementation SubtitleView

- (NSView *)hitTest:(NSPoint)p { return nil; }   // never steal clicks from the player controls

- (void)drawRect:(NSRect)dirty {
    NSRect vr = self.videoRect;
    if (vr.size.width <= 0 || vr.size.height <= 0) return;
    CGContextRef g = NSGraphicsContext.currentContext.CGContext;
    NSMutableArray *lines = [NSMutableArray array];
    for (SubtitleCue *c in self.cues) {
        if (c.image) {
            double sx = vr.size.width / c.canvas.width, sy = vr.size.height / c.canvas.height;
            CGRect r = c.imageRect;
            CGRect dst = CGRectMake(vr.origin.x + r.origin.x * sx,
                                    vr.origin.y + vr.size.height - (r.origin.y + r.size.height) * sy,
                                    r.size.width * sx, r.size.height * sy);
            CGContextSetInterpolationQuality(g, kCGInterpolationHigh);
            CGContextDrawImage(g, dst, c.image);
        } else if (c.text) [lines addObject:c.text];
    }
    if (!lines.count) return;
    NSString *text = [lines componentsJoinedByString:@"\n"];
    CGFloat fs = MAX(14, vr.size.height * 0.055);
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSFont *font = [NSFont systemFontOfSize:fs weight:NSFontWeightMedium];
    NSDictionary *fill = @{NSFontAttributeName: font, NSForegroundColorAttributeName: NSColor.whiteColor, NSParagraphStyleAttributeName: ps};
    NSMutableDictionary *outline = [fill mutableCopy];
    outline[NSStrokeColorAttributeName] = [NSColor colorWithWhite:0 alpha:0.9];
    outline[NSStrokeWidthAttributeName] = @(16);   // percent of font size; positive = stroke only
    CGFloat w = vr.size.width * 0.9;
    NSRect br = [text boundingRectWithSize:NSMakeSize(w, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin attributes:fill];
    NSRect box = NSMakeRect(NSMidX(vr) - w / 2, vr.origin.y + vr.size.height * 0.06, w, ceil(br.size.height));
    [text drawWithRect:box options:NSStringDrawingUsesLineFragmentOrigin attributes:outline];
    [text drawWithRect:box options:NSStringDrawingUsesLineFragmentOrigin attributes:fill];
}
@end
