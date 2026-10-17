/*
 * venice: the video surface. A child X window of the GNUstep window, on
 * venice's own X connection (VeniceX.h), that an mpv_render_context draws
 * frames into.
 *
 * Two implementations:
 *   gl  mpv's OpenGL renderer in a GLX context on the child window: decoded
 *       frames are uploaded as textures, and YUV->RGB, scaling and subtitles
 *       run as shaders. On the Pi that is Mesa's vc4 driver on the VideoCore
 *       IV (GL 2.1); elsewhere Mesa's softpipe. The default.
 *   sw  mpv's software renderer (libswscale, NEON) into a 32-bit image of
 *       the window, put with MIT-SHM (XShmPutImage) or XPutImage. The
 *       fallback when GL cannot start, or by choice (-VeniceRenderer sw).
 *
 * Decoding is the same for both: FFmpeg in software, on all four cores.
 */
#ifndef VENICE_VIDEO_H
#define VENICE_VIDEO_H

#include <mpv/client.h>
#include <mpv/render.h>

typedef struct VeniceVideo VeniceVideo;
struct VeniceVideo {
	const char *name;
	char info[128];             /* what it draws with, for Video Info (the GL renderer string) */
	unsigned long win;          /* the child X window */
	int width, height;          /* its size in pixels */
	mpv_render_context *rc;

	/* Resize the window (and the sw image). */
	void (*resize)(VeniceVideo *v, int width, int height);
	/* Draw mpv's current frame and put it on the window. */
	void (*draw)(VeniceVideo *v);
	/* Free the render context first (mpv_render_context_free needs the GL
	 * context current), then the window. */
	void (*destroy)(VeniceVideo *v);

	/* VENICE_STATS: frames drawn and the time spent drawing them */
	unsigned long frames;
	double t_draw;
};

/* `parent` is the X window of the GNUstep window; x, y is the view's origin
 * in it. Each returns NULL when it cannot run (no GLX visual, no context,
 * mpv refused the render API). */
VeniceVideo *venice_video_gl_new(mpv_handle *mpv, unsigned long parent, int x, int y, int w, int h);
VeniceVideo *venice_video_sw_new(mpv_handle *mpv, unsigned long parent, int x, int y, int w, int h);

void venice_video_move(VeniceVideo *v, int x, int y);
void venice_video_show(VeniceVideo *v, int show);

#endif
