/*
 * Venice: a small video player for GNUstep, on libmpv. See README.md.
 *
 *   Venice [file-or-URL]
 *
 * Plays local files and network streams (http, https, HLS, RTMP, UDP, ...;
 * whatever FFmpeg's protocols and demuxers take). Defaults (all optional):
 * VeniceRenderer (gl, the default, or sw), VeniceMPVOptions
 * ("key=value,key=value", passed to mpv), VeniceHardwareDecoding (NO:
 * decode in software even where the VPU could), VeniceQuitAtEnd (YES: quit
 * when the file ends, exit status 1 if it cannot be played; for scripted
 * tests).
 * Environment: VENICE_DEBUG=1 prints
 * mpv's log, VENICE_STATS=1 the renderer's frame times.
 */
#import <AppKit/AppKit.h>
#import "VeniceWindow.h"

/* Exceptions raised inside the event loop are reported through an NSAlert
 * that this theme suppresses when the text is empty (Milan's main.m). Log
 * them instead. */
@interface VeniceApplication : NSApplication
@end

@implementation VeniceApplication
- (void) reportException: (NSException *)e
{
	NSLog(@"VENICE EXCEPTION %@: %@ %@", [e name], [e reason], [e userInfo]);
}
@end

@interface VeniceApp : NSObject
{
	VeniceWindow *player;
	NSPanel *urlPanel;
	NSTextField *urlField;
	NSString *lastURL;
}
@end

static NSMenuItem *
add_item(NSMenu *m, NSString *title, SEL action, NSString *key, id target)
{
	NSMenuItem *i = (NSMenuItem *)[m addItemWithTitle: title action: action keyEquivalent: key ? key : @""];
	[i setTarget: target];
	return i;
}

/* The first argument that is not a GNUstep default (-Key value). */
static NSString *
argument_to_open(void)
{
	NSArray *args = [[NSProcessInfo processInfo] arguments];
	for (NSUInteger i = 1; i < [args count]; i++) {
		NSString *a = [args objectAtIndex: i];
		if ([a hasPrefix: @"-"] && [a length] > 1) {
			i++;            /* skip its value */
			continue;
		}
		return a;
	}
	return nil;
}

@implementation VeniceApp

- (VeniceWindow *) playerWindow
{
	/* a closed window has shut its mpv down: start a fresh one */
	if (player != nil && [[player player] handle] == NULL)
		DESTROY(player);
	if (player == nil) {
		player = [[VeniceWindow alloc] init];
		if (player == nil)
			NSLog(@"venice: cannot start mpv");
	}
	return player;
}

- (void) openPath: (NSString *)p
{
	if (p != nil)
		[[self playerWindow] openPath: p];
}

- (void) openFile: (id)sender
{
	NSOpenPanel *op = [NSOpenPanel openPanel];
	[op setAllowsMultipleSelection: NO];
	[op setCanChooseDirectories: NO];
	[op setTitle: @"Open Video"];
	if ([op runModalForDirectory: nil file: nil types: nil] == NSOKButton)
		[self openPath: [[op filenames] objectAtIndex: 0]];
}

/* ---- Open URL: a titled panel (titled windows paint on this stack) ---- */

- (void) urlOK: (id)sender { [NSApp stopModalWithCode: NSOKButton]; }
- (void) urlCancel: (id)sender { [NSApp stopModalWithCode: NSCancelButton]; }

- (void) openURL: (id)sender
{
	if (urlPanel == nil) {
		urlPanel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 480, 104)
		    styleMask: NSTitledWindowMask | NSClosableWindowMask backing: NSBackingStoreBuffered defer: NO];
		[urlPanel setTitle: @"Open URL"];
		NSView *cv = [urlPanel contentView];
		NSTextField *l = [[NSTextField alloc] initWithFrame: NSMakeRect(16, 72, 448, 18)];
		[l setStringValue: @"Stream or file URL (http, https, HLS .m3u8, rtmp, udp, ...):"];
		[l setEditable: NO];
		[l setBezeled: NO];
		[l setDrawsBackground: NO];
		[cv addSubview: l];
		[l release];
		urlField = [[NSTextField alloc] initWithFrame: NSMakeRect(16, 44, 448, 24)];
		[urlField setTarget: self];
		[urlField setAction: @selector(urlOK:)];
		[cv addSubview: urlField];
		NSButton *ok = [[NSButton alloc] initWithFrame: NSMakeRect(384, 10, 80, 26)];
		[ok setTitle: @"Open"];
		[ok setTarget: self];
		[ok setAction: @selector(urlOK:)];
		[ok setKeyEquivalent: @"\r"];
		[cv addSubview: ok];
		[ok release];
		NSButton *cancel = [[NSButton alloc] initWithFrame: NSMakeRect(296, 10, 80, 26)];
		[cancel setTitle: @"Cancel"];
		[cancel setTarget: self];
		[cancel setAction: @selector(urlCancel:)];
		[cancel setKeyEquivalent: @"\e"];
		[cv addSubview: cancel];
		[cancel release];
	}
	[urlField setStringValue: lastURL ? lastURL : @""];
	[urlPanel center];
	[urlPanel makeFirstResponder: urlField];
	NSInteger r = [NSApp runModalForWindow: urlPanel];
	[urlPanel orderOut: nil];
	NSString *u = [[urlField stringValue] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	if (r == NSOKButton && [u length] > 0) {
		ASSIGN(lastURL, u);
		[self openPath: u];
	}
}

/* ---- playback menu: to the player window ---- */

- (void) togglePause: (id)s { [player togglePause: s]; }
- (void) volumeUp: (id)s { [player volumeUp: s]; }
- (void) volumeDown: (id)s { [player volumeDown: s]; }
- (void) toggleMute: (id)s { [player toggleMute: s]; }
- (void) seekForward: (id)s { [player seekForward: s]; }
- (void) seekBackward: (id)s { [player seekBackward: s]; }
- (void) toggleFullscreen: (id)s { [player toggleFullscreen: s]; }
- (void) showInfo: (id)s { [player showInfo: s]; }

- (BOOL) validateMenuItem: (NSMenuItem *)i
{
	SEL a = [i action];
	if (a == @selector(openFile:) || a == @selector(openURL:) || a == @selector(showAbout:))
		return YES;
	return player != nil && [[player window] isVisible] && [[player player] path] != nil;
}

- (void) showAbout: (id)sender
{
	NSDictionary *opts = [NSDictionary dictionaryWithObjectsAndKeys:
	    @"Venice", @"ApplicationName",
	    @"A small video player for GNUstep, on libmpv.", @"ApplicationDescription",
	    @"0.1", @"ApplicationRelease",
	    [NSArray arrayWithObject: @"Anurodh Pokharel"], @"Authors",
	    @"Copyright © 2026 Anurodh Pokharel. MIT license.", @"Copyright",
	    @"Playback by libmpv (mpv 0.40, LGPL-2.1+) and FFmpeg 7.1 (LGPL-3).", @"CopyrightDescription",
	    nil];
	[NSApp orderFrontStandardAboutPanelWithOptions: opts];
}

- (void) buildMenus
{
	NSMenu *main = [[NSMenu alloc] initWithTitle: @"Venice"], *m;
	m = [[NSMenu alloc] initWithTitle: @"Venice"];
	add_item(m, @"About Venice", @selector(showAbout:), nil, self);
	add_item(m, @"Hide Venice", @selector(hide:), @"h", NSApp);
	add_item(m, @"Quit Venice", @selector(terminate:), @"q", NSApp);
	[main setSubmenu: m forItem: add_item(main, @"Venice", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"File"];
	add_item(m, @"Open…", @selector(openFile:), @"o", self);
	add_item(m, @"Open URL…", @selector(openURL:), @"u", self);
	add_item(m, @"Close Window", @selector(performClose:), @"w", nil);
	[main setSubmenu: m forItem: add_item(main, @"File", NULL, nil, nil)]; [m release];

	m = [[NSMenu alloc] initWithTitle: @"Playback"];
	add_item(m, @"Play/Pause", @selector(togglePause:), @"p", self);
	add_item(m, @"Skip Forward 5 s", @selector(seekForward:), @"]", self);
	add_item(m, @"Skip Back 5 s", @selector(seekBackward:), @"[", self);
	add_item(m, @"Volume Up", @selector(volumeUp:), @"=", self);
	add_item(m, @"Volume Down", @selector(volumeDown:), @"-", self);
	add_item(m, @"Mute", @selector(toggleMute:), @"m", self);
	add_item(m, @"Enter/Leave Full Screen", @selector(toggleFullscreen:), @"f", self);
	add_item(m, @"Video Info", @selector(showInfo:), @"i", self);
	[main setSubmenu: m forItem: add_item(main, @"Playback", NULL, nil, nil)]; [m release];

	[NSApp setMainMenu: main];
	[main release];
}

- (void) applicationDidFinishLaunching: (NSNotification *)n
{
	[self buildMenus];
	VeniceWindow *w = [self playerWindow];
	if (w == nil) {
		[NSApp terminate: nil];
		return;
	}
	NSString *arg = argument_to_open();
	if (arg != nil)
		[self openPath: arg];
	else if (![[w window] isVisible])
		[w performSelector: @selector(show)];
}

/* Open With from Milan, and documents dropped on the Dock icon */
- (BOOL) application: (NSApplication *)app openFile: (NSString *)file
{
	[self openPath: file];
	return YES;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *)a
{
	return player == nil || ![[player window] isVisible];
}

- (void) applicationWillTerminate: (NSNotification *)n
{
	[player release];       /* frees the render context, then mpv */
	player = nil;
}

@end

int
main(int argc, const char *argv[])
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	VeniceApp *delegate;
	[VeniceApplication sharedApplication];
	delegate = [[VeniceApp alloc] init];
	[NSApp setDelegate: delegate];
	[NSApp run];
	[pool release];
	return 0;
}
