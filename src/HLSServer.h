// Minimal HTTP/1.1 server on 127.0.0.1 serving a Segmenter's HLS presentation.
#import <Foundation/Foundation.h>
@class Segmenter;

NS_ASSUME_NONNULL_BEGIN
@interface HLSServer : NSObject
- (instancetype)initWithSegmenter:(Segmenter *)segmenter;
- (BOOL)start:(NSError **)error;
- (void)stop;
@property (readonly, nullable) NSURL *playlistURL;
@end
NS_ASSUME_NONNULL_END
