#import "Segmenter.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libswresample/swresample.h>

// ---------------------------------------------------------------------------
// Tunables
static const double kTargetSegmentSeconds = 6.0;
// Constant presentation offset added to every output timestamp.  Decode
// timestamps of video are synthesised from sorted PTS, so PTS must lead DTS
// by at least the B-frame reorder depth for composition offsets to stay >= 0.
static const int64_t kPresentationOffsetUs = 500000;
// How far before a segment's start we seek, so interleaved audio that
// precedes the video keyframe in the file is not missed.
static const int64_t kSeekMarginUs = 2000000;

// ---------------------------------------------------------------------------
// Small growable packet list
typedef struct { AVPacket **p; int n, cap; } PktList;
static void pl_push(PktList *l, AVPacket *pk) {
    if (l->n == l->cap) { l->cap = l->cap ? l->cap * 2 : 256; l->p = realloc(l->p, sizeof(AVPacket *) * l->cap); }
    l->p[l->n++] = pk;
}
static void pl_free(PktList *l) { for (int i = 0; i < l->n; i++) av_packet_free(&l->p[i]); free(l->p); *l = (PktList){0}; }
static int cmp_i64(const void *a, const void *b) { int64_t x = *(const int64_t *)a, y = *(const int64_t *)b; return (x > y) - (x < y); }

// ---------------------------------------------------------------------------
// Big-endian box writer
@interface BoxWriter : NSObject { @public NSMutableData *d; }
@end
@implementation BoxWriter
- (instancetype)init { if ((self = [super init])) d = [NSMutableData data]; return self; }
- (void)u8:(uint8_t)v { [d appendBytes:&v length:1]; }
- (void)u32:(uint32_t)v { uint32_t b = CFSwapInt32HostToBig(v); [d appendBytes:&b length:4]; }
- (void)u64:(uint64_t)v { uint64_t b = CFSwapInt64HostToBig(v); [d appendBytes:&b length:8]; }
- (NSUInteger)begin:(const char *)type { NSUInteger at = d.length; [self u32:0]; [d appendBytes:type length:4]; return at; }
- (void)end:(NSUInteger)at { uint32_t sz = CFSwapInt32HostToBig((uint32_t)(d.length - at)); [d replaceBytesInRange:NSMakeRange(at, 4) withBytes:&sz]; }
- (void)patch32:(NSUInteger)at value:(uint32_t)v { uint32_t b = CFSwapInt32HostToBig(v); [d replaceBytesInRange:NSMakeRange(at, 4) withBytes:&b]; }
@end

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

// Find a child box of the given type inside [p, p+len).  Returns pointer to box start.
static const uint8_t *findBox(const uint8_t *p, size_t len, const char *type, size_t *boxLen) {
    size_t o = 0;
    while (o + 8 <= len) {
        uint32_t sz = rd32(p + o);
        if (sz < 8 || o + sz > len) return NULL;
        if (memcmp(p + o + 4, type, 4) == 0) { *boxLen = sz; return p + o; }
        o += sz;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
typedef struct {
    int st;              // input stream index (-1 if absent)
    AVRational tb;       // input time base
    uint32_t trackID;    // output track id (from generated moov)
    uint32_t timescale;  // output media timescale (from generated moov)
    int frameSize;       // audio samples per packet when constant (0 otherwise)
} Track;

@implementation Segmenter {
    NSString *_path;
    AVFormatContext *_fmt;
    Track _v, _a;
    int64_t *_starts;     // segment start times in microseconds; _starts[_nseg] = INT64_MAX
    NSUInteger _nseg;
    NSData *_init;
    NSCache<NSNumber *, NSData *> *_cache;
    NSString *_playlist;
    // Fallback for audio AVPlayer cannot take as-is (TrueHD, DTS, FLAC, PCM, ...):
    // decode with libavcodec and re-encode losslessly to ALAC (stereo or 5.1).
    BOOL _transcode;
    AVCodecContext *_dec;
    AVChannelLayout _outLayout;
    int _outRate;
    // Leading-gap filler for passthrough E-AC-3/AC-3 whose audio starts after the
    // video: AVPlayer will not start until every track has data, so it would skip
    // the opening.  Silent frames (one encoded frame, repeated) cover the gap.
    AVPacket *_silence;
    int64_t _firstAudioPts, _silenceDur;   // audio time base
}

static void *const kSynthetic = (void *)&kSynthetic;   // AVPacket.opaque tag for filler frames
static int realCount(const PktList *l) { int n = 0; for (int i = 0; i < l->n; i++) n += l->p[i]->opaque != kSynthetic; return n; }

static NSError *mkerr(NSString *msg) {
    return [NSError errorWithDomain:@"PlayAtmos" code:1 userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static BOOL isAtmosEAC3(const AVCodecParameters *p) {
    return p->codec_id == AV_CODEC_ID_EAC3 && p->profile == AV_PROFILE_EAC3_DDP_ATMOS;
}

// Score audio tracks: genuine Atmos that Apple can render wins outright.
static int audioScore(const AVStream *s) {
    const AVCodecParameters *p = s->codecpar;
    int score;
    switch (p->codec_id) {
        case AV_CODEC_ID_EAC3: score = isAtmosEAC3(p) ? 1000 : 300; break;
        case AV_CODEC_ID_AC3:  score = 200; break;
        case AV_CODEC_ID_AAC:  score = 100; break;
        // Needs decode + ALAC re-encode.  Lossless sources outrank lossy passthrough
        // (but never E-AC-3 JOC, the only format Apple renders as Atmos).
        case AV_CODEC_ID_TRUEHD: case AV_CODEC_ID_MLP: case AV_CODEC_ID_FLAC:
        case AV_CODEC_ID_DTS: case AV_CODEC_ID_ALAC:
            score = 400; break;
        default:
            if (!avcodec_find_decoder(p->codec_id)) return -1;
            score = (p->codec_id >= AV_CODEC_ID_PCM_S16LE && p->codec_id < AV_CODEC_ID_ADPCM_IMA_QT) ? 400 : 50;
    }
    score += p->ch_layout.nb_channels * 10;
    if (s->disposition & AV_DISPOSITION_DEFAULT) score += 5;
    return score;
}

+ (instancetype)segmenterWithPath:(NSString *)path error:(NSError **)error {
    Segmenter *s = [[Segmenter alloc] init];
    s->_path = path;
    NSString *msg = [s open];
    if (msg) { if (error) *error = mkerr(msg); return nil; }
    return s;
}

- (void)dealloc {
    if (_silence) av_packet_free(&_silence);
    if (_dec) avcodec_free_context(&_dec);
    av_channel_layout_uninit(&_outLayout);
    if (_fmt) avformat_close_input(&_fmt);
    free(_starts);
}

- (NSString *)open {
    av_log_set_level(AV_LOG_ERROR);
    // Analyse further than FFmpeg's default (~5 s): some files start their audio
    // late (e.g. at 9 s), and E-AC-3 Atmos (JOC) is only detected by decoding a frame.
    AVDictionary *oo = NULL;
    av_dict_set(&oo, "analyzeduration", "30000000", 0);   // 30 s
    av_dict_set(&oo, "probesize", "100000000", 0);         // 100 MB
    int orc = avformat_open_input(&_fmt, _path.fileSystemRepresentation, NULL, &oo);
    av_dict_free(&oo);
    if (orc < 0) return @"Could not open file.";
    if (avformat_find_stream_info(_fmt, NULL) < 0) return @"Could not read stream info.";

    _v.st = -1; _a.st = -1;
    for (unsigned i = 0; i < _fmt->nb_streams; i++) {
        AVStream *st = _fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || (st->disposition & AV_DISPOSITION_ATTACHED_PIC)) continue;
        enum AVCodecID c = st->codecpar->codec_id;
        if (c == AV_CODEC_ID_H264 || c == AV_CODEC_ID_HEVC || c == AV_CODEC_ID_AV1) { _v.st = (int)i; break; }
        if (_v.st < 0) _videoSummary = [NSString stringWithFormat:@"%s video is not supported by AVFoundation", avcodec_get_name(c)];
    }
    int best = -1;
    for (unsigned i = 0; i < _fmt->nb_streams; i++) {
        AVStream *st = _fmt->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) continue;
        int sc = audioScore(st);
        if (sc > best) { best = sc; _a.st = (int)i; }
    }
    if (_v.st < 0 && _a.st < 0) return @"No playable video or audio stream (supported: H.264/HEVC/AV1 video; E-AC-3, AC-3, AAC audio).";

    if (_v.st >= 0) {
        AVCodecParameters *p = _fmt->streams[_v.st]->codecpar;
        _v.tb = _fmt->streams[_v.st]->time_base;
        _videoSummary = [NSString stringWithFormat:@"%s %dx%d", avcodec_get_name(p->codec_id), p->width, p->height];
    }
    if (_a.st >= 0) {
        AVStream *st = _fmt->streams[_a.st];
        AVCodecParameters *p = st->codecpar;
        _a.tb = st->time_base;
        _a.frameSize = p->frame_size;
        AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
        if (lang && lang->value[0] && strcmp(lang->value, "und")) _audioLanguage = @(lang->value);
        _atmosPassthrough = isAtmosEAC3(p);
        _transcode = p->codec_id != AV_CODEC_ID_EAC3 && p->codec_id != AV_CODEC_ID_AC3 && p->codec_id != AV_CODEC_ID_AAC;
        const char *prof = avcodec_profile_name(p->codec_id, p->profile);
        if (_atmosPassthrough) {
            _audioSummary = [NSString stringWithFormat:@"E-AC-3 JOC (Dolby Atmos), %d ch bed, passthrough", p->ch_layout.nb_channels];
        } else if (!_transcode) {
            _audioSummary = [NSString stringWithFormat:@"%s%s%s %d ch, passthrough", avcodec_get_name(p->codec_id),
                             prof ? " " : "", prof ? prof : "", p->ch_layout.nb_channels];
        } else {
            NSString *e = [self setupTranscode];
            if (e) return e;
            BOOL thdAtmos = p->codec_id == AV_CODEC_ID_TRUEHD && p->profile == AV_PROFILE_TRUEHD_ATMOS;
            _audioSummary = [NSString stringWithFormat:@"%s%s%s %d ch → ALAC %d ch (lossless re-encode)%s", avcodec_get_name(p->codec_id),
                             prof ? " " : "", prof ? prof : "", p->ch_layout.nb_channels, _outLayout.nb_channels,
                             thdAtmos ? " — TrueHD Atmos objects NOT rendered, bed only" : ""];
        }
    } else {
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned i = 0; i < _fmt->nb_streams; i++)
            if (_fmt->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO)
                [names addObject:@(avcodec_get_name(_fmt->streams[i]->codecpar->codec_id))];
        _audioSummary = names.count ? [NSString stringWithFormat:@"no playable audio (file has: %@)", [names componentsJoinedByString:@", "]] : @"no audio";
    }

    _duration = _fmt->duration > 0 ? _fmt->duration / (double)AV_TIME_BASE : 0;
    if (_duration <= 0) return @"File has unknown duration.";
    [self buildSegments];

    [self prepareLeadingSilence];
    _cache = [NSCache new];
    _cache.countLimit = 6;
    if (![self buildInit]) return @"Could not generate MP4 initialization segment.";
    return nil;
}

// Segment boundaries: group the container's keyframe index (Matroska Cues)
// into ~6 s segments.  Without an index, use a fixed grid; each segment then
// starts at the first keyframe at/after its grid time (same rule on both
// sides of every boundary, so segments always tile exactly).
- (void)buildSegments {
    int64_t start = _fmt->start_time != AV_NOPTS_VALUE ? _fmt->start_time : 0;
    int64_t end = start + _fmt->duration;
    int64_t target = (int64_t)(kTargetSegmentSeconds * AV_TIME_BASE);
    NSMutableArray<NSNumber *> *b = [NSMutableArray array];

    if (_v.st >= 0) {
        AVStream *st = _fmt->streams[_v.st];
        // Matroska loads Cues lazily, on the first seek.
        av_seek_frame(_fmt, _v.st, av_rescale_q(start + _fmt->duration / 2, AV_TIME_BASE_Q, st->time_base), AVSEEK_FLAG_BACKWARD);
        int n = avformat_index_get_entries_count(st);
        int64_t *kf = malloc(sizeof(int64_t) * (n + 1)); int nk = 0;
        for (int i = 0; i < n; i++) {
            const AVIndexEntry *e = avformat_index_get_entry(st, i);
            if (e->flags & AVINDEX_KEYFRAME) kf[nk++] = av_rescale_q(e->timestamp, st->time_base, AV_TIME_BASE_Q);
        }
        qsort(kf, nk, sizeof(int64_t), cmp_i64);
        if (nk > 1 && (double)(end - start) / nk < 30.0 * AV_TIME_BASE) {   // a usable index
            int64_t last = INT64_MIN;
            for (int i = 0; i < nk; i++) {
                if (kf[i] >= end) break;
                if (last == INT64_MIN || kf[i] - last >= target) { [b addObject:@(kf[i])]; last = kf[i]; }
            }
        }
        free(kf);
    }
    if (b.count == 0) for (int64_t t = start; t < end; t += target) [b addObject:@(t)];
    // Avoid a tiny trailing segment.
    if (b.count > 1 && end - b.lastObject.longLongValue < target / 3) [b removeLastObject];

    _nseg = b.count;
    _starts = malloc(sizeof(int64_t) * (_nseg + 1));
    for (NSUInteger i = 0; i < _nseg; i++) _starts[i] = b[i].longLongValue;
    _starts[_nseg] = INT64_MAX;

    NSMutableString *m = [NSMutableString string];
    double maxDur = 0;
    for (NSUInteger i = 0; i < _nseg; i++) {
        int64_t s0 = i == 0 ? start : _starts[i];
        int64_t s1 = i + 1 < _nseg ? _starts[i + 1] : end;
        double d = (s1 - s0) / (double)AV_TIME_BASE;
        maxDur = MAX(maxDur, d);
        [m appendFormat:@"#EXTINF:%.6f,\nseg%lu.m4s\n", d, (unsigned long)i];
    }
    _playlist = [NSString stringWithFormat:
                 @"#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:%d\n#EXT-X-MEDIA-SEQUENCE:0\n"
                  "#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n%@#EXT-X-ENDLIST\n",
                 (int)ceil(maxDur), m];
}

- (void)prepareLeadingSilence {
    if (_a.st < 0 || _transcode) return;
    AVCodecParameters *p = _fmt->streams[_a.st]->codecpar;
    if (p->codec_id != AV_CODEC_ID_EAC3 && p->codec_id != AV_CODEC_ID_AC3) return;
    // First audio and first video timestamps.
    avformat_seek_file(_fmt, -1, INT64_MIN, INT64_MIN, INT64_MIN, 0);
    int64_t firstA = AV_NOPTS_VALUE, firstVus = INT64_MAX;
    AVPacket *pk = av_packet_alloc();
    for (int i = 0; i < 20000 && firstA == AV_NOPTS_VALUE && av_read_frame(_fmt, pk) >= 0; i++) {
        int64_t t = pktTime(pk);
        if (t != AV_NOPTS_VALUE) {
            if (pk->stream_index == _a.st) firstA = t;
            else if (pk->stream_index == _v.st) firstVus = MIN(firstVus, av_rescale_q(t, _v.tb, AV_TIME_BASE_Q));
        }
        av_packet_unref(pk);
    }
    av_packet_free(&pk);
    if (firstA == AV_NOPTS_VALUE) return;
    int64_t startUs = firstVus != INT64_MAX ? firstVus : (_fmt->start_time != AV_NOPTS_VALUE ? _fmt->start_time : 0);
    if (av_rescale_q(firstA, _a.tb, AV_TIME_BASE_Q) - startUs < 50000) return;   // no meaningful gap

    // Encode one silent frame with FFmpeg's (E-)AC-3 encoder.
    const AVCodec *ec = avcodec_find_encoder(p->codec_id);
    AVCodecContext *e = ec ? avcodec_alloc_context3(ec) : NULL;
    if (!e) return;
    e->sample_rate = p->sample_rate;
    e->sample_fmt = AV_SAMPLE_FMT_FLTP;
    e->bit_rate = 192000;
    e->ch_layout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1;
    e->time_base = (AVRational){1, p->sample_rate};
    if (avcodec_open2(e, ec, NULL) >= 0) {
        AVFrame *fr = av_frame_alloc();
        AVPacket *out = av_packet_alloc();
        for (int i = 0; i < 4; i++) {
            fr->nb_samples = e->frame_size; fr->format = e->sample_fmt; fr->sample_rate = e->sample_rate;
            av_channel_layout_copy(&fr->ch_layout, &e->ch_layout);
            av_frame_get_buffer(fr, 0);
            for (int c = 0; c < fr->ch_layout.nb_channels; c++) memset(fr->extended_data[c], 0, fr->nb_samples * 4);
            fr->pts = (int64_t)i * e->frame_size;
            avcodec_send_frame(e, fr);
            av_frame_unref(fr);
            while (avcodec_receive_packet(e, out) >= 0) {
                if (_silence) av_packet_free(&_silence);
                _silence = av_packet_clone(out);
                av_packet_unref(out);
            }
        }
        av_packet_free(&out); av_frame_free(&fr);
        _silenceDur = av_rescale_q(e->frame_size, (AVRational){1, p->sample_rate}, _a.tb);
    }
    avcodec_free_context(&e);
    if (!_silence || _silenceDur <= 0) { if (_silence) av_packet_free(&_silence); return; }
    _firstAudioPts = firstA;
    // Filler frames run back from the first real frame, so they join it seamlessly.
    _audioSummary = [_audioSummary stringByAppendingFormat:@" (silence added before audio starts at %.2f s)", firstA * av_q2d(_a.tb)];
}

- (NSUInteger)segmentCount { return _nseg; }
- (NSString *)playlist { return _playlist; }
- (NSData *)initializationSegment { return _init; }

static int64_t pktTime(const AVPacket *p) { return p->pts != AV_NOPTS_VALUE ? p->pts : p->dts; }

// Read the packets belonging to segment k.  Video: from the first keyframe
// with pts >= start(k) up to (excluding) the first keyframe with
// pts >= start(k+1).  Audio: packets with pts in [start(k), start(k+1)).
// *vNext / *aNext receive the pts of the first packet of the next segment
// (AV_NOPTS_VALUE at end of file), used for the last sample's duration.
- (void)collect:(NSUInteger)k video:(PktList *)vl audio:(PktList *)al vNext:(int64_t *)vNext aNext:(int64_t *)aNext {
    [self collect:k video:vl audio:al vNext:vNext aNext:aNext eof:NULL];
}

- (void)collect:(NSUInteger)k video:(PktList *)vl audio:(PktList *)al vNext:(int64_t *)vNext aNext:(int64_t *)aNext eof:(BOOL *)eof {
    int64_t s0 = _starts[k], s1 = _starts[k + 1];
    // Transcoded audio is trimmed sample-accurately after decoding, so collect
    // packets with decoder pre-roll before s0 and a margin past s1.
    int64_t a0 = _transcode ? s0 - 1000000 : s0;
    int64_t a1 = _transcode && s1 != INT64_MAX ? s1 + 200000 : s1;
    if (eof) *eof = NO;
    *vNext = *aNext = AV_NOPTS_VALUE;
    int seekSt = _v.st >= 0 ? _v.st : _a.st;
    AVRational stb = _fmt->streams[seekSt]->time_base;
    int64_t ts = av_rescale_q(s0 - kSeekMarginUs, AV_TIME_BASE_Q, stb);
    if (avformat_seek_file(_fmt, seekSt, INT64_MIN, ts, ts, 0) < 0)
        avformat_seek_file(_fmt, seekSt, INT64_MIN, INT64_MIN, INT64_MIN, 0);

    int vState = _v.st >= 0 ? 0 : 2;   // 0 waiting for keyframe, 1 collecting, 2 done
    BOOL aDone = _a.st < 0;
    AVPacket *pk = av_packet_alloc();
    for (;;) {
        if (vState == 2 && aDone) break;
        if (av_read_frame(_fmt, pk) < 0) { if (eof) *eof = YES; break; }
        int64_t t = pktTime(pk);
        if (t == AV_NOPTS_VALUE) { av_packet_unref(pk); continue; }
        if (pk->stream_index == _v.st && vState != 2) {
            int64_t us = av_rescale_q(t, _v.tb, AV_TIME_BASE_Q);
            BOOL key = (pk->flags & AV_PKT_FLAG_KEY) != 0;
            if (vState == 0 && key && us >= s0) vState = 1;
            if (vState == 1 && key && us >= s1 && vl->n > 0) { *vNext = t; vState = 2; }
            if (vState == 1) { pl_push(vl, av_packet_clone(pk)); }
        } else if (pk->stream_index == _a.st && !aDone) {
            int64_t us = av_rescale_q(t, _a.tb, AV_TIME_BASE_Q);
            if (us >= a1) { *aNext = t; aDone = YES; }
            else if (us >= a0) pl_push(al, av_packet_clone(pk));
        }
        av_packet_unref(pk);
    }
    av_packet_free(&pk);
    if (_silence) {   // prepend filler frames that fall in this segment's audio window
        PktList syn = {0};
        int64_t startTb = av_rescale_q(_starts[0], AV_TIME_BASE_Q, _a.tb);
        int64_t n = (_firstAudioPts - startTb + _silenceDur - 1) / _silenceDur;
        for (int64_t j = n; j >= 1; j--) {
            int64_t pts = _firstAudioPts - j * _silenceDur;
            int64_t us = av_rescale_q(pts, _a.tb, AV_TIME_BASE_Q);
            if (us < a0 || us >= a1) continue;
            AVPacket *q = av_packet_clone(_silence);
            q->pts = q->dts = pts; q->duration = _silenceDur; q->stream_index = _a.st; q->opaque = kSynthetic;
            pl_push(&syn, q);
        }
        if (syn.n) {
            for (int i = 0; i < al->n; i++) pl_push(&syn, al->p[i]);
            free(al->p);
            *al = syn;
        }
    }
}

// --- Transcode fallback ----------------------------------------------------
- (NSString *)setupTranscode {
    AVCodecParameters *p = _fmt->streams[_a.st]->codecpar;
    const AVCodec *dc = avcodec_find_decoder(p->codec_id);
    if (!dc) return @"No decoder for the audio track.";
    _dec = avcodec_alloc_context3(dc);
    avcodec_parameters_to_context(_dec, p);
    _dec->pkt_timebase = _a.tb;
    if (avcodec_open2(_dec, dc, NULL) < 0) return @"Could not open the audio decoder.";
    _outRate = p->sample_rate;
    // Stereo/mono stay as they are; anything else becomes 5.1 (7.1 rears folded
    // into the side surrounds).  ALAC's 8-channel layout is "7.1 wide" (front
    // Lc/Rc), so true 7.1 cannot be carried.
    if (p->ch_layout.nb_channels <= 2) av_channel_layout_default(&_outLayout, p->ch_layout.nb_channels);
    else _outLayout = (AVChannelLayout)AV_CHANNEL_LAYOUT_5POINT1_BACK;
    return nil;
}

- (AVCodecContext *)newEncoder {
    const AVCodec *ec = avcodec_find_encoder(AV_CODEC_ID_ALAC);
    AVCodecContext *e = avcodec_alloc_context3(ec);
    e->sample_rate = _outRate;
    e->sample_fmt = AV_SAMPLE_FMT_S32P;
    e->bits_per_raw_sample = 24;
    av_channel_layout_copy(&e->ch_layout, &_outLayout);
    e->time_base = (AVRational){1, _outRate};
    if (avcodec_open2(e, ec, NULL) < 0) avcodec_free_context(&e);
    return e;
}

// Decode `raw` and keep exactly the samples [ceil(s0*sr), ceil(s1*sr)) of segment k,
// then encode them to ALAC.  Output packets get pts in samples (1/sr).
- (void)transcodeSegment:(NSUInteger)k raw:(PktList *)raw eof:(BOOL)eof out:(PktList *)out firstSample:(int64_t *)firstSample {
    const int64_t sr = _outRate;
    int64_t n0 = av_rescale_rnd(_starts[k], sr, AV_TIME_BASE, AV_ROUND_UP);
    int64_t n1 = k + 1 < _nseg ? av_rescale_rnd(_starts[k + 1], sr, AV_TIME_BASE, AV_ROUND_UP) : INT64_MAX;
    *firstSample = n0;
    const int nch = _outLayout.nb_channels;
    // Encoder input slot order.  Measured with per-channel tones through
    // AVPlayer: for 6-channel ALAC Apple assigns slots as C, L, R, LFE, Ls, Rs.
    static const int map51[6] = { 2, 0, 1, 3, 4, 5 };   // slot -> index in FL FR FC LFE BL BR
    SwrContext *swr = NULL;
    swr_alloc_set_opts2(&swr, &_outLayout, AV_SAMPLE_FMT_S32P, (int)sr, &_dec->ch_layout, _dec->sample_fmt, _dec->sample_rate, 0, NULL);
    if (!swr || swr_init(swr) < 0) { swr_free(&swr); return; }

    size_t cap = 0, have = 0;
    int32_t **pcm = calloc(nch, sizeof(int32_t *));
    int64_t pos = AV_NOPTS_VALUE;   // sample index of the next decoded sample
    BOOL done = NO;
    avcodec_flush_buffers(_dec);
    AVFrame *fr = av_frame_alloc();
    int32_t *tmp[8] = {0}; int tmpCap = 0;
    for (int i = 0; i <= raw->n && !done; i++) {
        if (i < raw->n) { if (avcodec_send_packet(_dec, raw->p[i]) < 0) continue; }
        else if (eof) avcodec_send_packet(_dec, NULL);
        else break;
        while (!done && avcodec_receive_frame(_dec, fr) >= 0) {
            if (pos == AV_NOPTS_VALUE) {
                int64_t t = fr->best_effort_timestamp;
                if (t == AV_NOPTS_VALUE) { av_frame_unref(fr); continue; }
                // Container timestamps are often ms-rounded: snap to the codec's frame
                // grid, anchored at the stream's first timestamp, so every segment
                // derives the same sample positions (exact for constant frame sizes).
                int64_t st0 = _fmt->streams[_a.st]->start_time;
                if (st0 == AV_NOPTS_VALUE) st0 = 0;
                AVRational str = (AVRational){1, (int)sr};
                int64_t base = av_rescale_q(st0, _a.tb, str), rel = av_rescale_q(t - st0, _a.tb, str);
                if (fr->nb_samples > 0) rel = (rel + fr->nb_samples / 2) / fr->nb_samples * fr->nb_samples;
                pos = base + rel;
            }
            if (fr->nb_samples > tmpCap) { tmpCap = fr->nb_samples; for (int c = 0; c < nch; c++) tmp[c] = realloc(tmp[c], tmpCap * 4); }
            int got = swr_convert(swr, (uint8_t **)tmp, tmpCap, (const uint8_t **)fr->extended_data, fr->nb_samples);
            for (int j = 0; j < got; j++, pos++) {
                if (pos < n0) continue;
                if (pos >= n1) { done = YES; break; }
                while (n0 + (int64_t)have < pos) {   // gap in the source audio: pad with silence
                    if (have == cap) { cap = cap ? cap * 2 : 1 << 16; for (int c = 0; c < nch; c++) pcm[c] = realloc(pcm[c], cap * 4); }
                    for (int c = 0; c < nch; c++) pcm[c][have] = 0;
                    have++;
                }
                if (have == cap) { cap = cap ? cap * 2 : 1 << 16; for (int c = 0; c < nch; c++) pcm[c] = realloc(pcm[c], cap * 4); }
                for (int c = 0; c < nch; c++) pcm[c][have] = tmp[nch == 6 ? map51[c] : c][j];
                have++;
            }
            av_frame_unref(fr);
        }
    }
    for (int c = 0; c < 8; c++) free(tmp[c]);
    swr_free(&swr);

    AVCodecContext *enc = [self newEncoder];
    AVPacket *pk = av_packet_alloc();
    for (size_t off = 0; enc && off <= have; ) {
        if (off < have) {
            int n = (int)MIN((size_t)enc->frame_size, have - off);
            fr->nb_samples = n; fr->format = AV_SAMPLE_FMT_S32P; fr->sample_rate = (int)sr;
            av_channel_layout_copy(&fr->ch_layout, &_outLayout);
            av_frame_get_buffer(fr, 0);
            for (int c = 0; c < nch; c++) memcpy(fr->extended_data[c], pcm[c] + off, n * 4);
            fr->pts = (int64_t)off;
            avcodec_send_frame(enc, fr);
            av_frame_unref(fr);
            off += n;
        } else { avcodec_send_frame(enc, NULL); off++; }
        while (avcodec_receive_packet(enc, pk) >= 0) {
            AVPacket *q = av_packet_clone(pk);
            q->pts = q->dts = n0 + pk->pts;
            pl_push(out, q);
            av_packet_unref(pk);
        }
    }
    av_packet_free(&pk);
    av_frame_free(&fr);
    if (enc) avcodec_free_context(&enc);
    for (int c = 0; c < nch; c++) free(pcm[c]);
    free(pcm);
}

// Per-sample output timing for one track, in the output track timescale.
typedef struct { uint64_t baseDts; uint32_t *dur; int32_t *cto; } Timing;

- (Timing)timingFor:(Track *)tr packets:(PktList *)l next:(int64_t)next video:(BOOL)isVideo {
    Timing T = { 0, calloc(l->n, 4), calloc(l->n, 4) };
    if (l->n == 0) return T;
    AVRational ots = (AVRational){1, (int)tr->timescale};
    int64_t off = av_rescale_q(kPresentationOffsetUs, AV_TIME_BASE_Q, tr->tb);
#define R(x) av_rescale_q((x), tr->tb, ots)
    if (isVideo) {
        // Decode times = presentation times sorted ascending (tiles exactly across segments).
        int64_t *sorted = malloc(sizeof(int64_t) * (l->n + 1));
        for (int i = 0; i < l->n; i++) sorted[i] = pktTime(l->p[i]);
        qsort(sorted, l->n, sizeof(int64_t), cmp_i64);
        int64_t endT = next;
        if (endT == AV_NOPTS_VALUE) {
            int64_t d = l->p[l->n - 1]->duration;
            if (d <= 0) d = l->n > 1 ? (sorted[l->n - 1] - sorted[0]) / (l->n - 1) : 1;
            endT = sorted[l->n - 1] + d;
        }
        sorted[l->n] = endT;
        T.baseDts = (uint64_t)R(sorted[0]);
        for (int i = 0; i < l->n; i++) {
            int64_t dts = R(sorted[i]);
            T.dur[i] = (uint32_t)MAX(1, R(sorted[i + 1]) - dts);
            int64_t c = R(pktTime(l->p[i]) + off) - dts;
            T.cto[i] = (int32_t)MAX(0, c);
        }
        free(sorted);
    } else if (_transcode) {
        AVRational str = (AVRational){1, _outRate};
        T.baseDts = (uint64_t)(av_rescale_q(l->p[0]->pts, str, ots) + av_rescale_q(kPresentationOffsetUs, AV_TIME_BASE_Q, ots));
        for (int i = 0; i < l->n; i++) T.dur[i] = (uint32_t)MAX(1, av_rescale_q(l->p[i]->duration, str, ots));
    } else {
        T.baseDts = (uint64_t)MAX(0, R(pktTime(l->p[0]) + off));
        BOOL constFrames = tr->frameSize > 0 && (int)tr->timescale == _fmt->streams[tr->st]->codecpar->sample_rate;
        for (int i = 0; i < l->n; i++) {
            if (constFrames) { T.dur[i] = (uint32_t)tr->frameSize; continue; }
            int64_t t0 = pktTime(l->p[i]);
            int64_t t1 = i + 1 < l->n ? pktTime(l->p[i + 1]) : (next != AV_NOPTS_VALUE ? next : t0 + l->p[i]->duration);
            T.dur[i] = (uint32_t)MAX(1, R(t1) - R(t0));
        }
    }
#undef R
    return T;
}

// --- Init segment: let libavformat's mp4 muxer build the moov (it writes
// correct avcC/hvcC and a dec3 box including the JOC extension), then keep
// only ftyp+moov and read back the track ids and timescales it chose.
static int memWrite(void *opaque, const uint8_t *buf, int size) {
    [(__bridge NSMutableData *)opaque appendBytes:buf length:size];
    return size;
}

// 'hev1' sources carry VPS/SPS/PPS in-band and an hvcC with no parameter-set
// arrays; under 'hvc1' AVFoundation needs them in hvcC.  Extract them from the
// first keyframe and hand them to the muxer as Annex-B extradata (movenc
// converts that into a complete hvcC).
static void fillHEVCParameterSets(AVCodecParameters *par, const AVPacket *key) {
    const uint8_t *x = par->extradata;
    BOOL hvcc = par->extradata_size >= 23 && x[0] == 1;
    if (!hvcc || x[22] != 0) return;            // Annex-B, or arrays already present
    int lenSize = (x[21] & 3) + 1;
    NSMutableData *annexb = [NSMutableData data];
    static const uint8_t sc[4] = {0, 0, 0, 1};
    for (int o = 0; o + lenSize <= key->size; ) {
        uint32_t n = 0;
        for (int i = 0; i < lenSize; i++) n = n << 8 | key->data[o + i];
        o += lenSize;
        if (n == 0 || o + (int)n > key->size) break;
        int type = (key->data[o] >> 1) & 0x3f;
        if (type >= 32 && type <= 34) { [annexb appendBytes:sc length:4]; [annexb appendBytes:key->data + o length:n]; }
        o += (int)n;
    }
    if (annexb.length == 0) return;
    av_freep(&par->extradata);
    par->extradata = av_mallocz(annexb.length + AV_INPUT_BUFFER_PADDING_SIZE);
    memcpy(par->extradata, annexb.bytes, annexb.length);
    par->extradata_size = (int)annexb.length;
}

// libavformat's mp4 muxer omits the JOC extension (flag_ec3_extension_type_a,
// complexity_index_type_a) from dec3 when the E-AC-3 stream has a dependent
// substream (7.1 bed).  Without it AVPlayer decodes the bed only.  Append it.
// The true complexity index (object count) lives in the bitstream's addbsi and
// is not exposed by libavformat; 16 (the value seen in 5.1-bed JOC streams and
// the maximum for streaming bitrates) is used.
static const uint32_t kContainerSkip[][2] = {   // box type, bytes before first child
    {'moov', 0}, {'trak', 0}, {'mdia', 0}, {'minf', 0}, {'stbl', 0}, {'stsd', 8}, {'ec-3', 28} };

static BOOL dec3HasJOCExtension(const uint8_t *b, uint32_t sz) {
    // payload: data_rate(13) num_ind_sub(3) then per substream 3 bytes (+1 if num_dep_sub>0)
    if (sz < 8 + 2) return YES;
    const uint8_t *p = b + 8; uint32_t len = sz - 8;
    int nind = (p[1] & 7) + 1; uint32_t need = 2;
    for (int i = 0; i < nind; i++) {
        if (need + 3 > len) return YES;
        int ndep = (p[need + 2] >> 1) & 0xF;
        need += ndep ? 4 : 3;
    }
    return len > need;
}

static BOOL patchDec3(NSMutableData *buf, NSUInteger o, NSUInteger end) {
    while (o + 8 <= end) {
        uint8_t *d = buf.mutableBytes;
        uint32_t sz = rd32(d + o), type = rd32(d + o + 4);
        if (sz < 8 || o + sz > end) return NO;
        if (type == 'dec3') {
            if (dec3HasJOCExtension(d + o, sz)) return NO;
            static const uint8_t ext[2] = { 0x01, 16 };
            [buf replaceBytesInRange:NSMakeRange(o + sz, 0) withBytes:ext length:2];
            uint32_t nsz = CFSwapInt32HostToBig(sz + 2);
            [buf replaceBytesInRange:NSMakeRange(o, 4) withBytes:&nsz];
            return YES;
        }
        for (size_t i = 0; i < sizeof kContainerSkip / sizeof kContainerSkip[0]; i++) {
            if (type != kContainerSkip[i][0]) continue;
            if (patchDec3(buf, o + 8 + kContainerSkip[i][1], o + sz)) {
                uint32_t nsz = CFSwapInt32HostToBig(sz + 2);
                [buf replaceBytesInRange:NSMakeRange(o, 4) withBytes:&nsz];
                return YES;
            }
        }
        o += sz;
    }
    return NO;
}

- (BOOL)buildInit {
    PktList vl = {0}, al = {0}; int64_t vn, an; BOOL eof;
    [self collect:0 video:&vl audio:&al vNext:&vn aNext:&an eof:&eof];
    // The muxer must see audio packets to build dec3/esds.  If the audio starts
    // later than the first segment, take it from the first segment that has some.
    for (NSUInteger k = 1; _a.st >= 0 && realCount(&al) == 0 && k < MIN(_nseg, 20); k++) {
        PktList v2 = {0};
        [self collect:k video:&v2 audio:&al vNext:&vn aNext:&an eof:&eof];
        pl_free(&v2);
    }
    AVCodecContext *enc = NULL;
    if (_transcode) {
        PktList enc0 = {0}; int64_t first;
        [self transcodeSegment:0 raw:&al eof:eof out:&enc0 firstSample:&first];
        pl_free(&al); al = enc0;
        enc = [self newEncoder];
        if (!enc) return NO;
    }

    NSMutableData *out = [NSMutableData data];
    AVFormatContext *oc = NULL;
    avformat_alloc_output_context2(&oc, NULL, "mp4", NULL);
    if (!oc) return NO;
    uint8_t *iobuf = av_malloc(65536);
    oc->pb = avio_alloc_context(iobuf, 65536, 1, (__bridge void *)out, NULL, memWrite, NULL);
    Track *trs[2] = { &_v, &_a };
    int outIndex[2] = { -1, -1 }, nout = 0;
    for (int t = 0; t < 2; t++) {
        if (trs[t]->st < 0) continue;
        AVStream *in = _fmt->streams[trs[t]->st];
        AVStream *os = avformat_new_stream(oc, NULL);
        if (t == 1 && enc) { avcodec_parameters_from_context(os->codecpar, enc); os->time_base = enc->time_base; }
        else { avcodec_parameters_copy(os->codecpar, in->codecpar); os->time_base = in->time_base; }
        os->codecpar->codec_tag = 0;
        if (in->codecpar->codec_id == AV_CODEC_ID_HEVC) {
            os->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            if (vl.n > 0) fillHEVCParameterSets(os->codecpar, vl.p[0]);
        }
        outIndex[t] = nout++;
    }
    AVDictionary *opt = NULL;
    av_dict_set(&opt, "movflags", "frag_custom+delay_moov+default_base_moof", 0);
    av_dict_set(&opt, "use_editlist", "0", 0);
    BOOL ok = avformat_write_header(oc, &opt) >= 0;
    av_dict_free(&opt);
    // Feed a few packets of each track so the muxer can parse codec headers.
    PktList *ls[2] = { &vl, &al };
    for (int t = 0; t < 2 && ok; t++) {
        if (outIndex[t] < 0) continue;
        int64_t prevDts = INT64_MIN;
        for (int i = 0, fed = 0; i < ls[t]->n && fed < 8; i++) {
            if (ls[t]->p[i]->opaque == kSynthetic) continue;   // codec headers from real frames only
            fed++;
            AVPacket *p = av_packet_clone(ls[t]->p[i]);
            p->stream_index = outIndex[t];
            int64_t tt = pktTime(p);
            p->pts = tt; p->dts = MAX(tt, prevDts == INT64_MIN ? tt : prevDts + 1); prevDts = p->dts;
            if (p->pts < p->dts) p->pts = p->dts;
            AVRational itb = (t == 1 && enc) ? enc->time_base : _fmt->streams[trs[t]->st]->time_base;
            av_packet_rescale_ts(p, itb, oc->streams[outIndex[t]]->time_base);
            if (av_write_frame(oc, p) < 0) ok = NO;
            av_packet_free(&p);
        }
    }
    if (ok) av_write_frame(oc, NULL);   // flush fragment -> moov is emitted
    av_write_trailer(oc);
    avio_flush(oc->pb);
    av_freep(&oc->pb->buffer);
    avio_context_free(&oc->pb);
    avformat_free_context(oc);
    pl_free(&vl); pl_free(&al);
    if (enc) avcodec_free_context(&enc);
    if (!ok) return NO;

    const uint8_t *d = out.bytes; size_t len = out.length, mlen = 0, flen = 0;
    const uint8_t *ftyp = findBox(d, len, "ftyp", &flen);
    const uint8_t *moov = findBox(d, len, "moov", &mlen);
    if (!ftyp || !moov) return NO;
    NSMutableData *init = [NSMutableData dataWithBytes:ftyp length:flen];
    [init appendBytes:moov length:mlen];
    if (_atmosPassthrough && patchDec3(init, flen, init.length)) {
        _audioSummary = [_audioSummary stringByAppendingString:@" (JOC flag added to dec3)"];
        moov = (const uint8_t *)init.bytes + flen; mlen += 2;
    }
    _init = init;

    // Walk traks in order (same order we added streams).
    size_t o = 8; int ti = 0;
    while (o + 8 <= mlen) {
        uint32_t sz = rd32(moov + o);
        if (sz < 8) break;
        if (memcmp(moov + o + 4, "trak", 4) == 0) {
            const uint8_t *trak = moov + o + 8; size_t tl = sz - 8, bl;
            const uint8_t *tkhd = findBox(trak, tl, "tkhd", &bl);
            const uint8_t *mdia = findBox(trak, tl, "mdia", &bl); size_t ml = bl;
            const uint8_t *mdhd = mdia ? findBox(mdia + 8, ml - 8, "mdhd", &bl) : NULL;
            if (!tkhd || !mdhd) return NO;
            uint32_t id = tkhd[8] == 1 ? rd32(tkhd + 8 + 4 + 16) : rd32(tkhd + 8 + 4 + 8);
            uint32_t ts = mdhd[8] == 1 ? rd32(mdhd + 8 + 4 + 16) : rd32(mdhd + 8 + 4 + 8);
            while (ti < 2 && outIndex[ti] < 0) ti++;
            if (ti < 2) { trs[ti]->trackID = id; trs[ti]->timescale = ts; ti++; }
        }
        o += sz;
    }
    return (_v.st < 0 || _v.timescale) && (_a.st < 0 || _a.timescale);
}

// --- Media segment: moof (one traf per track) + mdat, written directly.
- (NSData *)mediaSegment:(NSUInteger)k {
    if (k >= _nseg) return nil;
    NSData *cached = [_cache objectForKey:@(k)];
    if (cached) return cached;

    NSData *result;
    @synchronized (self) {
        PktList vl = {0}, al = {0}; int64_t vn, an; BOOL eof;
        [self collect:k video:&vl audio:&al vNext:&vn aNext:&an eof:&eof];
        if (_transcode) {
            PktList enc = {0}; int64_t first;
            [self transcodeSegment:k raw:&al eof:eof out:&enc firstSample:&first];
            pl_free(&al); al = enc;
        }
        Timing vt = [self timingFor:&_v packets:&vl next:vn video:YES];
        Timing at = [self timingFor:&_a packets:&al next:an video:NO];

        BoxWriter *w = [BoxWriter new];
        NSUInteger moof = [w begin:"moof"];
        NSUInteger mfhd = [w begin:"mfhd"]; [w u32:0]; [w u32:(uint32_t)k + 1]; [w end:mfhd];
        struct { Track *tr; PktList *l; Timing *tm; BOOL video; NSUInteger offsetField; } T[2] = {
            { &_v, &vl, &vt, YES, 0 }, { &_a, &al, &at, NO, 0 } };
        for (int t = 0; t < 2; t++) {
            if (T[t].tr->st < 0 || T[t].l->n == 0) continue;
            NSUInteger traf = [w begin:"traf"];
            NSUInteger tfhd = [w begin:"tfhd"]; [w u32:0x020000]; [w u32:T[t].tr->trackID]; [w end:tfhd];
            NSUInteger tfdt = [w begin:"tfdt"]; [w u32:0x01000000]; [w u64:T[t].tm->baseDts]; [w end:tfdt];
            uint32_t flags = 0x000001 | 0x000100 | 0x000200 | 0x000400 | (T[t].video ? 0x000800 : 0);
            NSUInteger trun = [w begin:"trun"]; [w u32:flags]; [w u32:(uint32_t)T[t].l->n];
            T[t].offsetField = w->d.length; [w u32:0];
            for (int i = 0; i < T[t].l->n; i++) {
                AVPacket *p = T[t].l->p[i];
                [w u32:T[t].tm->dur[i]];
                [w u32:(uint32_t)p->size];
                BOOL sync = !T[t].video || (p->flags & AV_PKT_FLAG_KEY);
                [w u32:sync ? 0x02000000 : 0x01010000];
                if (T[t].video) [w u32:(uint32_t)T[t].tm->cto[i]];
            }
            [w end:trun];
            [w end:traf];
        }
        [w end:moof];
        // mdat
        NSUInteger mdatStart = w->d.length;
        NSUInteger mdat = [w begin:"mdat"];
        for (int t = 0; t < 2; t++) {
            if (T[t].tr->st < 0 || T[t].l->n == 0) continue;
            [w patch32:T[t].offsetField value:(uint32_t)(w->d.length - moof)];
            for (int i = 0; i < T[t].l->n; i++) [w->d appendBytes:T[t].l->p[i]->data length:T[t].l->p[i]->size];
        }
        (void)mdatStart;
        [w end:mdat];

        free(vt.dur); free(vt.cto); free(at.dur); free(at.cto);
        pl_free(&vl); pl_free(&al);
        result = w->d;
    }
    [_cache setObject:result forKey:@(k)];
    return result;
}

@end
