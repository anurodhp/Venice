/*
 * venice: the video view (see VeniceView.h).
 */
#import "VeniceView.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include "VeniceX.h"
#include <stdio.h>
#include <stdlib.h>

static BOOL g_stats;

/* ---- run loop glue: venice's X connection ---- */

@interface VeniceXWatcher : NSObject <RunLoopEvents>
+ (void) watch;
@end

@implementation VeniceXWatcher
+ (void) watch
{
	static VeniceXWatcher *w;
	Display *dpy = venice_x_display();
	if (w != nil || dpy == NULL)
		return;
	w = [VeniceXWatcher new];
	NSRunLoop *rl = [NSRunLoop currentRunLoop];
	void *fd = (void *)(intptr_t)ConnectionNumber(dpy);
	[rl addEvent: fd type: ET_RDESC watcher: w forMode: NSDefaultRunLoopMode];
	[rl addEvent: fd type: ET_RDESC watcher: w forMode: NSEventTrackingRunLoopMode];
	[rl addEvent: fd type: ET_RDESC watcher: w forMode: NSModalPanelRunLoopMode];
}
- (void) receivedEvent: (void *)data type: (RunLoopEventType)type extra: (void *)extra forMode: (NSString *)mode
{
	venice_x_pump();
}
@end

static void
expose_cb(void *owner)
{
	[(VeniceView *)owner drawFrame];
}

@implementation VeniceView

+ (void) initialize
{
	g_stats = getenv("VENICE_STATS") != NULL;
}

- (id) initWithFrame: (NSRect)frame player: (VenicePlayer *)p
{
	if ((self = [super initWithFrame: frame]) == nil)
		return nil;
	player = [p retain];
	NSString *r = [[NSUserDefaults standardUserDefaults] stringForKey: @"VeniceRenderer"];
	rendererName = [(r ? r : @"gl") copy];
	return self;
}

- (void) dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver: self];
	[self stop];
	[player release];
	[rendererName release];
	[super dealloc];
}

- (BOOL) isFlipped { return YES; }
- (BOOL) isOpaque { return YES; }
- (BOOL) acceptsFirstResponder { return YES; }
- (void) setTarget: (id <VeniceViewTarget>)t { target = t; }
- (const char *) rendererName { return video ? video->name : "none"; }

- (void) drawRect: (NSRect)r
{
	/* covered by the child window; shows only before it exists */
	[[NSColor blackColor] set];
	NSRectFill(r);
}

/* The view's origin in the GNUstep window's X window: as gnustep-back's
 * XGGLContext.m places its GLX sub-window (and Rome's RomeView.m). */
- (NSPoint) xOrigin
{
	NSWindow *w = [self window];
	GSDisplayServer *srv = GSCurrentServer();
	NSRect rect;
	CGFloat height;
	if ([srv handlesWindowDecorations]) {
		NSView *cv = [w contentView];
		rect = [self convertRect: [self bounds] toView: cv];
		if ([cv isFlipped])
			rect.origin.y = NSHeight([cv frame]) - NSMaxY(rect);
		height = NSHeight([cv frame]);
	} else {
		rect = [self convertRect: [self bounds] toView: nil];
		height = NSHeight([w frame]);
	}
	return NSMakePoint(NSMinX(rect), height - NSMaxY(rect));
}

- (BOOL) start
{
	NSWindow *w = [self window];
	if (video != NULL)
		return YES;
	if (w == nil)
		return NO;
	GSDisplayServer *srv = GSCurrentServer();
	Window parent = (Window)(uintptr_t)[srv windowDevice: [w windowNumber]];
	if (parent == 0)
		return NO;
	/* the GNUstep window must exist on the server before venice's
	 * connection makes a child of it */
	SEL xd = @selector(xDisplay);
	if ([srv respondsToSelector: xd]) {
		Display *(*getdpy)(id, SEL) = (Display *(*)(id, SEL))[srv methodForSelector: xd];
		Display *gdpy = getdpy(srv, xd);
		if (gdpy != NULL)
			XSync(gdpy, False);
	}
	NSPoint o = [self xOrigin];
	NSSize s = [self bounds].size;
	mpv_handle *mpv = [player handle];
	BOOL wantSW = [rendererName caseInsensitiveCompare: @"sw"] == NSOrderedSame;
	if (!wantSW)
		video = venice_video_gl_new(mpv, parent, (int)o.x, (int)o.y, (int)s.width, (int)s.height);
	if (video == NULL)
		video = venice_video_sw_new(mpv, parent, (int)o.x, (int)o.y, (int)s.width, (int)s.height);
	if (video == NULL) {
		NSLog(@"venice: no video renderer could start");
		return NO;
	}
	if (g_stats)
		fprintf(stderr, "venice: renderer %s\n", video->name);
	laidOrigin = o;
	laidSize = s;
	venice_x_register((Window)video->win, expose_cb, self);
	[VeniceXWatcher watch];
	[player attachRenderContext: video->rc];
	return YES;
}

- (void) stop
{
	if (video == NULL)
		return;
	[player attachRenderContext: NULL];
	if (g_stats && video->frames > 0)
		fprintf(stderr, "venice-stats: renderer=%s %dx%d frames=%lu draw=%.2fms/frame\n", video->name,
		    video->width, video->height, video->frames, video->t_draw / video->frames);
	video->destroy(video);
	video = NULL;
}

- (void) drawFrame
{
	if (video == NULL)
		return;
	video->draw(video);
	if (g_stats && video->frames % 300 == 0)
		fprintf(stderr, "venice-stats: renderer=%s %dx%d frames=%lu draw=%.2fms/frame\n", video->name,
		    video->width, video->height, video->frames, video->t_draw / video->frames);
	/* XSync in a frame may have queued events (exposes) */
	venice_x_pump();
}

- (void) layoutVideo
{
	if (video == NULL)
		return;
	NSPoint o = [self xOrigin];
	NSSize s = [self bounds].size;
	if (o.x != laidOrigin.x || o.y != laidOrigin.y)
		venice_video_move(video, (int)o.x, (int)o.y);
	if (s.width != laidSize.width || s.height != laidSize.height) {
		video->resize(video, (int)s.width, (int)s.height);
		[self drawFrame];
	}
	laidOrigin = o;
	laidSize = s;
}

- (void) setFrameSize: (NSSize)size
{
	[super setFrameSize: size];
	[self layoutVideo];
}

- (void) setFrameOrigin: (NSPoint)p
{
	[super setFrameOrigin: p];
	[self layoutVideo];
}

/* GNUstep's autoresizing sets the frame with -setFrame:, not through
 * -setFrameSize: (Rome's RomeView.m watches the window for the same reason). */
- (void) setFrame: (NSRect)r
{
	[super setFrame: r];
	[self layoutVideo];
}

- (void) windowResized: (NSNotification *)n
{
	[self layoutVideo];
}

- (void) viewDidMoveToWindow
{
	[super viewDidMoveToWindow];
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc removeObserver: self name: NSWindowDidResizeNotification object: nil];
	if ([self window] != nil)
		[nc addObserver: self selector: @selector(windowResized:) name: NSWindowDidResizeNotification
		    object: [self window]];
}

/* ---- input: the window decides what each does ---- */

- (void) mouseDown: (NSEvent *)ev
{
	if ([ev clickCount] == 1)
		[target togglePause: self];
}

- (void) keyDown: (NSEvent *)ev
{
	if (![target handleKey: ev])
		[super keyDown: ev];
}

@end
