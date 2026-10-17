/*
 * venice: its own X connection (see VeniceX.h).
 */
#include "VeniceX.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static Display *g_dpy;

typedef struct {
	Window win;
	VeniceExposeFn fn;
	void *owner;
} Reg;
static Reg *g_regs;
static int g_nregs, g_capregs;

double
venice_now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

Display *
venice_x_display(void)
{
	if (g_dpy == NULL) {
		g_dpy = XOpenDisplay(NULL);
		if (g_dpy == NULL)
			fprintf(stderr, "venice: cannot open the X display\n");
	}
	return g_dpy;
}

void
venice_x_register(Window w, VeniceExposeFn fn, void *owner)
{
	if (g_nregs == g_capregs) {
		g_capregs = g_capregs ? 2 * g_capregs : 4;
		g_regs = realloc(g_regs, g_capregs * sizeof(*g_regs));
	}
	g_regs[g_nregs++] = (Reg){ w, fn, owner };
}

void
venice_x_unregister(Window w)
{
	for (int i = 0; i < g_nregs; i++) {
		if (g_regs[i].win == w) {
			g_regs[i] = g_regs[--g_nregs];
			return;
		}
	}
}

void
venice_x_set_fullscreen(unsigned long win, int on)
{
	Display *dpy = venice_x_display();
	if (dpy == NULL || win == 0)
		return;
	XEvent e;
	memset(&e, 0, sizeof(e));
	e.xclient.type = ClientMessage;
	e.xclient.window = (Window)win;
	e.xclient.message_type = XInternAtom(dpy, "_NET_WM_STATE", False);
	e.xclient.format = 32;
	e.xclient.data.l[0] = on ? 1 : 0;              /* _NET_WM_STATE_ADD / _REMOVE */
	e.xclient.data.l[1] = (long)XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
	e.xclient.data.l[2] = 0;
	e.xclient.data.l[3] = 1;                       /* source: a normal application */
	XSendEvent(dpy, DefaultRootWindow(dpy), False, SubstructureRedirectMask | SubstructureNotifyMask, &e);
	XFlush(dpy);
}

void
venice_x_pump(void)
{
	if (g_dpy == NULL)
		return;
	while (XPending(g_dpy) > 0) {
		XEvent ev;
		XNextEvent(g_dpy, &ev);
		/* one redraw covers any number of exposed rectangles */
		if (ev.type != Expose || ev.xexpose.count != 0)
			continue;
		for (int i = 0; i < g_nregs; i++) {
			if (g_regs[i].win == ev.xexpose.window) {
				g_regs[i].fn(g_regs[i].owner);
				break;
			}
		}
	}
}
