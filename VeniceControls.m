/*
 * venice: the controls under the video (see VeniceControls.h).
 */
#import "VeniceControls.h"
#include <math.h>

static NSColor *
white(CGFloat a)
{
	return [NSColor colorWithCalibratedWhite: 1 alpha: a];
}

/* ---- icon buttons ---- */

@implementation VeniceIconButton

- (id) initWithFrame: (NSRect)frame icon: (VeniceIcon)i target: (id)t action: (SEL)a
{
	if ((self = [super initWithFrame: frame]) == nil)
		return nil;
	icon = i;
	target = t;
	action = a;
	enabled = YES;
	return self;
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstResponder { return NO; }      /* keys stay with the video */
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (BOOL) isEnabled { return enabled; }
- (void) setEnabled: (BOOL)e
{
	if (e != enabled) {
		enabled = e;
		[self setNeedsDisplay: YES];
	}
}
- (void) setMuted: (BOOL)m
{
	if (m != muted) {
		muted = m;
		[self setNeedsDisplay: YES];
	}
}

- (void) setIcon: (VeniceIcon)i
{
	if (i != icon) {
		icon = i;
		[self setNeedsDisplay: YES];
	}
}

static void
triangle(CGFloat x, CGFloat cy, CGFloat w, CGFloat h, BOOL right)
{
	NSBezierPath *p = [NSBezierPath bezierPath];
	if (right) {
		[p moveToPoint: NSMakePoint(x, cy - h / 2)];
		[p lineToPoint: NSMakePoint(x + w, cy)];
		[p lineToPoint: NSMakePoint(x, cy + h / 2)];
	} else {
		[p moveToPoint: NSMakePoint(x + w, cy - h / 2)];
		[p lineToPoint: NSMakePoint(x, cy)];
		[p lineToPoint: NSMakePoint(x + w, cy + h / 2)];
	}
	[p closePath];
	[p fill];
}

/* The speaker of Naples' menu bar and Sound panel (NaplesSound.m,
 * NaplesDrawSpeaker), same geometry, drawn in its 20x14 box scaled to `b`:
 * the magnet and cone, then `waves` arcs, or a cross when muted. Its Sound
 * panel puts the 0-wave speaker left of the slider and the 3-wave one right,
 * as Venice's volume row does. */
static void
speaker(NSRect b, int waves, BOOL muted)
{
	CGFloat k = MIN(NSWidth(b) / 20, NSHeight(b) / 14) * 0.8;
	NSAffineTransform *t = [NSAffineTransform transform];
	[NSGraphicsContext saveGraphicsState];
	[t translateXBy: NSMidX(b) - 10 * k yBy: NSMidY(b)];
	[t scaleBy: k];
	[t concat];
	CGFloat x = 0, my = 0;
	NSBezierPath *p = [NSBezierPath bezierPath];
	[p moveToPoint: NSMakePoint(x + 1, my - 2.5)];
	[p lineToPoint: NSMakePoint(x + 4, my - 2.5)];
	[p lineToPoint: NSMakePoint(x + 7, my - 6)];
	[p lineToPoint: NSMakePoint(x + 7, my + 6)];
	[p lineToPoint: NSMakePoint(x + 4, my + 2.5)];
	[p lineToPoint: NSMakePoint(x + 1, my + 2.5)];
	[p closePath];
	[p fill];
	if (muted) {
		NSBezierPath *c = [NSBezierPath bezierPath];
		[c setLineWidth: 1.4];
		[c moveToPoint: NSMakePoint(x + 11, my - 3)]; [c lineToPoint: NSMakePoint(x + 17, my + 3)];
		[c moveToPoint: NSMakePoint(x + 11, my + 3)]; [c lineToPoint: NSMakePoint(x + 17, my - 3)];
		[c stroke];
	} else {
		for (int i = 0; i < waves; i++) {
			NSBezierPath *w = [NSBezierPath bezierPath];
			[w setLineWidth: 1.3];
			[w setLineCapStyle: NSRoundLineCapStyle];
			[w appendBezierPathWithArcWithCenter: NSMakePoint(x + 3.5, my) radius: 6 + 3.5 * i startAngle: -45 endAngle: 45];
			[w stroke];
		}
	}
	[NSGraphicsContext restoreGraphicsState];
}

- (void) drawRect: (NSRect)r
{
	[[NSColor blackColor] set];
	NSRectFill(r);
	[(!enabled ? white(0.3) : pressed ? white(0.55) : white(1)) set];
	NSRect b = [self bounds];
	CGFloat s = MIN(NSWidth(b), NSHeight(b)), cx = NSMidX(b), cy = NSMidY(b);
	switch (icon) {
	case VeniceIconPlay:
		triangle(cx - s * 0.22, cy, s * 0.5, s * 0.56, YES);
		break;
	case VeniceIconPause: {
		CGFloat w = s * 0.16, h = s * 0.54, gap = s * 0.14;
		[[NSBezierPath bezierPathWithRoundedRect: NSMakeRect(cx - gap / 2 - w, cy - h / 2, w, h) xRadius: w / 4 yRadius: w / 4] fill];
		[[NSBezierPath bezierPathWithRoundedRect: NSMakeRect(cx + gap / 2, cy - h / 2, w, h) xRadius: w / 4 yRadius: w / 4] fill];
		break;
	}
	case VeniceIconBack:
		triangle(cx - s * 0.36, cy, s * 0.36, s * 0.4, NO);
		triangle(cx, cy, s * 0.36, s * 0.4, NO);
		break;
	case VeniceIconForward:
		triangle(cx - s * 0.36, cy, s * 0.36, s * 0.4, YES);
		triangle(cx, cy, s * 0.36, s * 0.4, YES);
		break;
	case VeniceIconSpeakerLow:
		speaker(b, 0, muted);
		break;
	case VeniceIconSpeakerHigh:
		speaker(b, 3, NO);
		break;
	case VeniceIconFullscreen: {
		/* four L-shaped corners, open towards the edges */
		CGFloat h = floor(s * 0.30), a = floor(s * 0.13);
		NSBezierPath *p = [NSBezierPath bezierPath];
		for (int dx = -1; dx <= 1; dx += 2) {
			for (int dy = -1; dy <= 1; dy += 2) {
				CGFloat x = cx + dx * h, y = cy + dy * h;
				[p moveToPoint: NSMakePoint(x - dx * a, y)];
				[p lineToPoint: NSMakePoint(x, y)];
				[p lineToPoint: NSMakePoint(x, y - dy * a)];
			}
		}
		[p setLineWidth: MAX(2, s * 0.07)];
		[p setLineCapStyle: NSRoundLineCapStyle];
		[p setLineJoinStyle: NSRoundLineJoinStyle];
		[p stroke];
		break;
	}
	}
}

- (void) mouseDown: (NSEvent *)ev
{
	if (!enabled)
		return;
	pressed = YES;
	[self setNeedsDisplay: YES];
	for (;;) {
		NSEvent *e = [[self window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask];
		NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
		BOOL in = NSPointInRect(p, [self bounds]);
		if ([e type] == NSLeftMouseUp) {
			pressed = NO;
			[self setNeedsDisplay: YES];
			if (in)
				[NSApp sendAction: action to: target from: self];
			return;
		}
		if (in != pressed) {
			pressed = in;
			[self setNeedsDisplay: YES];
		}
	}
}

@end

/* ---- tracks ---- */

#define KNOB_R 6.0
#define TRACK_H 3.0

@implementation VeniceTrack

- (id) initWithFrame: (NSRect)frame target: (id)t action: (SEL)a
{
	if ((self = [super initWithFrame: frame]) == nil)
		return nil;
	target = t;
	action = a;
	maxValue = 1;
	enabled = YES;
	showsKnob = YES;
	lastKnobX = -1;
	return self;
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstResponder { return NO; }
- (BOOL) acceptsFirstMouse: (NSEvent *)e { return YES; }
- (BOOL) isDragging { return dragging; }
- (BOOL) isEnabled { return enabled; }
- (double) doubleValue { return value; }
- (double) maxValue { return maxValue; }
- (void) setMinValue: (double)v { minValue = v; lastKnobX = -1; }
- (void) setMaxValue: (double)v
{
	if (v != maxValue) {
		maxValue = v;
		lastKnobX = -1;
		[self setNeedsDisplay: YES];
	}
}
- (void) setEnabled: (BOOL)e
{
	if (e != enabled) {
		enabled = e;
		[self setNeedsDisplay: YES];
	}
}

/* the knob's centre travels from KNOB_R to width - KNOB_R */
- (CGFloat) knobX
{
	CGFloat w = NSWidth([self bounds]) - 2 * KNOB_R;
	double f = maxValue > minValue ? (value - minValue) / (maxValue - minValue) : 0;
	f = f < 0 ? 0 : f > 1 ? 1 : f;
	return floor(KNOB_R + f * w + 0.5);
}

- (void) setDoubleValue: (double)v
{
	value = v;
	/* redraw only when the knob moves by a pixel */
	if ([self knobX] != lastKnobX)
		[self setNeedsDisplay: YES];
}

- (void) drawRect: (NSRect)r
{
	[[NSColor blackColor] set];
	NSRectFill(r);
	NSRect b = [self bounds];
	CGFloat cy = floor(NSMidY(b)), x = [self knobX];
	lastKnobX = x;
	NSRect track = NSMakeRect(KNOB_R, cy - TRACK_H / 2, NSWidth(b) - 2 * KNOB_R, TRACK_H);
	[white(enabled ? 0.3 : 0.18) set];
	[[NSBezierPath bezierPathWithRoundedRect: track xRadius: TRACK_H / 2 yRadius: TRACK_H / 2] fill];
	if (!enabled)
		return;
	NSRect done = track;
	done.size.width = MAX(0, x - NSMinX(track));
	[white(1) set];
	[[NSBezierPath bezierPathWithRoundedRect: done xRadius: TRACK_H / 2 yRadius: TRACK_H / 2] fill];
	CGFloat kr = dragging ? KNOB_R : KNOB_R - 1.5;
	[[NSBezierPath bezierPathWithOvalInRect: NSMakeRect(x - kr, cy - kr, 2 * kr, 2 * kr)] fill];
}

- (void) trackTo: (NSEvent *)e
{
	NSPoint p = [self convertPoint: [e locationInWindow] fromView: nil];
	CGFloat w = NSWidth([self bounds]) - 2 * KNOB_R;
	double f = w > 0 ? (p.x - KNOB_R) / w : 0;
	f = f < 0 ? 0 : f > 1 ? 1 : f;
	value = minValue + f * (maxValue - minValue);
	[self setNeedsDisplay: YES];
	[NSApp sendAction: action to: target from: self];
}

- (void) mouseDown: (NSEvent *)ev
{
	if (!enabled)
		return;
	dragging = YES;
	[self trackTo: ev];
	for (;;) {
		NSEvent *e = [[self window] nextEventMatchingMask: NSLeftMouseUpMask | NSLeftMouseDraggedMask];
		if ([e type] == NSLeftMouseUp) {
			dragging = NO;
			[self trackTo: e];
			return;
		}
		[self trackTo: e];
	}
}

@end

/* ---- the bar ---- */

@implementation VeniceBarView

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }

- (void) dealloc
{
	[left release];
	[right release];
	[super dealloc];
}

- (void) setLeftRect: (NSRect)l rightRect: (NSRect)r
{
	leftRect = l;
	rightRect = r;
	[self setNeedsDisplay: YES];
}

- (void) setLeftText: (NSString *)l rightText: (NSString *)r
{
	if (![l isEqualToString: left]) {
		ASSIGN(left, l);
		[self setNeedsDisplayInRect: leftRect];
	}
	if (![r isEqualToString: right]) {
		ASSIGN(right, r);
		[self setNeedsDisplayInRect: rightRect];
	}
}

- (void) drawRect: (NSRect)r
{
	[[NSColor blackColor] set];
	NSRectFill(r);
	NSMutableParagraphStyle *ps = [[[NSParagraphStyle defaultParagraphStyle] mutableCopy] autorelease];
	NSMutableDictionary *a = [NSMutableDictionary dictionaryWithObjectsAndKeys:
	    [NSFont systemFontOfSize: 11], NSFontAttributeName,
	    white(0.65), NSForegroundColorAttributeName, ps, NSParagraphStyleAttributeName, nil];
	if (left != nil && NSIntersectsRect(r, leftRect)) {
		[ps setAlignment: NSLeftTextAlignment];
		[left drawInRect: leftRect withAttributes: a];
	}
	if (right != nil && NSIntersectsRect(r, rightRect)) {
		[ps setAlignment: NSRightTextAlignment];
		[right drawInRect: rightRect withAttributes: a];
	}
}

@end
