/* Renders the Mail2 application icon: on a rounded deep-teal tile (the shape of Milan's, Naples' and Venice's icons),
 * an open white envelope with a cream letter rising out of it, and a second envelope tilted behind -- the "2". No red,
 * and no closed envelope on blue: nothing that reads as a notification badge or as Apple Mail's icon.
 * Host tool, run by tools/make_icons.sh:  make_icon icons/Mail2.png */
#import <AppKit/AppKit.h>

static NSColor *
rgb(double r, double g, double b)
{
	return [NSColor colorWithCalibratedRed: r / 255.0 green: g / 255.0 blue: b / 255.0 alpha: 1];
}

static void
shadowed(void (^draw)(void), double blur, double dy, double alpha)
{
	[NSGraphicsContext saveGraphicsState];
	NSShadow *s = [[NSShadow alloc] init];
	[s setShadowBlurRadius: blur];
	[s setShadowOffset: NSMakeSize(0, -dy)];
	[s setShadowColor: [NSColor colorWithCalibratedWhite: 0 alpha: alpha]];
	[s set];
	draw();
	[NSGraphicsContext restoreGraphicsState];
}

/* an envelope's body, its open flap pointing up behind it, and the V of its front pocket */
static void
envelope(NSRect body, NSColor *paper, NSColor *flapColor, NSColor *line, BOOL open, void (^inside)(void))
{
	CGFloat midX = NSMidX(body), top = NSMaxY(body);
	if (open) {	/* the flap, folded up behind */
		NSBezierPath *flap = [NSBezierPath bezierPath];
		[flap moveToPoint: NSMakePoint(NSMinX(body) + 2, top - 2)];
		[flap lineToPoint: NSMakePoint(midX, top + body.size.height * 0.55)];
		[flap lineToPoint: NSMakePoint(NSMaxX(body) - 2, top - 2)];
		[flap closePath];
		[flapColor set];
		[flap fill];
	}
	if (inside)
		inside();
	/* the pocket: the body below the line where the sides fold in */
	NSBezierPath *pocket = [NSBezierPath bezierPath];
	[pocket moveToPoint: NSMakePoint(NSMinX(body), NSMinY(body) + 8)];
	[pocket appendBezierPathWithArcFromPoint: NSMakePoint(NSMinX(body), NSMinY(body))
	    toPoint: NSMakePoint(NSMinX(body) + 8, NSMinY(body)) radius: 8];
	[pocket lineToPoint: NSMakePoint(NSMaxX(body) - 8, NSMinY(body))];
	[pocket appendBezierPathWithArcFromPoint: NSMakePoint(NSMaxX(body), NSMinY(body))
	    toPoint: NSMakePoint(NSMaxX(body), NSMinY(body) + 8) radius: 8];
	[pocket lineToPoint: NSMakePoint(NSMaxX(body), top)];
	[pocket lineToPoint: NSMakePoint(midX, NSMinY(body) + body.size.height * 0.42)];
	[pocket lineToPoint: NSMakePoint(NSMinX(body), top)];
	[pocket closePath];
	[paper set];
	[pocket fill];
	/* the folds */
	NSBezierPath *v = [NSBezierPath bezierPath];
	[v moveToPoint: NSMakePoint(NSMinX(body) + 3, top - 1)];
	[v lineToPoint: NSMakePoint(midX, NSMinY(body) + body.size.height * 0.42)];
	[v lineToPoint: NSMakePoint(NSMaxX(body) - 3, top - 1)];
	[v moveToPoint: NSMakePoint(NSMinX(body) + 6, NSMinY(body) + 6)];
	[v lineToPoint: NSMakePoint(midX - 14, NSMinY(body) + body.size.height * 0.36)];
	[v moveToPoint: NSMakePoint(NSMaxX(body) - 6, NSMinY(body) + 6)];
	[v lineToPoint: NSMakePoint(midX + 14, NSMinY(body) + body.size.height * 0.36)];
	[v setLineWidth: 3];
	[v setLineCapStyle: NSLineCapStyleRound];
	[v setLineJoinStyle: NSLineJoinStyleRound];
	[line set];
	[v stroke];
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		const char *out = argc > 1 ? argv[1] : "icons/Mail2.png";
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 256 pixelsHigh: 256 bitsPerSample: 8
		    samplesPerPixel: 4 hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 32];
		NSRect tile = NSMakeRect(8, 8, 240, 240);
		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithBitmapImageRep: rep]];
		[[NSColor clearColor] set];
		NSRectFill(NSMakeRect(0, 0, 256, 256));

		/* the tile: deep teal, lighter at the top */
		NSBezierPath *tp = [NSBezierPath bezierPathWithRoundedRect: tile xRadius: 52 yRadius: 52];
		shadowed(^{ [rgb(14, 92, 98) set]; [tp fill]; }, 6, 2, 0.35);
		NSGradient *g = [[NSGradient alloc] initWithStartingColor: rgb(38, 170, 158) endingColor: rgb(13, 96, 104)];
		[g drawInBezierPath: tp angle: -90];

		/* the second envelope, tilted behind: pale, closed */
		[NSGraphicsContext saveGraphicsState];
		NSAffineTransform *t = [NSAffineTransform transform];
		[t translateXBy: 150 yBy: 150];
		[t rotateByDegrees: 15];
		[t translateXBy: -150 yBy: -150];
		[t concat];
		NSRect back = NSMakeRect(100, 126, 124, 82);
		shadowed(^{
			[rgb(176, 226, 219) set];
			[[NSBezierPath bezierPathWithRoundedRect: back xRadius: 8 yRadius: 8] fill];
		}, 5, 2, 0.25);
		NSBezierPath *bv = [NSBezierPath bezierPath];
		[bv moveToPoint: NSMakePoint(NSMinX(back) + 4, NSMaxY(back) - 3)];
		[bv lineToPoint: NSMakePoint(NSMidX(back), NSMidY(back) - 6)];
		[bv lineToPoint: NSMakePoint(NSMaxX(back) - 4, NSMaxY(back) - 3)];
		[bv setLineWidth: 4];
		[bv setLineJoinStyle: NSLineJoinStyleRound];
		[bv setLineCapStyle: NSLineCapStyleRound];
		[rgb(112, 182, 174) set];
		[bv stroke];
		[NSGraphicsContext restoreGraphicsState];

		/* the open envelope in front, its letter rising out of it */
		NSRect body = NSMakeRect(40, 44, 156, 100);
		shadowed(^{
			[[NSColor whiteColor] set];
			[[NSBezierPath bezierPathWithRoundedRect: NSInsetRect(body, 1, 1) xRadius: 8 yRadius: 8] fill];
		}, 8, 4, 0.30);
		envelope(body, [NSColor whiteColor], rgb(226, 240, 238), rgb(196, 222, 218), YES, ^{
			NSRect letter = NSMakeRect(58, 84, 120, 104);
			shadowed(^{
				[rgb(255, 249, 232) set];
				[[NSBezierPath bezierPathWithRoundedRect: letter xRadius: 5 yRadius: 5] fill];
			}, 3, 1, 0.18);
			/* a few lines of writing */
			NSColor *ink = rgb(34, 120, 124);
			CGFloat ys[] = { 166, 150, 134 }, ws[] = { 82, 92, 60 };
			int i;
			for (i = 0; i < 3; i++) {
				NSBezierPath *l = [NSBezierPath bezierPath];
				[l moveToPoint: NSMakePoint(NSMinX(letter) + 16, ys[i])];
				[l lineToPoint: NSMakePoint(NSMinX(letter) + 16 + ws[i], ys[i])];
				[l setLineWidth: 6];
				[l setLineCapStyle: NSLineCapStyleRound];
				[[ink colorWithAlphaComponent: i == 0 ? 0.9 : 0.45] set];
				[l stroke];
			}
		});

		[NSGraphicsContext restoreGraphicsState];
		NSData *png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
		if (![png writeToFile: [NSString stringWithUTF8String: out] atomically: YES])
			return 1;
	}
	return 0;
}
