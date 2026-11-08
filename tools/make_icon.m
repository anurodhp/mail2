/* Renders the Mail2 application icon: a white envelope on a rounded sky-blue tile (the shape of Milan's,
 * Naples' and Venice's icons), with a red postage stamp in its top-right corner and a postmark arc beside it.
 * Host tool, run by tools/make_icons.sh:  make_icon icons/Mail2.png */
#import <AppKit/AppKit.h>

static NSColor *
rgb(double r, double g, double b)
{
	return [NSColor colorWithCalibratedRed: r green: g blue: b alpha: 1];
}

/* the stamp's perforated edge: a rectangle with semicircular bites along every side */
static NSBezierPath *
perforated(NSRect r, int across, int down)
{
	NSBezierPath *p = [NSBezierPath bezierPathWithRect: r];
	double bw = r.size.width / across, bh = r.size.height / down, rad = MIN(bw, bh) * 0.28;
	for (int i = 0; i < across; i++) {
		double cx = r.origin.x + bw * (i + 0.5);
		[p appendBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(cx - rad, NSMinY(r) - rad, 2 * rad, 2 * rad)]];
		[p appendBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(cx - rad, NSMaxY(r) - rad, 2 * rad, 2 * rad)]];
	}
	for (int i = 0; i < down; i++) {
		double cy = r.origin.y + bh * (i + 0.5);
		[p appendBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMinX(r) - rad, cy - rad, 2 * rad, 2 * rad)]];
		[p appendBezierPath: [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMaxX(r) - rad, cy - rad, 2 * rad, 2 * rad)]];
	}
	[p setWindingRule: NSWindingRuleEvenOdd];
	return p;
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
		NSRectFillUsingOperation(NSMakeRect(0, 0, 256, 256), NSCompositingOperationClear);
		[[[NSGradient alloc] initWithStartingColor: rgb(0.44, 0.80, 1.00) endingColor: rgb(0.10, 0.42, 0.88)]
		    drawInBezierPath: [NSBezierPath bezierPathWithRoundedRect: tile xRadius: 52 yRadius: 52] angle: -90];

		/* the envelope, with a soft shadow under it */
		NSRect env = NSMakeRect(38, 62, 180, 124);
		NSShadow *sh = [[NSShadow alloc] init];
		[sh setShadowColor: [NSColor colorWithCalibratedWhite: 0 alpha: 0.28]];
		[sh setShadowOffset: NSMakeSize(0, -5)];
		[sh setShadowBlurRadius: 9];
		[NSGraphicsContext saveGraphicsState];
		[sh set];
		[[NSColor whiteColor] set];
		[[NSBezierPath bezierPathWithRoundedRect: env xRadius: 12 yRadius: 12] fill];
		[NSGraphicsContext restoreGraphicsState];
		/* bottom folds, then the flap's V, in a pale blue-gray */
		NSBezierPath *folds = [NSBezierPath bezierPath];
		[folds moveToPoint: NSMakePoint(NSMinX(env) + 8, NSMinY(env) + 8)];
		[folds lineToPoint: NSMakePoint(NSMidX(env), NSMinY(env) + 62)];
		[folds lineToPoint: NSMakePoint(NSMaxX(env) - 8, NSMinY(env) + 8)];
		[folds setLineWidth: 5];
		[folds setLineCapStyle: NSLineCapStyleRound];
		[folds setLineJoinStyle: NSLineJoinStyleRound];
		[rgb(0.80, 0.86, 0.93) set];
		[folds stroke];
		NSBezierPath *flap = [NSBezierPath bezierPath];
		[flap moveToPoint: NSMakePoint(NSMinX(env) + 6, NSMaxY(env) - 6)];
		[flap lineToPoint: NSMakePoint(NSMidX(env), NSMinY(env) + 44)];
		[flap lineToPoint: NSMakePoint(NSMaxX(env) - 6, NSMaxY(env) - 6)];
		[flap setLineWidth: 7];
		[flap setLineCapStyle: NSLineCapStyleRound];
		[flap setLineJoinStyle: NSLineJoinStyleRound];
		[rgb(0.62, 0.72, 0.84) set];
		[flap stroke];

		/* the stamp: white perforated paper, a red face, a tiny white heart-free mark (two hills) */
		NSRect stamp = NSMakeRect(160, 150, 58, 68);
		[NSGraphicsContext saveGraphicsState];
		NSShadow *ss = [[NSShadow alloc] init];
		[ss setShadowColor: [NSColor colorWithCalibratedWhite: 0 alpha: 0.30]];
		[ss setShadowOffset: NSMakeSize(1, -3)];
		[ss setShadowBlurRadius: 4];
		[ss set];
		NSAffineTransform *rot = [NSAffineTransform transform];
		[rot translateXBy: NSMidX(stamp) yBy: NSMidY(stamp)];
		[rot rotateByDegrees: -8];
		[rot translateXBy: -NSMidX(stamp) yBy: -NSMidY(stamp)];
		[rot concat];
		[[NSColor whiteColor] set];
		[perforated(stamp, 5, 6) fill];
		[NSGraphicsContext restoreGraphicsState];
		[NSGraphicsContext saveGraphicsState];
		[rot concat];
		NSRect face = NSInsetRect(stamp, 7, 7);
		[[[NSGradient alloc] initWithStartingColor: rgb(0.98, 0.40, 0.33) endingColor: rgb(0.80, 0.14, 0.18)]
		    drawInRect: face angle: -90];
		NSBezierPath *hills = [NSBezierPath bezierPath];
		[hills moveToPoint: NSMakePoint(NSMinX(face) + 4, NSMinY(face) + 8)];
		[hills curveToPoint: NSMakePoint(NSMidX(face), NSMinY(face) + 14)
		      controlPoint1: NSMakePoint(NSMinX(face) + 12, NSMinY(face) + 30)
		      controlPoint2: NSMakePoint(NSMidX(face) - 6, NSMinY(face) + 26)];
		[hills curveToPoint: NSMakePoint(NSMaxX(face) - 4, NSMinY(face) + 8)
		      controlPoint1: NSMakePoint(NSMidX(face) + 6, NSMinY(face) + 34)
		      controlPoint2: NSMakePoint(NSMaxX(face) - 10, NSMinY(face) + 28)];
		[hills setLineWidth: 3.5];
		[hills setLineCapStyle: NSLineCapStyleRound];
		[[NSColor colorWithCalibratedWhite: 1 alpha: 0.9] set];
		[hills stroke];
		[[NSColor colorWithCalibratedWhite: 1 alpha: 0.9] set];
		[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMaxX(face) - 16, NSMaxY(face) - 16, 9, 9)] fill];
		[NSGraphicsContext restoreGraphicsState];

		/* the postmark: three wavy cancellation lines running off the stamp's left edge */
		[rgb(0.22, 0.30, 0.45) set];
		for (int i = 0; i < 3; i++) {
			double y = 196 - i * 11;
			NSBezierPath *w = [NSBezierPath bezierPath];
			[w moveToPoint: NSMakePoint(112, y)];
			[w curveToPoint: NSMakePoint(170, y) controlPoint1: NSMakePoint(130, y + 7) controlPoint2: NSMakePoint(150, y - 7)];
			[w setLineWidth: 3];
			[w setLineCapStyle: NSLineCapStyleRound];
			[[NSColor colorWithCalibratedRed: 0.22 green: 0.30 blue: 0.45 alpha: 0.55] set];
			[w stroke];
		}
		[NSGraphicsContext restoreGraphicsState];
		[[rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}] writeToFile: [NSString stringWithUTF8String: out] atomically: YES];
	}
	return 0;
}
