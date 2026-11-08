/* Renders the Mail2 application icon: on a rounded sky-blue tile (the shape of Milan's, Naples' and Venice's icons), a
 * letter seen from its address side, a second envelope tilted behind it (the "2"), a perforated stamp inside its
 * top-right corner -- a sun over hills, no red, well inside the envelope so it never reads as a badge -- and a round
 * postmark reading HELLO FROM BOSTON, its wavy cancellation lines running across the stamp.
 * Host tool, run by tools/make_icons.sh:  make_icon icons/Mail2.png */
#import <AppKit/AppKit.h>
#include <math.h>

static NSColor *
rgb(double r, double g, double b)
{
	return [NSColor colorWithCalibratedRed: r green: g blue: b alpha: 1];
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

/* a stamp's outline: a rectangle with semicircular bites along every side */
static NSBezierPath *
perforated(NSRect r, int across, int down)
{
	NSBezierPath *p = [NSBezierPath bezierPathWithRect: r];
	double bw = r.size.width / across, bh = r.size.height / down, rad = MIN(bw, bh) * 0.30;
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

/* text set along a circle, centred on an angle (degrees, 90 = the top); on the top it reads left to right over the
 * arc, on the bottom (bottom: YES) left to right under it */
static void
ring_text(NSString *s, NSPoint c, double radius, double centerDeg, BOOL bottom, NSDictionary *attrs)
{
	NSUInteger i, n = MIN([s length], (NSUInteger)64);
	double widths[64], total = 0;
	for (i = 0; i < n; i++) {
		widths[i] = [[s substringWithRange: NSMakeRange(i, 1)] sizeWithAttributes: attrs].width + 0.5;
		total += widths[i];
	}
	double span = total / radius * 180 / M_PI;
	/* top: from the left end clockwise (decreasing angle); bottom: from the left end counter-clockwise */
	double angle = bottom ? centerDeg - span / 2 : centerDeg + span / 2;
	for (i = 0; i < n; i++) {
		double half = widths[i] / 2 / radius * 180 / M_PI;
		angle += bottom ? half : -half;
		NSString *ch = [s substringWithRange: NSMakeRange(i, 1)];
		[NSGraphicsContext saveGraphicsState];
		NSAffineTransform *t = [NSAffineTransform transform];
		[t translateXBy: c.x + radius * cos(angle * M_PI / 180) yBy: c.y + radius * sin(angle * M_PI / 180)];
		[t rotateByDegrees: bottom ? angle + 90 : angle - 90];
		[t concat];
		NSSize sz = [ch sizeWithAttributes: attrs];
		[ch drawAtPoint: NSMakePoint(-sz.width / 2, -sz.height / 2) withAttributes: attrs];
		[NSGraphicsContext restoreGraphicsState];
		angle += bottom ? half : -half;
	}
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

		/* the tile: the sky blue of Mail2's first icon */
		NSBezierPath *tp = [NSBezierPath bezierPathWithRoundedRect: tile xRadius: 52 yRadius: 52];
		[[[NSGradient alloc] initWithStartingColor: rgb(0.44, 0.80, 1.00) endingColor: rgb(0.10, 0.42, 0.88)]
		    drawInBezierPath: tp angle: -90];

		/* the second envelope, tilted behind */
		[NSGraphicsContext saveGraphicsState];
		NSAffineTransform *t = [NSAffineTransform transform];
		[t translateXBy: 128 yBy: 128];
		[t rotateByDegrees: 9];
		[t translateXBy: -128 yBy: -128];
		[t concat];
		NSRect back = NSMakeRect(44, 80, 176, 116);
		shadowed(^{
			[rgb(0.84, 0.91, 0.98) set];
			[[NSBezierPath bezierPathWithRoundedRect: back xRadius: 10 yRadius: 10] fill];
		}, 6, 3, 0.25);
		NSBezierPath *bv = [NSBezierPath bezierPath];
		[bv moveToPoint: NSMakePoint(NSMinX(back) + 6, NSMaxY(back) - 5)];
		[bv lineToPoint: NSMakePoint(NSMidX(back), NSMidY(back) - 4)];
		[bv lineToPoint: NSMakePoint(NSMaxX(back) - 6, NSMaxY(back) - 5)];
		[bv setLineWidth: 5];
		[bv setLineJoinStyle: NSLineJoinStyleRound];
		[bv setLineCapStyle: NSLineCapStyleRound];
		[rgb(0.66, 0.76, 0.88) set];
		[bv stroke];
		[NSGraphicsContext restoreGraphicsState];

		/* the letter in front, address side up */
		NSRect env = NSMakeRect(30, 46, 190, 130);
		shadowed(^{
			[[NSColor whiteColor] set];
			[[NSBezierPath bezierPathWithRoundedRect: env xRadius: 11 yRadius: 11] fill];
		}, 9, 5, 0.30);
		/* the address: three lines */
		NSColor *ink = rgb(0.36, 0.48, 0.64);
		double ys[] = { 96, 82, 68 }, ws[] = { 78, 92, 58 };
		for (int i = 0; i < 3; i++) {
			NSBezierPath *l = [NSBezierPath bezierPath];
			[l moveToPoint: NSMakePoint(80, ys[i])];
			[l lineToPoint: NSMakePoint(80 + ws[i], ys[i])];
			[l setLineWidth: 6];
			[l setLineCapStyle: NSLineCapStyleRound];
			[[ink colorWithAlphaComponent: i == 0 ? 0.85 : 0.5] set];
			[l stroke];
		}

		/* the stamp: cream perforated paper, a sun over hills */
		NSRect stamp = NSMakeRect(162, 110, 44, 54);
		shadowed(^{ [rgb(0.99, 0.96, 0.88) set]; [perforated(stamp, 6, 7) fill]; }, 2.5, 1, 0.35);
		NSRect face = NSInsetRect(stamp, 5, 5);
		[NSGraphicsContext saveGraphicsState];
		[[NSBezierPath bezierPathWithRect: face] addClip];
		[[[NSGradient alloc] initWithStartingColor: rgb(0.62, 0.84, 0.98) endingColor: rgb(0.86, 0.94, 1.0)]
		    drawInRect: face angle: -90];
		[rgb(0.98, 0.70, 0.18) set];
		[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(NSMidX(face) + 1, NSMinY(face) + 20, 13, 13)] fill];
		NSBezierPath *hills = [NSBezierPath bezierPath];
		[hills moveToPoint: NSMakePoint(NSMinX(face) - 2, NSMinY(face))];
		[hills lineToPoint: NSMakePoint(NSMinX(face) - 2, NSMinY(face) + 14)];
		[hills curveToPoint: NSMakePoint(NSMidX(face) + 2, NSMinY(face) + 12)
		      controlPoint1: NSMakePoint(NSMinX(face) + 8, NSMinY(face) + 26) controlPoint2: NSMakePoint(NSMidX(face) - 6, NSMinY(face) + 20)];
		[hills curveToPoint: NSMakePoint(NSMaxX(face) + 2, NSMinY(face) + 16)
		      controlPoint1: NSMakePoint(NSMidX(face) + 8, NSMinY(face) + 6) controlPoint2: NSMakePoint(NSMaxX(face) - 6, NSMinY(face) + 20)];
		[hills lineToPoint: NSMakePoint(NSMaxX(face) + 2, NSMinY(face))];
		[hills closePath];
		[rgb(0.24, 0.62, 0.42) set];
		[hills fill];
		[NSGraphicsContext restoreGraphicsState];
		[[rgb(0.36, 0.48, 0.64) colorWithAlphaComponent: 0.6] set];
		NSFrameRectWithWidth(face, 1);

		/* the postmark: two rings, HELLO FROM over BOSTON between them, and its wavy lines across the stamp */
		NSColor *pm = [rgb(0.12, 0.17, 0.30) colorWithAlphaComponent: 0.80];
		NSPoint c = NSMakePoint(132, 140);
		double R = 29, r = 17;
		[pm set];
		NSBezierPath *outer = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(c.x - R, c.y - R, 2 * R, 2 * R)];
		[outer setLineWidth: 2.2];
		[outer stroke];
		NSBezierPath *inner = [NSBezierPath bezierPathWithOvalInRect: NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)];
		[inner setLineWidth: 1.5];
		[inner stroke];
		NSDictionary *ta = @{ NSFontAttributeName: [NSFont boldSystemFontOfSize: 7.2], NSForegroundColorAttributeName: pm };
		ring_text(@"HELLO FROM", c, (R + r) / 2 - 0.5, 90, NO, ta);
		ring_text(@"BOSTON", c, (R + r) / 2 + 0.5, 270, YES, ta);
		/* the date bars in the middle */
		for (int k = -1; k <= 1; k += 2) {
			NSBezierPath *bar = [NSBezierPath bezierPath];
			[bar moveToPoint: NSMakePoint(c.x - 9, c.y + k * 3)];
			[bar lineToPoint: NSMakePoint(c.x + 9, c.y + k * 3)];
			[bar setLineWidth: 1.8];
			[bar stroke];
		}
		for (int k = 0; k < 4; k++) {
			NSBezierPath *w = [NSBezierPath bezierPath];
			double y0 = c.y + 15 - k * 9.5, x0 = c.x + R + 2;
			[w moveToPoint: NSMakePoint(x0, y0)];
			for (double x = 0; x <= 56; x += 1)
				[w lineToPoint: NSMakePoint(x0 + x, y0 + 2.8 * sin(x / 56 * 2 * M_PI * 1.5))];
			[w setLineWidth: 1.8];
			[w setLineCapStyle: NSLineCapStyleRound];
			[w stroke];
		}

		[NSGraphicsContext restoreGraphicsState];
		NSData *png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
		if (![png writeToFile: [NSString stringWithUTF8String: out] atomically: YES])
			return 1;
	}
	return 0;
}
