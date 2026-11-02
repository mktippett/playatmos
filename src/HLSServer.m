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
    if (_fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
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

// Parse a single-range "Range: bytes=..." value against a body of length len.
// Returns 1 with [*from, *to] (inclusive) for a satisfiable range, 0 to ignore the header
// (absent, malformed or multi-range: serve the whole body), -1 for an unsatisfiable range (416).
static int parseRange(NSString *spec, long long len, long long *from, long long *to) {
    if (!spec || [spec containsString:@","]) return 0;
    NSArray *p = [spec componentsSeparatedByString:@"-"];
    if (p.count != 2) return 0;
    NSString *a = [p[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *b = [p[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!a.length && !b.length) return 0;
    if (!a.length) {                                   // suffix: the last N bytes
        long long n = b.longLongValue;
        if (n <= 0 || len == 0) return -1;
        *from = n >= len ? 0 : len - n; *to = len - 1; return 1;
    }
    long long f = a.longLongValue, t = b.length ? b.longLongValue : len - 1;
    if (f < 0 || f >= len || t < f) return -1;
    *from = f; *to = MIN(t, len - 1); return 1;
}

- (void)handle:(int)c {
    // A client that goes quiet (or stops reading) releases its thread after a minute instead
    // of holding it, and this server and its Segmenter, forever.
    struct timeval tv = { .tv_sec = 60 };
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    char buf[8192]; size_t got = 0;
    // Serve requests on this connection until the client closes (keep-alive).
    for (;;) {
        char *endp;
        while (!(buf[got] = 0, endp = strstr(buf, "\r\n\r\n"))) {
            if (got >= sizeof buf - 1) { close(c); return; }   // header too large
            ssize_t n = read(c, buf + got, sizeof buf - 1 - got);
            if (n <= 0) { close(c); return; }
            got += (size_t)n;
        }
        size_t hlen = (size_t)(endp - buf) + 4;
        NSString *req = [[NSString alloc] initWithBytes:buf length:hlen encoding:NSISOLatin1StringEncoding];
        // Keep anything after this request's headers (a pipelined request) for the next pass.
        memmove(buf, buf + hlen, got - hlen); got -= hlen;

        NSArray *lines = [req componentsSeparatedByString:@"\r\n"];
        NSArray *rl = [lines.firstObject componentsSeparatedByString:@" "];
        if (rl.count < 2) { close(c); return; }
        NSString *method = rl[0], *path = rl[1], *range = nil;
        for (NSString *h in lines)
            if ([h.lowercaseString hasPrefix:@"range:"]) {
                NSString *v = [[h substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if ([v.lowercaseString hasPrefix:@"bytes="]) range = [v substringFromIndex:6];
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
        long long len = (long long)body.length, r0 = 0, r1 = 0;
        int rs = body ? parseRange(range, len, &r0, &r1) : 0;
        if (!body) {
            head = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n";
            payload = nil;
        } else if (rs < 0) {
            head = [NSString stringWithFormat:@"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */%lld\r\nContent-Length: 0\r\n", len];
            payload = nil;
        } else if (rs > 0) {
            payload = [body subdataWithRange:NSMakeRange((NSUInteger)r0, (NSUInteger)(r1 - r0 + 1))];
            head = [NSString stringWithFormat:@"HTTP/1.1 206 Partial Content\r\nContent-Type: %@\r\nContent-Length: %lu\r\nContent-Range: bytes %lld-%lld/%lld\r\nAccept-Ranges: bytes\r\n",
                    type, (unsigned long)payload.length, r0, r1, len];
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
