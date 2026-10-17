/*
 * venice: the OpenGL video surface (VeniceVideo.h).
 *
 * A GLX context on the child window, handed to mpv's OpenGL render API
 * (mpv's own GL renderer, which needs GL 2.1 / GLES 2.0: what Mesa's vc4
 * driver gives on the Pi's VideoCore IV). mpv draws each frame into the
 * default framebuffer and venice swaps. On the Pi the swap is
 * xlib_vc4_flush_frontbuffer (tools/userland_staging/mesa_xlib_vc4 in the
 * iokit repo): the frame is read back from the GPU and put on the window by
 * the CPU, so the GPU's share is the shading (colour conversion, scaling,
 * subtitles, the OSD) and the copy is the floor of a frame's cost.
 */
#include "VeniceVideo.h"
#include "VeniceX.h"

#include <GL/gl.h>
#include <GL/glx.h>
#include <mpv/render_gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	VeniceVideo base;
	Display *dpy;
	Window win;
	Colormap cmap;
	GLXContext ctx;
} GLV;

static void *
get_proc_address(void *ctx, const char *name)
{
	(void)ctx;
	return (void *)glXGetProcAddressARB((const GLubyte *)name);
}

static void
gl_resize(VeniceVideo *v, int w, int h)
{
	GLV *g = (GLV *)v;
	if (w < 1) w = 1;
	if (h < 1) h = 1;
	if (w == v->width && h == v->height)
		return;
	XResizeWindow(g->dpy, g->win, w, h);
	v->width = w;
	v->height = h;
	/* Mesa's xlib GLX picks the new size up with XGetGeometry when the
	 * buffer is next made current (xm_api.c, xmesa_check_buffer_size); the
	 * server must see the resize first. */
	XSync(g->dpy, False);
	glXMakeCurrent(g->dpy, None, NULL);
}

static void
gl_draw(VeniceVideo *v)
{
	GLV *g = (GLV *)v;
	double t0 = venice_now_ms();
	glXMakeCurrent(g->dpy, g->win, g->ctx);
	int flip = 1;
	mpv_opengl_fbo fbo = { .fbo = 0, .w = v->width, .h = v->height };
	mpv_render_param params[] = {
		{ MPV_RENDER_PARAM_OPENGL_FBO, &fbo },
		{ MPV_RENDER_PARAM_FLIP_Y, &flip },
		{ 0 }
	};
	mpv_render_context_render(v->rc, params);
	v->t_render += venice_now_ms() - t0;
	glXSwapBuffers(g->dpy, g->win);
	mpv_render_context_report_swap(v->rc);
	v->frames++;
	v->t_draw += venice_now_ms() - t0;
}

static void
gl_destroy(VeniceVideo *v)
{
	GLV *g = (GLV *)v;
	if (v->rc != NULL) {
		glXMakeCurrent(g->dpy, g->win, g->ctx);
		mpv_render_context_free(v->rc);
	}
	if (g->ctx != NULL) {
		glXMakeCurrent(g->dpy, None, NULL);
		glXDestroyContext(g->dpy, g->ctx);
	}
	if (g->win != 0) {
		venice_x_unregister(g->win);
		XDestroyWindow(g->dpy, g->win);
	}
	if (g->cmap != 0)
		XFreeColormap(g->dpy, g->cmap);
	XSync(g->dpy, False);
	free(g);
}

VeniceVideo *
venice_video_gl_new(mpv_handle *mpv, unsigned long parent, int x, int y, int w, int h)
{
	Display *dpy = venice_x_display();
	if (dpy == NULL)
		return NULL;
	int scr = DefaultScreen(dpy);
	int attrs[] = { GLX_RGBA, GLX_DOUBLEBUFFER, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, None };
	XVisualInfo *vi = glXChooseVisual(dpy, scr, attrs);
	if (vi == NULL) {
		fprintf(stderr, "venice: no double-buffered RGB GLX visual\n");
		return NULL;
	}
	GLV *g = calloc(1, sizeof(*g));
	if (g == NULL) {
		XFree(vi);
		return NULL;
	}
	VeniceVideo *v = &g->base;
	v->name = "gl";
	v->resize = gl_resize;
	v->draw = gl_draw;
	v->destroy = gl_destroy;
	v->width = w > 0 ? w : 1;
	v->height = h > 0 ? h : 1;
	g->dpy = dpy;
	XSetWindowAttributes wa;
	memset(&wa, 0, sizeof(wa));
	wa.background_pixel = BlackPixel(dpy, scr);
	wa.border_pixel = 0;
	g->cmap = wa.colormap = XCreateColormap(dpy, RootWindow(dpy, scr), vi->visual, AllocNone);
	wa.event_mask = ExposureMask;
	g->win = XCreateWindow(dpy, (Window)parent, x, y, v->width, v->height, 0, vi->depth, InputOutput,
	    vi->visual, CWBackPixel | CWBorderPixel | CWColormap | CWEventMask, &wa);
	v->win = g->win;
	XMapWindow(dpy, g->win);
	g->ctx = glXCreateContext(dpy, vi, NULL, True);
	XFree(vi);
	if (g->ctx == NULL || !glXMakeCurrent(dpy, g->win, g->ctx)) {
		fprintf(stderr, "venice: cannot create or bind a GLX context\n");
		gl_destroy(v);
		return NULL;
	}
	snprintf(v->info, sizeof(v->info), "OpenGL %s, %s", (const char *)glGetString(GL_VERSION),
	    (const char *)glGetString(GL_RENDERER));
	if (getenv("VENICE_STATS") != NULL)
		fprintf(stderr, "venice: GL_RENDERER %s, GL_VERSION %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION));

	mpv_opengl_init_params gl_init = { .get_proc_address = get_proc_address };
	mpv_render_param params[] = {
		{ MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL },
		{ MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init },
		{ MPV_RENDER_PARAM_X11_DISPLAY, dpy },
		{ 0 }
	};
	int err = mpv_render_context_create(&v->rc, mpv, params);
	if (err < 0) {
		fprintf(stderr, "venice: mpv's OpenGL renderer did not start: %s\n", mpv_error_string(err));
		v->rc = NULL;
		gl_destroy(v);
		return NULL;
	}
	return v;
}

void
venice_video_move(VeniceVideo *v, int x, int y)
{
	Display *dpy = venice_x_display();
	if (dpy != NULL && v->win != 0) {
		XMoveWindow(dpy, (Window)v->win, x, y);
		XFlush(dpy);
	}
}

void
venice_video_show(VeniceVideo *v, int show)
{
	Display *dpy = venice_x_display();
	if (dpy != NULL && v->win != 0) {
		if (show)
			XMapWindow(dpy, (Window)v->win);
		else
			XUnmapWindow(dpy, (Window)v->win);
		XFlush(dpy);
	}
}
