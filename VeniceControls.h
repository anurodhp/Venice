/*
 * venice: the controls under the video, drawn by venice itself, white on
 * black, in the shape of the iOS player: icon buttons (play, pause, skip,
 * the two speakers) and thin tracks with a round knob (the scrubber and the
 * volume). They are vector paths, so they depend on no font having the
 * glyphs and on no theme art (the theme's slider and buttons are drawn for
 * a light window).
 *
 * Each redraws only when what it shows changes: the scrubber's value is set
 * on every position update, and on the Pi a needless redraw is CPU taken
 * from the decoder.
 */
#import <AppKit/AppKit.h>

typedef enum {
	VeniceIconPlay,
	VeniceIconPause,
	VeniceIconBack,         /* skip back */
	VeniceIconForward,      /* skip forward */
	VeniceIconSpeakerLow,   /* volume down: Naples' speaker, no waves */
	VeniceIconSpeakerHigh,  /* volume up: Naples' speaker, three waves */
	VeniceIconFullscreen,   /* four corners pointing out */
} VeniceIcon;

@interface VeniceIconButton : NSControl
{
	VeniceIcon icon;
	BOOL pressed, enabled, muted;
	id target;
	SEL action;
}
- (id) initWithFrame: (NSRect)frame icon: (VeniceIcon)i target: (id)t action: (SEL)a;
- (void) setIcon: (VeniceIcon)i;
/* the speaker icons draw Naples' muted speaker (a cross for the waves) */
- (void) setMuted: (BOOL)m;
@end

@interface VeniceTrack : NSControl
{
	double value, minValue, maxValue;
	BOOL dragging, enabled, showsKnob;
	CGFloat lastKnobX;
	id target;
	SEL action;
}
- (id) initWithFrame: (NSRect)frame target: (id)t action: (SEL)a;
- (void) setMinValue: (double)v;
- (void) setMaxValue: (double)v;
- (double) maxValue;
/* the action is sent on the press, on each drag and on the release */
- (BOOL) isDragging;
@end

/* The black strip under the video that the controls sit on; it draws the
 * elapsed and remaining times under the scrubber's ends. */
@interface VeniceBarView : NSView
{
	NSString *left, *right;
	NSRect leftRect, rightRect;
}
- (void) setLeftText: (NSString *)l rightText: (NSString *)r;
- (void) setLeftRect: (NSRect)l rightRect: (NSRect)r;
@end
