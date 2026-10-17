/*
 * venice: the player window. The video view above a black control strip
 * laid out like the iOS player: the scrubber across the window with the
 * elapsed and remaining times under it, back 10 s / play-pause / forward
 * 10 s, and the volume between Naples' two speakers. Owns the VenicePlayer
 * and is its delegate.
 *
 * Keys (in the video): space plays/pauses, left/right seek 5 s (30 s with
 * Shift), up/down change the volume by 5, m mutes. A click on the video
 * plays/pauses; a file dropped on it plays.
 */
#import <AppKit/AppKit.h>
#import "VenicePlayer.h"
#import "VeniceView.h"
#import "VeniceControls.h"

@interface VeniceWindow : NSObject <VenicePlayerDelegate, VeniceViewTarget>
{
	NSWindow *window;
	VenicePlayer *player;
	VeniceView *videoView;
	VeniceBarView *bar;
	VeniceIconButton *playButton, *backButton, *forwardButton, *volDown, *volUp;
	VeniceTrack *scrubber, *volumeTrack;
	BOOL scrubbing, started, sizedForVideo;
	double lastScrubMs;
	NSString *pending;
}
- (id) init;
- (NSWindow *) window;
- (void) openPath: (NSString *)pathOrURL;
- (VenicePlayer *) player;

- (void) togglePause: (id)sender;
- (void) volumeUp: (id)sender;
- (void) volumeDown: (id)sender;
- (void) toggleMute: (id)sender;
- (void) seekForward: (id)sender;
- (void) seekBackward: (id)sender;
- (BOOL) handleKey: (NSEvent *)ev;
@end
