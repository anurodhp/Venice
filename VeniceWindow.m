/*
 * venice: the player window (see VeniceWindow.h).
 */
#import "VeniceWindow.h"
#import "VeniceView.h"
#import <GNUstepGUI/GSDisplayServer.h>
#include "VeniceX.h"
#include <math.h>

/* The control strip under the video, iOS player style (VeniceControls.h):
 * the scrubber across the window, the elapsed and remaining times under its
 * ends, the transport centred, the volume row at the bottom. Rows, from the
 * top of the strip: */
#define SCRUB_Y 6
#define SCRUB_H 16
#define TIME_Y 22
#define TIME_H 14
#define TRANSPORT_Y 36
#define TRANSPORT_H 40
#define VOLUME_Y 80
#define VOLUME_H 24
#define BAR_H 108
#define MARGIN 14
#define SKIP_SECONDS 10
#define DEFAULT_MAX_VIDEO_WIDTH 1280

/* The video view also takes files dropped on it. */
@interface VeniceDropView : VeniceView
@end

@implementation VeniceDropView
- (NSDragOperation) draggingEntered: (id <NSDraggingInfo>)info
{
	return [[[info draggingPasteboard] types] containsObject: NSFilenamesPboardType] ? NSDragOperationCopy
	                                                                                 : NSDragOperationNone;
}
- (BOOL) performDragOperation: (id <NSDraggingInfo>)info
{
	NSArray *files = [[info draggingPasteboard] propertyListForType: NSFilenamesPboardType];
	if ([files count] == 0)
		return NO;
	[target openPath: [files objectAtIndex: 0]];
	return YES;
}
@end

static NSString *
format_time(double t)
{
	if (!(t >= 0) || isinf(t))
		t = 0;
	long s = (long)t;
	if (s >= 3600)
		return [NSString stringWithFormat: @"%ld:%02ld:%02ld", s / 3600, (s / 60) % 60, s % 60];
	return [NSString stringWithFormat: @"%ld:%02ld", s / 60, s % 60];
}

@implementation VeniceWindow

- (id) init
{
	if ((self = [super init]) == nil)
		return nil;
	player = [[VenicePlayer alloc] initWithDelegate: self];
	if (player == nil) {
		[self release];
		return nil;
	}
	/* 854x480 of video, or less on a small screen (the Pi's HDMI is often
	 * 640x480): a window the server clamps leaves AppKit's autoresizing
	 * working from the wrong size */
	NSRect vis = [[NSScreen mainScreen] visibleFrame];
	CGFloat w0 = 854, h0 = 480;
	if (!NSIsEmptyRect(vis)) {
		CGFloat sc = MIN(1.0, MIN(NSWidth(vis) * 0.9 / w0, (NSHeight(vis) * 0.9 - BAR_H - 24) / h0));
		w0 = floor(w0 * sc);
		h0 = floor(h0 * sc);
	}
	NSRect content = NSMakeRect(0, 0, w0, h0 + BAR_H);
	window = [[NSWindow alloc] initWithContentRect: content
	    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask
	    backing: NSBackingStoreBuffered defer: NO];
	[window setTitle: @"Venice"];
	[window setMinSize: NSMakeSize(MIN(420, w0), MIN(240, h0) + BAR_H)];
	[window setDelegate: self];
	[window setReleasedWhenClosed: NO];
	NSView *cv = [window contentView];
	CGFloat w = NSWidth(content);

	videoView = [[VeniceDropView alloc] initWithFrame: NSMakeRect(0, BAR_H, w, NSHeight(content) - BAR_H) player: player];
	[videoView setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
	[videoView setTarget: self];
	[videoView registerForDraggedTypes: [NSArray arrayWithObject: NSFilenamesPboardType]];
	[cv addSubview: videoView];

	[window setBackgroundColor: [NSColor blackColor]];
	bar = [[VeniceBarView alloc] initWithFrame: NSMakeRect(0, 0, w, BAR_H)];
	[cv addSubview: bar];
	scrubber = [[VeniceTrack alloc] initWithFrame: NSMakeRect(0, 0, 10, SCRUB_H) target: self action: @selector(scrub:)];
	[scrubber setEnabled: NO];
	backButton = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconBack target: self
	    action: @selector(skipBack:)];
	playButton = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconPlay target: self
	    action: @selector(togglePause:)];
	forwardButton = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconForward target: self
	    action: @selector(skipForward:)];
	volDown = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconSpeakerLow target: self
	    action: @selector(volumeDown:)];
	volUp = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconSpeakerHigh target: self
	    action: @selector(volumeUp:)];
	volumeTrack = [[VeniceTrack alloc] initWithFrame: NSMakeRect(0, 0, 10, VOLUME_H) target: self
	    action: @selector(volumeDragged:)];
	[volumeTrack setMaxValue: 100];
	[backButton setToolTip: @"Back 10 seconds"];
	[forwardButton setToolTip: @"Forward 10 seconds"];
	[volDown setToolTip: @"Volume down"];
	[volUp setToolTip: @"Volume up"];
	fullscreenButton = [[VeniceIconButton alloc] initWithFrame: NSZeroRect icon: VeniceIconFullscreen target: self
	    action: @selector(toggleFullscreen:)];
	[fullscreenButton setToolTip: @"Full screen (Esc to leave)"];
	for (NSView *v in [NSArray arrayWithObjects: scrubber, backButton, playButton, forwardButton, volDown,
	                                            volumeTrack, volUp, fullscreenButton, nil]) {
		[bar addSubview: v];
		[v release];
	}
	[self layoutViews];
	[self playerStateChanged: player];
	return self;
}

- (void) dealloc
{
	[infoTimer invalidate];
	[infoPanel release];
	[videoView stop];
	[player shutdown];
	[videoView release];
	[bar release];
	[window release];
	[player release];
	[pending release];
	[super dealloc];
}

- (NSWindow *) window { return window; }

/* The video fills the content view above the bar. Set from the content
 * view's real size on every resize rather than left to autoresizing, which
 * adds up size deltas and goes wrong for good once one is missed. */
- (void) layoutViews
{
	NSRect b = [[window contentView] bounds];
	CGFloat w = NSWidth(b), cx = floor(w / 2);
	/* full screen: the video alone */
	CGFloat bh = fullscreen ? 0 : BAR_H;
	[bar setHidden: fullscreen];
	[bar setFrame: NSMakeRect(0, 0, w, BAR_H)];
	[videoView setFrame: NSMakeRect(0, bh, w, MAX(1, NSHeight(b) - bh))];
	/* the bar is flipped: y runs down from the video's bottom edge */
	[scrubber setFrame: NSMakeRect(MARGIN - 6, SCRUB_Y, w - 2 * MARGIN + 12, SCRUB_H)];
	[bar setLeftRect: NSMakeRect(MARGIN, TIME_Y, 100, TIME_H) rightRect: NSMakeRect(w - MARGIN - 100, TIME_Y, 100, TIME_H)];
	CGFloat t = TRANSPORT_H;
	[playButton setFrame: NSMakeRect(cx - t / 2, TRANSPORT_Y, t, t)];
	[backButton setFrame: NSMakeRect(cx - t / 2 - 24 - t, TRANSPORT_Y, t, t)];
	[forwardButton setFrame: NSMakeRect(cx + t / 2 + 24, TRANSPORT_Y, t, t)];
	[fullscreenButton setFrame: NSMakeRect(w - MARGIN - 28, TRANSPORT_Y + (t - 28) / 2, 28, 28)];
	/* the volume row: at most 360 wide, centred, speakers at its ends */
	CGFloat vw = MIN(w - 2 * MARGIN, 360), vx = cx - floor(vw / 2), sw = 28;
	[volDown setFrame: NSMakeRect(vx, VOLUME_Y, sw, VOLUME_H)];
	[volUp setFrame: NSMakeRect(vx + vw - sw, VOLUME_Y, sw, VOLUME_H)];
	[volumeTrack setFrame: NSMakeRect(vx + sw + 4, VOLUME_Y, vw - 2 * sw - 8, VOLUME_H)];
	[bar setNeedsDisplay: YES];
}

- (void) windowDidResize: (NSNotification *)n
{
	[self layoutViews];
}
- (VenicePlayer *) player { return player; }

- (void) show
{
	[window center];
	[window makeKeyAndOrderFront: nil];
	[self layoutViews];
	[window makeFirstResponder: videoView];
	/* the X child window needs the GNUstep window on the server: after the
	 * order-front, on the next pass of the run loop */
	[self performSelector: @selector(startVideo) withObject: nil afterDelay: 0];
}

- (void) startVideo
{
	if (started)
		return;
	started = [videoView start];
	if (!started)
		[window setTitle: @"Venice (no video renderer)"];
	if (pending != nil) {
		[player open: pending];
		DESTROY(pending);
	}
}

- (void) openPath: (NSString *)pathOrURL
{
	if (![window isVisible])
		[self show];
	sizedForVideo = NO;
	[window setTitle: [pathOrURL lastPathComponent]];
	if (!started)
		ASSIGN(pending, pathOrURL);     /* opened once the video surface exists */
	else
		[player open: pathOrURL];
}

/* ---- controls ---- */

/* A clicked button becomes first responder, and space would then press it:
 * give the keys back to the video. */
- (void) refocus: (id)sender
{
	if ([sender isKindOfClass: [NSControl class]])
		[window makeFirstResponder: videoView];
}

- (void) togglePause: (id)sender { [player togglePause]; [self refocus: sender]; }
- (void) volumeUp: (id)sender { [player changeVolumeBy: 5]; [self refocus: sender]; }
- (void) volumeDown: (id)sender { [player changeVolumeBy: -5]; [self refocus: sender]; }
- (void) toggleMute: (id)sender { [player toggleMute]; }
- (void) seekForward: (id)sender { [player seekBy: 5]; }
- (void) seekBackward: (id)sender { [player seekBy: -5]; }
- (void) skipForward: (id)sender { [player seekBy: SKIP_SECONDS]; }
- (void) skipBack: (id)sender { [player seekBy: -SKIP_SECONDS]; }

- (void) volumeDragged: (id)sender
{
	[player setVolume: [volumeTrack doubleValue]];
}

- (void) scrub: (id)sender
{
	double t = [scrubber doubleValue];
	if ([scrubber isDragging]) {
		/* keyframe seeks while dragging, at most ten a second */
		scrubbing = YES;
		double now = venice_now_ms();
		if (now - lastScrubMs > 100) {
			[player seekTo: t exact: NO];
			lastScrubMs = now;
		}
		[bar setLeftText: format_time(t) rightText: [self remainingText: t]];
	} else {
		scrubbing = NO;
		[player seekTo: t exact: YES];
		[self refocus: sender];
	}
}

- (BOOL) handleKey: (NSEvent *)ev
{
	NSString *chars = [ev charactersIgnoringModifiers];
	if ([chars length] == 0)
		return NO;
	unichar c = [chars characterAtIndex: 0];
	BOOL shift = ([ev modifierFlags] & NSShiftKeyMask) != 0;
	switch (c) {
	case ' ': [player togglePause]; return YES;
	case NSRightArrowFunctionKey: [player seekBy: shift ? 30 : 5]; return YES;
	case NSLeftArrowFunctionKey: [player seekBy: shift ? -30 : -5]; return YES;
	case NSUpArrowFunctionKey: [player changeVolumeBy: 5]; return YES;
	case NSDownArrowFunctionKey: [player changeVolumeBy: -5]; return YES;
	case 'm': case 'M': [player toggleMute]; return YES;
	case 'f': case 'F': [self toggleFullscreen: self]; return YES;
	case 0x1b:                  /* Esc leaves full screen */
		if (fullscreen) {
			[self toggleFullscreen: self];
			return YES;
		}
		return NO;
	}
	return NO;
}

/* ---- full screen ---- */

- (BOOL) isFullscreen { return fullscreen; }

- (void) toggleFullscreen: (id)sender
{
	GSDisplayServer *srv = GSCurrentServer();
	unsigned long xwin = (unsigned long)(uintptr_t)[srv windowDevice: [window windowNumber]];
	fullscreen = !fullscreen;
	/* the strip goes first, so the resize Window Maker answers with is laid out for the video alone */
	[self layoutViews];
	venice_x_set_fullscreen(xwin, fullscreen);
	[window makeFirstResponder: videoView];
}

/* ---- Video Info ---- */

static void
info_line(NSMutableString *s, NSString *label, NSString *value)
{
	[s appendFormat: @"%@%@\n", [label stringByPaddingToLength: 16 withString: @" " startingAtIndex: 0],
	    value != nil && [value length] > 0 ? value : @"-"];
}

- (NSString *) infoText
{
	VenicePlayer *p = player;
	NSMutableString *s = [NSMutableString string];
	NSString *(^prop)(const char *) = ^(const char *n) { return [p property: n]; };
	NSString *(^join)(NSString *, NSString *, NSString *) = ^(NSString *a, NSString *sep, NSString *b) {
		return a != nil && b != nil ? [NSString stringWithFormat: @"%@%@%@", a, sep, b] : nil;
	};
	info_line(s, @"File", [p path]);
	info_line(s, @"Title", [p title]);
	info_line(s, @"Container", prop("file-format"));
	info_line(s, @"Position", [NSString stringWithFormat: @"%@ / %@", format_time([p timePos]),
	    [p duration] > 0 ? format_time([p duration]) : @"live"]);
	[s appendString: @"\n"];
	info_line(s, @"Video codec", prop("video-codec"));
	info_line(s, @"Size", join(prop("video-params/w"), @" x ", prop("video-params/h")));
	info_line(s, @"Pixel format", prop("video-params/pixelformat"));
	info_line(s, @"Colour", join(prop("video-params/colormatrix"), @", ", prop("video-params/colorlevels")));
	{
		NSString *fps = prop("container-fps"), *shown = prop("estimated-display-fps");
		info_line(s, @"Frame rate", fps == nil ? nil : shown == nil
		    ? [NSString stringWithFormat: @"%.3g fps", [fps doubleValue]]
		    : [NSString stringWithFormat: @"%.3g fps, %.3g shown", [fps doubleValue], [shown doubleValue]]);
	}
	info_line(s, @"Video bitrate", prop("video-bitrate"));
	{
		NSString *hwdec = prop("hwdec-current");
		info_line(s, @"Decoder", hwdec == nil || [hwdec isEqualToString: @"no"] || [hwdec length] == 0
		    ? @"software (FFmpeg)"
		    : [NSString stringWithFormat: @"hardware, VideoCore VPU (%@)", hwdec]);
	}
	info_line(s, @"Renderer", [NSString stringWithFormat: @"%s: %s", [videoView rendererName], [videoView rendererInfo]]);
	info_line(s, @"Output size", join(prop("osd-width"), @" x ", prop("osd-height")));
	info_line(s, @"Dropped", join(prop("frame-drop-count"), @" output, ", join(prop("decoder-frame-drop-count"), @" decoder", @"")));
	[s appendString: @"\n"];
	info_line(s, @"Audio codec", prop("audio-codec"));
	info_line(s, @"Audio format", join(prop("audio-params/samplerate"), @" Hz, ",
	    join(prop("audio-params/channel-count"), @" ch, ", prop("audio-params/format"))));
	info_line(s, @"Audio bitrate", prop("audio-bitrate"));
	info_line(s, @"Audio output", join(prop("current-ao"), @", ", prop("audio-device")));
	[s appendString: @"\n"];
	info_line(s, @"Cache", prop("demuxer-cache-duration") ? [NSString stringWithFormat: @"%.1f s ahead",
	    [prop("demuxer-cache-duration") doubleValue]] : nil);
	return s;
}

- (void) refreshInfo: (NSTimer *)t
{
	if (![infoPanel isVisible]) {
		[infoTimer invalidate];
		infoTimer = nil;
		return;
	}
	[infoText setString: [self infoText]];
}

- (void) showInfo: (id)sender
{
	if (infoPanel == nil) {
		infoPanel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 560, 460)
		    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
		    backing: NSBackingStoreBuffered defer: NO];
		[infoPanel setTitle: @"Video Info"];
		[infoPanel setReleasedWhenClosed: NO];
		NSScrollView *sv = [[NSScrollView alloc] initWithFrame: [[infoPanel contentView] bounds]];
		[sv setHasVerticalScroller: YES];
		[sv setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
		infoText = [[NSTextView alloc] initWithFrame: [[sv contentView] bounds]];
		[infoText setEditable: NO];
		[infoText setSelectable: YES];
		[infoText setFont: [NSFont userFixedPitchFontOfSize: 11]];
		[infoText setAutoresizingMask: NSViewWidthSizable];
		[sv setDocumentView: infoText];
		[[infoPanel contentView] addSubview: sv];
		[infoText release];
		[sv release];
		[infoPanel center];
	}
	[infoText setString: [self infoText]];
	[infoPanel makeKeyAndOrderFront: nil];
	if (infoTimer == nil)
		infoTimer = [NSTimer scheduledTimerWithTimeInterval: 1.0 target: self selector: @selector(refreshInfo:)
		    userInfo: nil repeats: YES];
}

/* ---- VenicePlayerDelegate ---- */

/* iOS shows the time left, with a minus sign, under the scrubber's right end */
- (NSString *) remainingText: (double)pos
{
	if ([player isIdle])
		return @"";
	if ([player isBuffering])
		return @"Buffering";
	if ([player duration] <= 0)
		return @"LIVE";
	return [@"-" stringByAppendingString: format_time([player duration] - pos)];
}

- (void) playerStateChanged: (VenicePlayer *)p
{
	BOOL live = [p duration] <= 0, idle = [p isIdle] && [p path] == nil;
	[playButton setIcon: [p isPaused] || [p isIdle] ? VeniceIconPlay : VeniceIconPause];
	[playButton setEnabled: !idle];
	[backButton setEnabled: !idle && [p isSeekable]];
	[forwardButton setEnabled: !idle && [p isSeekable]];
	[scrubber setEnabled: !live && [p isSeekable]];
	if (!scrubbing) {
		if (!live) {
			[scrubber setMaxValue: [p duration]];
			[scrubber setDoubleValue: [p timePos]];
		} else {
			[scrubber setDoubleValue: 0];
		}
		[bar setLeftText: [p isIdle] ? @"" : format_time([p timePos]) rightText: [self remainingText: [p timePos]]];
	}
	if (![volumeTrack isDragging])
		[volumeTrack setDoubleValue: [p isMuted] ? 0 : [p volume]];
	[volDown setMuted: [p isMuted]];
	if ([p title] != nil && ![p isIdle])
		[window setTitle: [p title]];
	/* -VeniceQuitAtEnd YES (scripted tests): quit once the file has played to its end */
	if ([p isAtEnd] && [[NSUserDefaults standardUserDefaults] boolForKey: @"VeniceQuitAtEnd"]) {
		NSLog(@"venice: end of %@ (renderer %s) %@", [p path], [videoView rendererName], [p playbackStats]);
		[NSApp terminate: nil];
	}
}

/* Fit the window to a new video: its own size, scaled down to fit the screen. */
- (void) player: (VenicePlayer *)p videoSizeChanged: (NSSize)size
{
	if (sizedForVideo)
		return;
	sizedForVideo = YES;
	NSRect vis = [[window screen] visibleFrame];
	if (NSIsEmptyRect(vis))
		vis = [[NSScreen mainScreen] visibleFrame];
	CGFloat maxW = NSWidth(vis) * 0.9, maxH = NSHeight(vis) * 0.9 - BAR_H - 24;   /* 24: title bar */
	if (maxW < 1 || maxH < 1)
		return;
	/* VeniceMaxVideoWidth: the widest the window opens for a video (it can
	 * still be resized). On the Pi each GL frame is read back from the GPU and
	 * put by the CPU, which costs in proportion to the window's area. */
	double cap = [[NSUserDefaults standardUserDefaults] doubleForKey: @"VeniceMaxVideoWidth"];
	if (cap <= 0)
		cap = DEFAULT_MAX_VIDEO_WIDTH;
	maxW = MIN(maxW, cap);
	CGFloat scale = MIN(1.0, MIN(maxW / size.width, maxH / size.height));
	NSSize c = NSMakeSize(floor(size.width * scale), floor(size.height * scale) + BAR_H);
	c.width = MAX(c.width, [window minSize].width);
	[window setContentSize: c];
	[self layoutViews];
	if (getenv("VENICE_STATS") != NULL)
		NSLog(@"venice: video %.0fx%.0f, window content %.0fx%.0f (asked %.0fx%.0f), video view %.0fx%.0f",
		    size.width, size.height, NSWidth([[window contentView] frame]), NSHeight([[window contentView] frame]),
		    c.width, c.height, NSWidth([videoView frame]), NSHeight([videoView frame]));
}

- (void) playerWantsFrame: (VenicePlayer *)p
{
	[videoView drawFrame];
}

- (void) player: (VenicePlayer *)p endedWithError: (NSString *)error
{
	if (error == nil)
		return;
	NSLog(@"venice: cannot play %@: %@", [p path], error);
	[window setTitle: [NSString stringWithFormat: @"Cannot play %@ (%@)", [[p path] lastPathComponent], error]];
	if ([[NSUserDefaults standardUserDefaults] boolForKey: @"VeniceQuitAtEnd"])
		exit(1);
}

/* ---- window ---- */

- (void) windowWillClose: (NSNotification *)n
{
	/* mpv_render_context_free before mpv_terminate_destroy (render.h) */
	[videoView stop];
	[player shutdown];
}

@end
