/*
 * venice: the player. Owns the mpv_handle, sets it up for playback through
 * the render API, observes the properties the window shows (position,
 * duration, pause, volume, title, video size) and turns mpv's callbacks,
 * which arrive on mpv's threads, into calls on the main thread.
 *
 * mpv's wakeup and render-update callbacks write a byte to a pipe that the
 * main run loop watches (ET_RDESC); the bytes are drained there and the
 * events handled. (GNUstep's run loop is not woken by work queued on the
 * main dispatch queue: Milan's notes.)
 */
#import <Foundation/Foundation.h>
#include <mpv/client.h>
#include <mpv/render.h>

@class VenicePlayer;

@protocol VenicePlayerDelegate
/* Any observed property changed; read the new values from the player. */
- (void) playerStateChanged: (VenicePlayer *)p;
/* The video's display size became known or changed (a new file). */
- (void) player: (VenicePlayer *)p videoSizeChanged: (NSSize)size;
/* mpv has a new frame (or wants a redraw). */
- (void) playerWantsFrame: (VenicePlayer *)p;
/* A file ended; `error` is nil for a normal end. */
- (void) player: (VenicePlayer *)p endedWithError: (NSString *)error;
@end

@interface VenicePlayer : NSObject
{
	mpv_handle *mpv;
	mpv_render_context *rc;
	int wakefd[2];
	id delegate;
	double timePos, duration, volume;
	BOOL paused, muted, idle, seekable, buffering, eof;
	BOOL hardware;          /* the VPU may decode (VeniceHardwareDecoding) */
	BOOL overlay;           /* mpv decodes with hwdec=mmal: the video is a display layer */
	int overlayWanted;      /* what setOverlay last asked hwdec for: -1 nothing yet */
	NSString *title, *path;
	int64_t dwidth, dheight;
}
- (id) initWithDelegate: (id)d;
- (mpv_handle *) handle;
/* The render context the video surface made; its update callback is
 * routed through the pipe. Pass NULL before freeing it. */
- (void) attachRenderContext: (mpv_render_context *)ctx;
- (void) open: (NSString *)pathOrURL;
- (void) togglePause;
- (void) setPaused: (BOOL)p;
- (void) changeVolumeBy: (double)delta;
- (void) setVolume: (double)v;
- (void) toggleMute;
- (void) seekTo: (double)seconds exact: (BOOL)exact;
- (void) seekBy: (double)seconds;
- (void) stop;
- (void) shutdown;

- (double) timePos;
- (double) duration;
- (double) volume;
- (BOOL) isPaused;
/* Full screen on the Pi: the VPU's frames go straight to a VideoCore
 * display layer at screen position x, y (mpv's rpi-overlay, hwdec=mmal);
 * NO goes back to frames drawn through GL (mmal-copy). */
- (void) setOverlay: (BOOL)on x: (int)x y: (int)y;
/* mpv is showing the video as that layer (hwdec-current is mmal) */
- (BOOL) isOverlay;
- (BOOL) isMuted;
- (BOOL) isIdle;
- (BOOL) isSeekable;
- (BOOL) isBuffering;
/* played to the end of the file (keep-open holds the last frame, paused) */
- (BOOL) isAtEnd;
/* mpv's string value of a property, or nil */
- (NSString *) property: (const char *)name;
/* codec, size and dropped-frame counters, one line (VeniceQuitAtEnd logs it) */
- (NSString *) playbackStats;
- (NSString *) title;
- (NSString *) path;
@end
