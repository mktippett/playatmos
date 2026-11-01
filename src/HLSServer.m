#import "HLSServer.h"
#import "Segmenter.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

@implementation HLSServer {
    Segmenter *_seg;
    int _fd;
    dispatch_source_t _src;
    dispatch_queue_t _workers;
}

- (instancetype)initWithSegmenter:(Segmenter *)segmenter {
    if ((self = [super init])) { _seg = segmenter; _fd = -1; }
    return self;
}

- (void)dealloc { [self stop]; }

- (BOOL)start:(NSError **)error {
    _fd = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1; setsockopt(_fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a = { .sin_len = sizeof a, .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(_fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(_fd, 16) < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        close(_fd); _fd = -1; return NO;
    }
    socklen_t l = sizeof a; getsockname(_fd, (struct sockaddr *)&a, &l);
    _playlistURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/index.m3u8", ntohs(a.sin_port)]];

    _workers = dispatch_queue_create("hls.workers", DISPATCH_QUEUE_CONCURRENT);
    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _fd, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    __weak HLSServer *ws = self;
    int lfd = _fd;
    dispatch_source_set_event_handler(_src, ^{
        int c = accept(lfd, NULL, NULL);
        if (c < 0) return;
        int nosig = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof nosig);
        HLSServer *s = ws;
        if (!s) { close(c); return; }
        dispatch_async(s->_workers, ^{ [s handle:c]; });
    });
    dispatch_source_set_cancel_handler(_src, ^{ close(lfd); });
    dispatch_resume(_src);
    return YES;
}

- (void)stop {
    if (_src) { dispatch_source_cancel(_src); _src = nil; _fd = -1; }
}

static void sendAll(int fd, const void *buf, size_t len) {
    const char *p = buf;
    while (len) { ssize_t n = write(fd, p, len); if (n <= 0) return; p += n; len -= (size_t)n; }
}

- (void)handle:(int)c {
    // Serve requests on this connection until the client closes (keep-alive).
    for (;;) {
        char buf[8192]; size_t got = 0;
        while (got < sizeof buf - 1) {
            ssize_t n = read(c, buf + got, sizeof buf - 1 - got);
            if (n <= 0) { close(c); return; }
            got += (size_t)n; buf[got] = 0;
            if (strstr(buf, "\r\n\r\n")) break;
        }
        NSString *req = [[NSString alloc] initWithBytes:buf length:got encoding:NSISOLatin1StringEncoding];
        NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
        NSArray *rl = [lines.firstObject componentsSeparatedByString:@" "];
        if (rl.count < 2) { close(c); return; }
        NSString *method = rl[0], *path = rl[1];
        long long r0 = -1, r1 = -1;
        for (NSString *h in lines) {
            if ([h.lowercaseString hasPrefix:@"range: bytes="]) {
                NSArray *p = [[h substringFromIndex:13] componentsSeparatedByString:@"-"];
                r0 = [p[0] longLongValue];
                r1 = (p.count > 1 && [p[1] length]) ? [p[1] longLongValue] : -1;
            }
        }

        NSData *body = nil; NSString *type = @"application/octet-stream";
        if ([path isEqualToString:@"/index.m3u8"]) {
            body = [_seg.playlist dataUsingEncoding:NSUTF8StringEncoding]; type = @"application/vnd.apple.mpegurl";
        } else if ([path isEqualToString:@"/init.mp4"]) {
            body = _seg.initializationSegment; type = @"video/mp4";
        } else if ([path hasPrefix:@"/seg"] && [path hasSuffix:@".m4s"]) {
            NSUInteger k = (NSUInteger)[[path substringWithRange:NSMakeRange(4, path.length - 8)] integerValue];
            body = [_seg mediaSegment:k]; type = @"video/iso.segment";
        }

        NSString *head;
        NSData *payload = body;
        if (!body) {
            head = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n";
            payload = nil;
        } else if (r0 >= 0 && r0 < (long long)body.length) {
            long long e = (r1 < 0 || r1 >= (long long)body.length) ? (long long)body.length - 1 : r1;
            payload = [body subdataWithRange:NSMakeRange((NSUInteger)r0, (NSUInteger)(e - r0 + 1))];
            head = [NSString stringWithFormat:@"HTTP/1.1 206 Partial Content\r\nContent-Type: %@\r\nContent-Length: %lu\r\nContent-Range: bytes %lld-%lld/%lu\r\nAccept-Ranges: bytes\r\n",
                    type, (unsigned long)payload.length, r0, e, (unsigned long)body.length];
        } else {
            head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nAccept-Ranges: bytes\r\n",
                    type, (unsigned long)body.length];
        }
        head = [head stringByAppendingString:@"Cache-Control: no-cache\r\nConnection: keep-alive\r\n\r\n"];
        NSData *h = [head dataUsingEncoding:NSISOLatin1StringEncoding];
        sendAll(c, h.bytes, h.length);
        if (payload && ![method isEqualToString:@"HEAD"]) sendAll(c, payload.bytes, payload.length);
    }
}

@end
