/*
 * venice: its own X connection, and the child window the video is drawn in.
 *
 * Same reasons as Rome's (RomeX.h): gnustep-back drops Expose events for X
 * windows it did not create, and NSOpenGLView's -flushBuffer puts the whole
 * GNUstep window. So venice opens one X connection of its own, makes the
 * video's child window inside the GNUstep window on it, and reads that
 * connection's events itself.
 *
 * Mouse and keyboard events are not selected on the child, so X delivers
 * them to the GNUstep window and AppKit handles input as usual.
 */
#ifndef VENICE_X_H
#define VENICE_X_H

#include <X11/Xlib.h>

Display *venice_x_display(void);

/* Called for Expose on a registered window. */
typedef void (*VeniceExposeFn)(void *owner);
void venice_x_register(Window w, VeniceExposeFn fn, void *owner);
void venice_x_unregister(Window w);

/* Handle every queued event. Call when the connection's fd is readable and
 * after anything that may have read events into Xlib's queue (XSync). */
void venice_x_pump(void);

double venice_now_ms(void);

#endif
