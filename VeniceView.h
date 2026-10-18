/*
 * venice: the video view. An NSView whose pixels are a child X window drawn
 * by a VeniceVideo surface (VeniceX.h says why). Clicks and keys reach it
 * through AppKit as usual; it passes them to its target (the window).
 */
#import <AppKit/AppKit.h>
#import "VenicePlayer.h"
#include "VeniceVideo.h"

/* What the view's clicks and keys go to (VeniceWindow). */
@protocol VeniceViewTarget
- (void) togglePause: (id)sender;
- (void) toggleFullscreen: (id)sender;
- (BOOL) handleKey: (NSEvent *)ev;
- (void) openPath: (NSString *)pathOrURL;
@end

@interface VeniceView : NSView
{
	VenicePlayer *player;
	VeniceVideo *video;
	NSString *rendererName;
	NSPoint laidOrigin;
	NSSize laidSize;
	id <VeniceViewTarget> target;
}
- (id) initWithFrame: (NSRect)frame player: (VenicePlayer *)p;
/* Make the child window and the render context (once the view is in a
 * window that exists on the server). Returns NO when no renderer starts. */
- (BOOL) start;
- (void) drawFrame;
/* Free the render context (before the player shuts mpv down). */
- (void) stop;
- (const char *) rendererName;
/* what the surface draws with ("OpenGL 2.1 ..., VC4 V3D 2.1"), or "" */
- (const char *) rendererInfo;
/* the child X window the video is drawn into (0 before -start) */
- (unsigned long) videoWindow;
- (void) setTarget: (id <VeniceViewTarget>)t;
@end
