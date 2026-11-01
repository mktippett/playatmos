// Draws the PlayAtmos app icon and writes a 1024x1024 PNG.
// build.sh turns it into AppIcon.icns with sips + iconutil.
// usage: makeicon <out.png> [letter|dome|light]   (default: letter)
#import <Cocoa/Cocoa.h>

static NSColor *rgb(int hex, CGFloat a) {
    return [NSColor colorWithSRGBRed:((hex >> 16) & 0xff) / 255.0 green:((hex >> 8) & 0xff) / 255.0
                                blue:(hex & 0xff) / 255.0 alpha:a];
}

// A play triangle under a dome of three arcs with four height-speaker dots, over a floor line.
static void drawDome(const int arcs[3], CGFloat arcAlpha[3], NSColor *dots, NSColor *floorColor, NSColor *play) {
    NSPoint c = NSMakePoint(512, 290);
    CGFloat radii[3] = {215, 300, 385};
    for (int i = 0; i < 3; i++) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:radii[i] startAngle:12 endAngle:168];
        arc.lineWidth = 34 - 6 * i;
        arc.lineCapStyle = NSLineCapStyleRound;
        [rgb(arcs[i], arcAlpha[i]) setStroke];
        [arc stroke];
    }
    for (int k = 0; k < 4; k++) {
        CGFloat deg = (CGFloat[]){40, 70, 110, 140}[k] * M_PI / 180, r = 385, d = 44;
        NSPoint p = NSMakePoint(c.x + r * cos(deg), c.y + r * sin(deg));
        [dots setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - d / 2, p.y - d / 2, d, d)] fill];
    }
    NSBezierPath *floor = [NSBezierPath bezierPath];
    [floor moveToPoint:NSMakePoint(220, 260)];
    [floor lineToPoint:NSMakePoint(804, 260)];
    floor.lineWidth = 14;
    floor.lineCapStyle = NSLineCapStyleRound;
    [floorColor setStroke];
    [floor stroke];

    CGFloat h = 150, w = h * 0.87, cx = 512 + w * 0.08, cy = c.y + 92;
    NSBezierPath *tri = [NSBezierPath bezierPath];
    [tri moveToPoint:NSMakePoint(cx - w / 2, cy + h / 2)];
    [tri lineToPoint:NSMakePoint(cx + w / 2, cy)];
    [tri lineToPoint:NSMakePoint(cx - w / 2, cy - h / 2)];
    [tri closePath];
    tri.lineJoinStyle = NSLineJoinStyleRound;
    tri.lineWidth = 30;
    [play set];
    [tri fill];
    [tri stroke];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: makeicon <out.png> [dome|light|letter]\n"); return 1; }
        NSString *variant = argc > 2 ? @(argv[2]) : @"letter";
        const CGFloat S = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL pixelsWide:S pixelsHigh:S bitsPerSample:8 samplesPerPixel:4
                            hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
                         bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

        // macOS icon grid: 824 pt body centred on the 1024 canvas, with a drop shadow.
        NSRect body = NSMakeRect(100, 100, 824, 824);
        NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 yRadius:185];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.45];
        sh.shadowOffset = NSMakeSize(0, -12);
        sh.shadowBlurRadius = 24;
        [sh set];
        [[NSColor grayColor] setFill];
        [plate fill];
        [NSGraphicsContext restoreGraphicsState];

        if ([variant isEqualToString:@"light"]) {
            // Pale plate, saturated arcs, dark play button: stands out on a dark Dock.
            [[[NSGradient alloc] initWithColors:@[ rgb(0xffffff, 1), rgb(0xdfe4f2, 1) ]] drawInBezierPath:plate angle:-90];
            int arcs[3] = {0x00a8d8, 0x4f6bed, 0x8a4fe0};
            CGFloat a[3] = {1, 1, 1};
            drawDome(arcs, a, rgb(0x1b1f4a, 1), rgb(0x00a8d8, 0.35), rgb(0x1b1f4a, 1));
        } else if ([variant isEqualToString:@"letter"]) {
            // Cyan-to-violet plate with a single heavy rounded "A".
            [[[NSGradient alloc] initWithColors:@[ rgb(0x2ec8f5, 1), rgb(0x5a6cf0, 1), rgb(0x8a4fe0, 1) ]]
                drawInBezierPath:plate angle:-45];
            NSFont *f = [NSFont systemFontOfSize:600 weight:NSFontWeightHeavy];
            NSFontDescriptor *rd = [f.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
            if (rd) f = [NSFont fontWithDescriptor:rd size:600];
            // Draw the glyph as a path so its exact outline bounds can be centred on the plate.
            CGGlyph g;
            UniChar ch = 'A';
            CTFontGetGlyphsForCharacters((__bridge CTFontRef)f, &ch, &g, 1);
            NSBezierPath *A = [NSBezierPath bezierPath];
            [A moveToPoint:NSZeroPoint];
            [A appendBezierPathWithCGGlyph:g inFont:f];
            // Bounds from the glyph outline alone (A.bounds would include the moveTo origin).
            CGPathRef gp = CTFontCreatePathForGlyph((__bridge CTFontRef)f, g, NULL);
            NSRect b = NSRectFromCGRect(CGPathGetPathBoundingBox(gp));
            CGPathRelease(gp);
            NSAffineTransform *t = [NSAffineTransform transform];
            [t translateXBy:512 - NSMidX(b) yBy:512 - NSMidY(b)];
            [A transformUsingAffineTransform:t];
            [NSColor.whiteColor setFill];
            [A fill];
        } else {
            // "dome": the original design on a brighter indigo plate with a light rim,
            // so its lower edge does not vanish into a dark Dock.
            [[[NSGradient alloc] initWithColors:@[ rgb(0x4048c0, 1), rgb(0x262b80, 1), rgb(0x1a1e5c, 1) ]]
                drawInBezierPath:plate angle:-90];
            NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(body, 4, 4) xRadius:181 yRadius:181];
            rim.lineWidth = 8;
            [rgb(0xffffff, 0.22) setStroke];
            [rim stroke];
            int arcs[3] = {0x5ee7ff, 0x7d9bff, 0xb47cff};
            CGFloat a[3] = {0.95, 0.85, 0.8};
            drawDome(arcs, a, NSColor.whiteColor, rgb(0x5ee7ff, 0.45), NSColor.whiteColor);
        }

        [NSGraphicsContext restoreGraphicsState];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        if (![png writeToFile:@(argv[1]) atomically:YES]) { fprintf(stderr, "write failed\n"); return 1; }
    }
    return 0;
}
