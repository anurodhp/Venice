/*
 * venice: the software video surface (VeniceVideo.h).
 *
 * mpv's software renderer (MPV_RENDER_API_TYPE_SW: libswscale with its NEON
 * code, colour conversion and scaling on the CPU) draws each frame into a
 * client-side 32-bit image of the window, which is put with XShmPutImage
 * when MIT-SHM works and XPutImage otherwise. The MIT-SHM sequence is
 * Rome's (RomeRenderX11.c): IPC_RMID only after the server has attached,
 * because xnu refuses to find a segment already marked for removal.
 *
 * The image is allocated 16 pixels wider than needed at most, so that each
 * row starts on a 64-byte boundary: mpv's SIMD paths want the pointer and
 * stride aligned to 64 (render.h, MPV_RENDER_PARAM_SW_STRIDE) and copy the
 * whole frame otherwise.
 */
#include "VeniceVideo.h"
#include "VeniceX.h"

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
	VeniceVideo base;
	Display *dpy;
	Window win;
	GC gc;
	Visual *visual;
	int depth;
	XImage *img;
	XShmSegmentInfo shm;
	int use_shm;            /* -1 unknown, 0 no, 1 yes */
	const char *format;     /* mpv's name for the visual's pixel layout */
} SWV;

static int g_shm_error;
static int
shm_error_handler(Display *d, XErrorEvent *e)
{
	(void)d;
	(void)e;
	g_shm_error = 1;
	return 0;
}

static void
image_free(SWV *s)
{
	if (s->img == NULL)
		return;
	if (s->shm.shmaddr != NULL) {
		XShmDetach(s->dpy, &s->shm);
		XSync(s->dpy, False);
		s->img->data = NULL;
		XDestroyImage(s->img);
		shmdt(s->shm.shmaddr);
		memset(&s->shm, 0, sizeof(s->shm));
	} else {
		free(s->img->data);
		s->img->data = NULL;
		XDestroyImage(s->img);
	}
	s->img = NULL;
}

static XImage *
image_shm(SWV *s, int w, int h)
{
	if (s->use_shm < 0)
		s->use_shm = getenv("VENICE_NOSHM") == NULL && XShmQueryExtension(s->dpy);
	if (!s->use_shm)
		return NULL;
	XImage *img = XShmCreateImage(s->dpy, s->visual, s->depth, ZPixmap, NULL, &s->shm, w, h);
	if (img == NULL)
		return NULL;
	s->shm.shmid = shmget(IPC_PRIVATE, (size_t)img->bytes_per_line * h, IPC_CREAT | 0600);
	if (s->shm.shmid < 0) {
		/* over shmmax (xnu default 4 MiB): this size uses XPutImage */
		XDestroyImage(img);
		memset(&s->shm, 0, sizeof(s->shm));
		return NULL;
	}
	s->shm.shmaddr = img->data = shmat(s->shm.shmid, NULL, 0);
	if (s->shm.shmaddr == (char *)-1) {
		shmctl(s->shm.shmid, IPC_RMID, NULL);
		img->data = NULL;
		XDestroyImage(img);
		memset(&s->shm, 0, sizeof(s->shm));
		return NULL;
	}
	s->shm.readOnly = True;
	g_shm_error = 0;
	XSync(s->dpy, False);
	XErrorHandler old = XSetErrorHandler(shm_error_handler);
	XShmAttach(s->dpy, &s->shm);
	XSync(s->dpy, False);
	XSetErrorHandler(old);
	shmctl(s->shm.shmid, IPC_RMID, NULL);
	if (g_shm_error) {
		img->data = NULL;
		XDestroyImage(img);
		shmdt(s->shm.shmaddr);
		memset(&s->shm, 0, sizeof(s->shm));
		s->use_shm = 0;
		return NULL;
	}
	return img;
}

static void
sw_resize(VeniceVideo *v, int w, int h)
{
	SWV *s = (SWV *)v;
	if (w < 1) w = 1;
	if (h < 1) h = 1;
	if (s->img != NULL && w == v->width && h == v->height)
		return;
	image_free(s);
	XResizeWindow(s->dpy, s->win, w, h);
	v->width = w;
	v->height = h;
	int aw = (w + 15) & ~15;
	XImage *img = image_shm(s, aw, h);
	if (img == NULL) {
		img = XCreateImage(s->dpy, s->visual, s->depth, ZPixmap, 0, NULL, aw, h, 32, 0);
		if (img == NULL)
			return;
		if (posix_memalign((void **)&img->data, 64, (size_t)img->bytes_per_line * h) != 0) {
			img->data = NULL;
			XDestroyImage(img);
			return;
		}
	}
	if (img->bits_per_pixel != 32) {
		fprintf(stderr, "venice: the sw renderer needs a 32 bpp visual (got %d)\n", img->bits_per_pixel);
		s->img = img;
		image_free(s);
		return;
	}
	memset(img->data, 0, (size_t)img->bytes_per_line * h);
	s->img = img;
}

static void
sw_draw(VeniceVideo *v)
{
	SWV *s = (SWV *)v;
	if (s->img == NULL)
		return;
	double t0 = venice_now_ms();
	int size[2] = { v->width, v->height };
	size_t stride = (size_t)s->img->bytes_per_line;
	mpv_render_param params[] = {
		{ MPV_RENDER_PARAM_SW_SIZE, size },
		{ MPV_RENDER_PARAM_SW_FORMAT, (void *)s->format },
		{ MPV_RENDER_PARAM_SW_STRIDE, &stride },
		{ MPV_RENDER_PARAM_SW_POINTER, s->img->data },
		{ 0 }
	};
	if (mpv_render_context_render(v->rc, params) >= 0) {
		if (s->shm.shmaddr != NULL)
			XShmPutImage(s->dpy, s->win, s->gc, s->img, 0, 0, 0, 0, v->width, v->height, False);
		else
			XPutImage(s->dpy, s->win, s->gc, s->img, 0, 0, 0, 0, v->width, v->height);
		/* the image is reused for the next frame: the server must be done with it */
		XSync(s->dpy, False);
	}
	mpv_render_context_report_swap(v->rc);
	v->frames++;
	v->t_draw += venice_now_ms() - t0;
}

static void
sw_destroy(VeniceVideo *v)
{
	SWV *s = (SWV *)v;
	if (v->rc != NULL)
		mpv_render_context_free(v->rc);
	image_free(s);
	if (s->gc != NULL)
		XFreeGC(s->dpy, s->gc);
	if (s->win != 0) {
		venice_x_unregister(s->win);
		XDestroyWindow(s->dpy, s->win);
	}
	XSync(s->dpy, False);
	free(s);
}

/* mpv's byte-order name for the visual's 32-bit pixels, or NULL */
static const char *
format_for(Visual *vis, int byte_order)
{
	unsigned long r = vis->red_mask, g = vis->green_mask, b = vis->blue_mask;
	int lsb = byte_order == LSBFirst;
	if (r == 0xff0000 && g == 0xff00 && b == 0xff)
		return lsb ? "bgr0" : "0rgb";
	if (r == 0xff && g == 0xff00 && b == 0xff0000)
		return lsb ? "rgb0" : "0bgr";
	return NULL;
}

VeniceVideo *
venice_video_sw_new(mpv_handle *mpv, unsigned long parent, int x, int y, int w, int h)
{
	Display *dpy = venice_x_display();
	if (dpy == NULL)
		return NULL;
	int scr = DefaultScreen(dpy);
	Visual *vis = DefaultVisual(dpy, scr);
	const char *fmt = format_for(vis, ImageByteOrder(dpy));
	if (fmt == NULL || DefaultDepth(dpy, scr) < 24) {
		fprintf(stderr, "venice: the sw renderer needs a 24-bit TrueColor visual\n");
		return NULL;
	}
	SWV *s = calloc(1, sizeof(*s));
	if (s == NULL)
		return NULL;
	VeniceVideo *v = &s->base;
	v->name = "sw";
	v->resize = sw_resize;
	v->draw = sw_draw;
	v->destroy = sw_destroy;
	s->dpy = dpy;
	s->visual = vis;
	s->depth = DefaultDepth(dpy, scr);
	s->format = fmt;
	s->use_shm = -1;
	/* The image is in the default visual, so the window must be too: the
	 * GNUstep window it sits in may use another (a 32-bit ARGB one), and a
	 * CopyFromParent child would inherit it and refuse every XShmPutImage
	 * with BadMatch. A visual other than the parent's needs its own
	 * colormap and border pixel. */
	XSetWindowAttributes wa;
	memset(&wa, 0, sizeof(wa));
	wa.background_pixel = BlackPixel(dpy, scr);
	wa.border_pixel = 0;
	wa.colormap = DefaultColormap(dpy, scr);
	wa.event_mask = ExposureMask;
	s->win = XCreateWindow(dpy, (Window)parent, x, y, w > 0 ? w : 1, h > 0 ? h : 1, 0, s->depth,
	    InputOutput, vis, CWBackPixel | CWBorderPixel | CWColormap | CWEventMask, &wa);
	v->win = s->win;
	s->gc = XCreateGC(dpy, s->win, 0, NULL);
	XMapWindow(dpy, s->win);
	sw_resize(v, w, h);

	mpv_render_param params[] = {
		{ MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW },
		{ 0 }
	};
	int err = mpv_render_context_create(&v->rc, mpv, params);
	if (err < 0) {
		fprintf(stderr, "venice: mpv's software renderer did not start: %s\n", mpv_error_string(err));
		v->rc = NULL;
		sw_destroy(v);
		return NULL;
	}
	return v;
}
