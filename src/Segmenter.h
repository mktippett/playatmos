// Segmenter: presents a Matroska (or any libavformat-readable) file as an
// HLS VOD presentation made of fragmented-MP4 segments, generated on demand
// by stream copy (no re-encoding of video or E-AC-3/AC-3/AAC audio).
//
// Why: on macOS only AVPlayer engages Apple's Dolby Atmos (E-AC-3 JOC)
// object renderer; AVSampleBufferAudioRenderer and AudioToolbox decode the
// 5.1 bed only.  AVPlayer cannot open MKV, so we hand it HLS instead.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Segmenter : NSObject

+ (nullable instancetype)segmenterWithPath:(NSString *)path error:(NSError **)error;

/// Human-readable description of the selected audio track, e.g. "E-AC-3 JOC (Dolby Atmos), passthrough".
@property (readonly) NSString *audioSummary;
@property (readonly) NSString *videoSummary;
/// YES when the selected audio is E-AC-3 with Atmos (JOC) and is passed through untouched.
@property (readonly) BOOL atmosPassthrough;
/// Language tag of the selected audio track (as in the file, e.g. "kor"), nil if untagged.
@property (readonly, nullable) NSString *audioLanguage;
@property (readonly) NSUInteger segmentCount;
@property (readonly) double duration;

- (NSString *)playlist;
- (nullable NSData *)initializationSegment;
- (nullable NSData *)mediaSegment:(NSUInteger)index;

@end

NS_ASSUME_NONNULL_END
