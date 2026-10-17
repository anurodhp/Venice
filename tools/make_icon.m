/* Renders icons/Venice.png (and icons/Venice.tiff with sips): a white play symbol on a rounded lagoon-blue tile, in
 * the shape of Milan's and Naples' icons.
 * Host tool, run once:  clang -fobjc-arc -framework AppKit tools/make_icon.m -o /tmp/make_icon && /tmp/make_icon
 *                       sips -s format tiff icons/Venice.png --out icons/Venice.tiff */
#import <AppKit/AppKit.h>

int
main(void)
{
	@autoreleasepool {
		NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL pixelsWide: 256 pixelsHigh: 256 bitsPerSample: 8
		    samplesPerPixel: 4 hasAlpha: YES isPlanar: NO colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 32];
		NSRect tile = NSMakeRect(8, 8, 240, 240);
		[NSGraphicsContext saveGraphicsState];
		[NSGraphicsContext setCurrentContext: [NSGraphicsContext graphicsContextWithBitmapImageRep: rep]];
		[[NSColor clearColor] set];
		NSRectFillUsingOperation(NSMakeRect(0, 0, 256, 256), NSCompositingOperationClear);
		[[[NSGradient alloc] initWithStartingColor: [NSColor colorWithCalibratedRed: 0.30 green: 0.82 blue: 0.80 alpha: 1]
		                               endingColor: [NSColor colorWithCalibratedRed: 0.05 green: 0.38 blue: 0.55 alpha: 1]]
		    drawInBezierPath: [NSBezierPath bezierPathWithRoundedRect: tile xRadius: 52 yRadius: 52] angle: -90];
		/* the play symbol, optically centred (nudged right of the geometric centre) */
		NSBezierPath *tri = [NSBezierPath bezierPath];
		[tri moveToPoint: NSMakePoint(98, 70)];
		[tri lineToPoint: NSMakePoint(98, 186)];
		[tri lineToPoint: NSMakePoint(196, 128)];
		[tri closePath];
		[tri setLineJoinStyle: NSLineJoinStyleRound];
		[tri setLineWidth: 18];
		[[NSColor whiteColor] set];
		[tri fill];
		[tri stroke];
		[NSGraphicsContext restoreGraphicsState];
		[[rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}] writeToFile: @"icons/Venice.png" atomically: YES];
	}
	return 0;
}
