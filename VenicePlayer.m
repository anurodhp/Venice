/*
 * venice: the player (see VenicePlayer.h).
 */
#import <AppKit/AppKit.h>
#import "VenicePlayer.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

enum {
	P_TIME_POS = 1, P_DURATION, P_PAUSE, P_VOLUME, P_MUTE, P_IDLE, P_EOF, P_TITLE, P_DWIDTH, P_DHEIGHT,
	P_SEEKABLE, P_BUFFERING,
};

/* Both callbacks run on mpv's threads: they may only wake the main thread. */
static void
wakeup_cb(void *ctx)
{
	int fd = (int)(intptr_t)ctx;
	char c = 'e';
	(void)write(fd, &c, 1);         /* the pipe is non-blocking: when full, a wakeup is already pending */
}

static void
update_cb(void *ctx)
{
	int fd = (int)(intptr_t)ctx;
	char c = 'r';
	(void)write(fd, &c, 1);
}

static NSString *
default_string(NSString *key)
{
	return [[NSUserDefaults standardUserDefaults] stringForKey: key];
}

@interface VenicePlayer (Private) <RunLoopEvents>
@end

@implementation VenicePlayer

- (id) initWithDelegate: (id)d
{
	if ((self = [super init]) == nil)
		return nil;
	delegate = d;
	volume = 100;
	idle = YES;
	if (pipe(wakefd) != 0) {
		[self release];
		return nil;
	}
	for (int i = 0; i < 2; i++) {
		fcntl(wakefd[i], F_SETFL, fcntl(wakefd[i], F_GETFL) | O_NONBLOCK);
		fcntl(wakefd[i], F_SETFD, FD_CLOEXEC);
	}

	mpv = mpv_create();
	if (mpv == NULL) {
		NSLog(@"venice: mpv_create failed");
		[self release];
		return nil;
	}
	BOOL debug = getenv("VENICE_DEBUG") != NULL;
	/* frames go to the render API (VeniceVideo); nothing of mpv's own UI */
	mpv_set_option_string(mpv, "vo", "libmpv");
	mpv_set_option_string(mpv, "config", "no");
	mpv_set_option_string(mpv, "terminal", debug ? "yes" : "no");
	mpv_set_option_string(mpv, "msg-level", debug ? "all=v" : "all=warn");
	mpv_set_option_string(mpv, "input-default-bindings", "no");
	mpv_set_option_string(mpv, "input-vo-keyboard", "no");
	mpv_set_option_string(mpv, "osd-level", "1");
	mpv_set_option_string(mpv, "idle", "yes");
	mpv_set_option_string(mpv, "keep-open", "yes");
	mpv_set_option_string(mpv, "ytdl", "no");
	mpv_set_option_string(mpv, "volume-max", "100");
	/* The Pi's video decoder is on the VideoCore VPU: FFmpeg's h264_mmal
	 * reaches it through MMAL over VCHIQ (iokit's BCM2837VCHIQ driver), and
	 * mpv's mmal-copy hands the decoded frames back as ordinary YUV
	 * images, so both renderers take them as they take FFmpeg's. Only for
	 * the codecs the Pi 3 decodes without a purchased licence key (H.264
	 * and MPEG-4 Part 2; MPEG-2 and VC-1 need one). Where there is no VPU
	 * (QEMU), or the codec or the stream is one the VPU refuses, mpv falls
	 * back to FFmpeg's software decoder, with NEON on every core.
	 * VeniceHardwareDecoding NO: always software. */
	BOOL hw = [[NSUserDefaults standardUserDefaults] objectForKey: @"VeniceHardwareDecoding"] == nil ||
	    [[NSUserDefaults standardUserDefaults] boolForKey: @"VeniceHardwareDecoding"];
	mpv_set_option_string(mpv, "hwdec", hw ? "mmal-copy" : "no");
	mpv_set_option_string(mpv, "hwdec-codecs", "h264,mpeg4");
	mpv_set_option_string(mpv, "vd-lavc-threads", "0");
	/* Cheaper GL shaders (bilinear scaling, no dithering, no HDR peak
	 * detection) and the fastest swscale path for the sw renderer: the Pi 3's
	 * VC4 and Cortex-A53 have little to spare. */
	mpv_set_option_string(mpv, "profile", "fast");
	mpv_set_option_string(mpv, "sw-fast", "yes");
	/* 1 GB of RAM: keep the demuxer cache modest */
	mpv_set_option_string(mpv, "demuxer-max-bytes", "48MiB");
	mpv_set_option_string(mpv, "demuxer-max-back-bytes", "16MiB");
	/* VeniceMPVOptions "key=value,key=value": any other mpv option (e.g.
	 * vd-lavc-skiploopfilter=all to trade quality for speed) */
	NSString *extra = default_string(@"VeniceMPVOptions");
	if (extra != nil) {
		for (NSString *kv in [extra componentsSeparatedByString: @","]) {
			NSRange eq = [kv rangeOfString: @"="];
			if (eq.location == NSNotFound)
				continue;
			NSString *k = [kv substringToIndex: eq.location], *v = [kv substringFromIndex: NSMaxRange(eq)];
			int err = mpv_set_option_string(mpv, [k UTF8String], [v UTF8String]);
			if (err < 0)
				NSLog(@"venice: mpv option %@=%@: %s", k, v, mpv_error_string(err));
		}
	}
	int err = mpv_initialize(mpv);
	if (err < 0) {
		NSLog(@"venice: mpv_initialize: %s", mpv_error_string(err));
		mpv_terminate_destroy(mpv);
		mpv = NULL;
		[self release];
		return nil;
	}
	mpv_observe_property(mpv, P_TIME_POS, "time-pos", MPV_FORMAT_DOUBLE);
	mpv_observe_property(mpv, P_DURATION, "duration", MPV_FORMAT_DOUBLE);
	mpv_observe_property(mpv, P_PAUSE, "pause", MPV_FORMAT_FLAG);
	mpv_observe_property(mpv, P_VOLUME, "volume", MPV_FORMAT_DOUBLE);
	mpv_observe_property(mpv, P_MUTE, "mute", MPV_FORMAT_FLAG);
	mpv_observe_property(mpv, P_IDLE, "idle-active", MPV_FORMAT_FLAG);
	mpv_observe_property(mpv, P_EOF, "eof-reached", MPV_FORMAT_FLAG);
	mpv_observe_property(mpv, P_TITLE, "media-title", MPV_FORMAT_STRING);
	mpv_observe_property(mpv, P_DWIDTH, "dwidth", MPV_FORMAT_INT64);
	mpv_observe_property(mpv, P_DHEIGHT, "dheight", MPV_FORMAT_INT64);
	mpv_observe_property(mpv, P_SEEKABLE, "seekable", MPV_FORMAT_FLAG);
	mpv_observe_property(mpv, P_BUFFERING, "paused-for-cache", MPV_FORMAT_FLAG);

	NSRunLoop *rl = [NSRunLoop currentRunLoop];
	void *fd = (void *)(intptr_t)wakefd[0];
	[rl addEvent: fd type: ET_RDESC watcher: self forMode: NSDefaultRunLoopMode];
	[rl addEvent: fd type: ET_RDESC watcher: self forMode: NSEventTrackingRunLoopMode];
	[rl addEvent: fd type: ET_RDESC watcher: self forMode: NSModalPanelRunLoopMode];
	mpv_set_wakeup_callback(mpv, wakeup_cb, (void *)(intptr_t)wakefd[1]);
	return self;
}

- (void) dealloc
{
	[self shutdown];
	[title release];
	[path release];
	[super dealloc];
}

- (mpv_handle *) handle { return mpv; }

- (void) attachRenderContext: (mpv_render_context *)ctx
{
	if (rc != NULL)
		mpv_render_context_set_update_callback(rc, NULL, NULL);
	rc = ctx;
	if (rc != NULL)
		mpv_render_context_set_update_callback(rc, update_cb, (void *)(intptr_t)wakefd[1]);
}

/* ---- commands ---- */

- (void) command: (const char **)args
{
	if (mpv == NULL)
		return;
	int err = mpv_command_async(mpv, 0, args);
	if (err < 0)
		NSLog(@"venice: mpv %s: %s", args[0], mpv_error_string(err));
}

- (void) open: (NSString *)pathOrURL
{
	ASSIGN(path, pathOrURL);
	const char *args[] = { "loadfile", [pathOrURL UTF8String], "replace", NULL };
	[self command: args];
	[self setPaused: NO];
}

- (void) setPaused: (BOOL)p
{
	if (mpv == NULL)
		return;
	int flag = p;
	mpv_set_property_async(mpv, 0, "pause", MPV_FORMAT_FLAG, &flag);
}

- (void) togglePause
{
	/* at the end (keep-open), play starts over */
	if (eof && paused && duration > 0)
		[self seekTo: 0 exact: YES];
	const char *args[] = { "cycle", "pause", NULL };
	[self command: args];
}

- (void) changeVolumeBy: (double)delta
{
	char d[32];
	snprintf(d, sizeof(d), "%g", delta);
	const char *args[] = { "add", "volume", d, NULL };
	[self command: args];
	if (muted && delta > 0) {
		const char *unmute[] = { "set", "mute", "no", NULL };
		[self command: unmute];
	}
}

- (void) setVolume: (double)v
{
	if (mpv == NULL)
		return;
	v = v < 0 ? 0 : v > 100 ? 100 : v;
	mpv_set_property_async(mpv, 0, "volume", MPV_FORMAT_DOUBLE, &v);
	if (muted && v > 0) {
		int no = 0;
		mpv_set_property_async(mpv, 0, "mute", MPV_FORMAT_FLAG, &no);
	}
}

- (void) toggleMute
{
	const char *args[] = { "cycle", "mute", NULL };
	[self command: args];
}

- (void) seekTo: (double)seconds exact: (BOOL)exact
{
	char t[32];
	snprintf(t, sizeof(t), "%.3f", seconds < 0 ? 0 : seconds);
	const char *args[] = { "seek", t, exact ? "absolute+exact" : "absolute+keyframes", NULL };
	[self command: args];
}

- (void) seekBy: (double)seconds
{
	char t[32];
	snprintf(t, sizeof(t), "%.3f", seconds);
	const char *args[] = { "seek", t, "relative", NULL };
	[self command: args];
}

- (void) stop
{
	const char *args[] = { "stop", NULL };
	[self command: args];
}

- (void) shutdown
{
	if (mpv == NULL)
		return;
	NSRunLoop *rl = [NSRunLoop currentRunLoop];
	void *fd = (void *)(intptr_t)wakefd[0];
	[rl removeEvent: fd type: ET_RDESC forMode: NSDefaultRunLoopMode all: YES];
	[rl removeEvent: fd type: ET_RDESC forMode: NSEventTrackingRunLoopMode all: YES];
	[rl removeEvent: fd type: ET_RDESC forMode: NSModalPanelRunLoopMode all: YES];
	mpv_set_wakeup_callback(mpv, NULL, NULL);
	/* the render context must already be gone (mpv.h: mpv_render_context_free before mpv_terminate_destroy) */
	mpv_terminate_destroy(mpv);
	mpv = NULL;
	close(wakefd[0]);
	close(wakefd[1]);
}

/* ---- state ---- */

- (double) timePos { return timePos; }
- (double) duration { return duration; }
- (double) volume { return volume; }
- (BOOL) isPaused { return paused; }
- (BOOL) isMuted { return muted; }
- (BOOL) isIdle { return idle; }
- (BOOL) isSeekable { return seekable; }
- (BOOL) isBuffering { return buffering; }
- (BOOL) isAtEnd { return eof && !idle; }

- (NSString *) property: (const char *)name
{
	if (mpv == NULL)
		return nil;
	char *v = mpv_get_property_string(mpv, name);
	if (v == NULL)
		return nil;
	NSString *s = [NSString stringWithUTF8String: v];
	mpv_free(v);
	return s;
}

- (NSString *) playbackStats
{
	NSMutableString *out = [NSMutableString string];
	const char *props[] = { "video-codec", "hwdec-current", "width", "height", "container-fps", "frame-drop-count",
	    "decoder-frame-drop-count", "current-ao", "audio-codec-name", NULL };
	for (int i = 0; mpv != NULL && props[i] != NULL; i++) {
		char *v = mpv_get_property_string(mpv, props[i]);
		[out appendFormat: @"%s%s=%s", i ? " " : "", props[i], v ? v : "-"];
		mpv_free(v);
	}
	return out;
}
- (NSString *) title { return title; }
- (NSString *) path { return path; }

/* ---- events, on the main thread ---- */

- (void) handleProperty: (mpv_event_property *)p id: (uint64_t)pid
{
	BOOL sizeChanged = NO;
	void *d = p->data;
	switch (pid) {
	case P_TIME_POS: timePos = d ? *(double *)d : 0; break;
	case P_DURATION: duration = d ? *(double *)d : 0; break;
	case P_PAUSE: paused = d ? *(int *)d : NO; break;
	case P_VOLUME: volume = d ? *(double *)d : 0; break;
	case P_MUTE: muted = d ? *(int *)d : NO; break;
	case P_IDLE: idle = d ? *(int *)d : NO; break;
	case P_EOF: eof = d ? *(int *)d : NO; break;
	case P_SEEKABLE: seekable = d ? *(int *)d : NO; break;
	case P_BUFFERING: buffering = d ? *(int *)d : NO; break;
	case P_TITLE:
		ASSIGN(title, d ? [NSString stringWithUTF8String: *(char **)d] : nil);
		break;
	case P_DWIDTH:
	case P_DHEIGHT: {
		int64_t v = d ? *(int64_t *)d : 0;
		if (pid == P_DWIDTH) {
			sizeChanged = v != dwidth;
			dwidth = v;
		} else {
			sizeChanged = v != dheight;
			dheight = v;
		}
		break;
	}
	}
	if (sizeChanged && dwidth > 0 && dheight > 0)
		[delegate player: self videoSizeChanged: NSMakeSize(dwidth, dheight)];
}

- (void) drainEvents
{
	BOOL changed = NO;
	while (mpv != NULL) {
		mpv_event *ev = mpv_wait_event(mpv, 0);
		if (ev->event_id == MPV_EVENT_NONE)
			break;
		switch (ev->event_id) {
		case MPV_EVENT_PROPERTY_CHANGE:
			[self handleProperty: ev->data id: ev->reply_userdata];
			changed = YES;
			break;
		case MPV_EVENT_END_FILE: {
			mpv_event_end_file *e = ev->data;
			NSString *err = nil;
			if (e->reason == MPV_END_FILE_REASON_ERROR)
				err = [NSString stringWithUTF8String: mpv_error_string(e->error)];
			[delegate player: self endedWithError: err];
			break;
		}
		case MPV_EVENT_SHUTDOWN:
			return;
		default:
			break;
		}
	}
	if (changed)
		[delegate playerStateChanged: self];
}

- (void) receivedEvent: (void *)data type: (RunLoopEventType)type extra: (void *)extra forMode: (NSString *)mode
{
	char buf[64];
	BOOL events = NO, frame = NO;
	ssize_t n;
	while ((n = read(wakefd[0], buf, sizeof(buf))) > 0) {
		for (ssize_t i = 0; i < n; i++) {
			if (buf[i] == 'e')
				events = YES;
			else if (buf[i] == 'r')
				frame = YES;
		}
	}
	if (events)
		[self drainEvents];
	if (frame && rc != NULL && (mpv_render_context_update(rc) & MPV_RENDER_UPDATE_FRAME))
		[delegate playerWantsFrame: self];
}

@end
