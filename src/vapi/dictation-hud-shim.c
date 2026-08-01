/*
 * dictation-hud-shim.c
 *
 * Always-on-top, non-focus-stealing dictation OSD via an override-redirect
 * X11 window (native X11 or XWayland). Drawn with Cairo + Pango; click-
 * through via an empty ShapeInput region. Never calls XSetInputFocus.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "dictation-hud-shim.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/shape.h>

#include <cairo-xlib.h>
#include <cairo.h>
#include <pango/pangocairo.h>

#include <glib.h>
#include <string.h>

#define HUD_MAX_WIDTH_FRAC   0.60
#define HUD_BOTTOM_MARGIN    48
#define HUD_PAD_X            20.0
#define HUD_PAD_Y            14.0
#define HUD_DOT_RADIUS       6.0
#define HUD_DOT_GAP          12.0
#define HUD_CORNER_RADIUS    12.0
#define HUD_MAX_LINES        3
#define HUD_FONT             "Sans 12"

struct KakiDictationHudNative {
    Display *dpy;
    int screen;
    Window root;
    Window win;
    Visual *visual;
    Colormap colormap;
    int depth;
    int screen_w;
    int screen_h;
    int win_w;
    int win_h;
    char *text;
    int mapped;
    int created;
};

static void
ensure_window (KakiDictationHudNative *hud)
{
    XSetWindowAttributes attrs;
    XVisualInfo vinfo;
    unsigned long valuemask;
    Atom net_wm_state;
    Atom net_wm_window_type;
    Atom atoms[4];
    int natoms = 0;

    if (hud->created)
        return;

    if (XMatchVisualInfo (hud->dpy, hud->screen, 32, TrueColor, &vinfo)) {
        hud->visual = vinfo.visual;
        hud->depth = vinfo.depth;
        hud->colormap = XCreateColormap (hud->dpy, hud->root,
                                         hud->visual, AllocNone);
    } else {
        hud->visual = DefaultVisual (hud->dpy, hud->screen);
        hud->depth = DefaultDepth (hud->dpy, hud->screen);
        hud->colormap = DefaultColormap (hud->dpy, hud->screen);
    }

    memset (&attrs, 0, sizeof (attrs));
    attrs.override_redirect = True;
    attrs.background_pixel = 0;
    attrs.border_pixel = 0;
    attrs.colormap = hud->colormap;
    attrs.event_mask = ExposureMask | StructureNotifyMask;
    valuemask = CWOverrideRedirect | CWBackPixel | CWBorderPixel
                | CWColormap | CWEventMask;

    hud->win_w = 320;
    hud->win_h = 48;
    hud->win = XCreateWindow (hud->dpy, hud->root,
                              (hud->screen_w - hud->win_w) / 2,
                              hud->screen_h - hud->win_h - HUD_BOTTOM_MARGIN,
                              (unsigned) hud->win_w, (unsigned) hud->win_h,
                              0, hud->depth, InputOutput, hud->visual,
                              valuemask, &attrs);

    /* Click-through: empty input shape so pointer events pass through. */
    XShapeCombineRectangles (hud->dpy, hud->win, ShapeInput,
                             0, 0, NULL, 0, ShapeSet, Unsorted);

    net_wm_state = XInternAtom (hud->dpy, "_NET_WM_STATE", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_ABOVE", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_SKIP_PAGER", False);
    XChangeProperty (hud->dpy, hud->win, net_wm_state, XA_ATOM, 32,
                     PropModeReplace, (unsigned char *) atoms, natoms);

    net_wm_window_type = XInternAtom (hud->dpy, "_NET_WM_WINDOW_TYPE", False);
    atoms[0] = XInternAtom (hud->dpy, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False);
    XChangeProperty (hud->dpy, hud->win, net_wm_window_type, XA_ATOM, 32,
                     PropModeReplace, (unsigned char *) atoms, 1);

    XStoreName (hud->dpy, hud->win, "Kaki Dictation");
    hud->created = 1;
}

static void
rounded_rect (cairo_t *cr, double x, double y, double w, double h, double r)
{
    double degrees = G_PI / 180.0;

    cairo_new_sub_path (cr);
    cairo_arc (cr, x + w - r, y + r, r, -90 * degrees, 0 * degrees);
    cairo_arc (cr, x + w - r, y + h - r, r, 0 * degrees, 90 * degrees);
    cairo_arc (cr, x + r, y + h - r, r, 90 * degrees, 180 * degrees);
    cairo_arc (cr, x + r, y + r, r, 180 * degrees, 270 * degrees);
    cairo_close_path (cr);
}

static void
measure_and_layout (cairo_t *cr,
                    const char *text,
                    int max_text_w,
                    PangoLayout **layout_out,
                    int *text_w,
                    int *text_h)
{
    PangoLayout *layout = pango_cairo_create_layout (cr);
    PangoFontDescription *desc = pango_font_description_from_string (HUD_FONT);

    pango_layout_set_font_description (layout, desc);
    pango_font_description_free (desc);

    pango_layout_set_text (layout, text != NULL ? text : "", -1);
    pango_layout_set_width (layout, max_text_w * PANGO_SCALE);
    pango_layout_set_wrap (layout, PANGO_WRAP_WORD_CHAR);
    /* Ellipsize from the start so the live tail stays visible. */
    pango_layout_set_ellipsize (layout, PANGO_ELLIPSIZE_START);
    /* Negative height = max lines (Pango convention). */
    pango_layout_set_height (layout, -HUD_MAX_LINES);

    pango_layout_get_pixel_size (layout, text_w, text_h);
    *layout_out = layout;
}

static void
redraw (KakiDictationHudNative *hud)
{
    cairo_surface_t *surface;
    cairo_t *cr;
    PangoLayout *layout = NULL;
    int max_w;
    int max_text_w;
    int text_w = 0;
    int text_h = 0;
    int content_w;
    int content_h;
    int new_w;
    int new_h;
    int x;
    int y;
    double text_x;
    double text_y;
    double dot_cx;
    double dot_cy;

    if (!hud->created || !hud->mapped)
        return;

    max_w = (int) (hud->screen_w * HUD_MAX_WIDTH_FRAC);
    if (max_w < 200)
        max_w = 200;

    /* Temporary surface for measuring with the real visual. */
    surface = cairo_xlib_surface_create (hud->dpy, hud->win, hud->visual,
                                         max_w, 200);
    cr = cairo_create (surface);

    max_text_w = max_w - (int) (HUD_PAD_X * 2 + HUD_DOT_RADIUS * 2 + HUD_DOT_GAP);
    if (max_text_w < 80)
        max_text_w = 80;

    measure_and_layout (cr, hud->text, max_text_w, &layout, &text_w, &text_h);

    content_w = (int) (HUD_DOT_RADIUS * 2 + HUD_DOT_GAP) + text_w;
    content_h = text_h > (int) (HUD_DOT_RADIUS * 2)
                ? text_h
                : (int) (HUD_DOT_RADIUS * 2);
    new_w = content_w + (int) (HUD_PAD_X * 2);
    new_h = content_h + (int) (HUD_PAD_Y * 2);
    if (new_w > max_w)
        new_w = max_w;
    if (new_w < 120)
        new_w = 120;
    if (new_h < 40)
        new_h = 40;

    g_object_unref (layout);
    cairo_destroy (cr);
    cairo_surface_destroy (surface);

    if (new_w != hud->win_w || new_h != hud->win_h) {
        hud->win_w = new_w;
        hud->win_h = new_h;
        x = (hud->screen_w - hud->win_w) / 2;
        y = hud->screen_h - hud->win_h - HUD_BOTTOM_MARGIN;
        XMoveResizeWindow (hud->dpy, hud->win, x, y,
                           (unsigned) hud->win_w, (unsigned) hud->win_h);
        /* Re-apply empty input shape after resize. */
        XShapeCombineRectangles (hud->dpy, hud->win, ShapeInput,
                                 0, 0, NULL, 0, ShapeSet, Unsorted);
    }

    surface = cairo_xlib_surface_create (hud->dpy, hud->win, hud->visual,
                                         hud->win_w, hud->win_h);
    cairo_xlib_surface_set_size (surface, hud->win_w, hud->win_h);
    cr = cairo_create (surface);

    cairo_set_operator (cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba (cr, 0, 0, 0, 0);
    cairo_paint (cr);

    cairo_set_operator (cr, CAIRO_OPERATOR_OVER);
    rounded_rect (cr, 0.5, 0.5,
                  hud->win_w - 1.0, hud->win_h - 1.0, HUD_CORNER_RADIUS);
    cairo_set_source_rgba (cr, 0.08, 0.08, 0.10, 0.82);
    cairo_fill_preserve (cr);
    cairo_set_source_rgba (cr, 1.0, 1.0, 1.0, 0.12);
    cairo_set_line_width (cr, 1.0);
    cairo_stroke (cr);

    max_text_w = hud->win_w - (int) (HUD_PAD_X * 2 + HUD_DOT_RADIUS * 2 + HUD_DOT_GAP);
    if (max_text_w < 80)
        max_text_w = 80;
    measure_and_layout (cr, hud->text, max_text_w, &layout, &text_w, &text_h);

    dot_cx = HUD_PAD_X + HUD_DOT_RADIUS;
    dot_cy = hud->win_h / 2.0;
    cairo_arc (cr, dot_cx, dot_cy, HUD_DOT_RADIUS, 0, 2 * G_PI);
    cairo_set_source_rgba (cr, 0.90, 0.18, 0.18, 1.0);
    cairo_fill (cr);

    text_x = HUD_PAD_X + HUD_DOT_RADIUS * 2 + HUD_DOT_GAP;
    text_y = (hud->win_h - text_h) / 2.0;
    cairo_move_to (cr, text_x, text_y);
    cairo_set_source_rgba (cr, 0.95, 0.95, 0.97, 1.0);
    pango_cairo_show_layout (cr, layout);

    g_object_unref (layout);
    cairo_destroy (cr);
    cairo_surface_destroy (surface);
    XFlush (hud->dpy);
}

KakiDictationHudNative *
kaki_dictation_hud_native_new (void)
{
    KakiDictationHudNative *hud;
    Display *dpy;

    dpy = XOpenDisplay (NULL);
    if (dpy == NULL)
        return NULL;

    hud = g_new0 (KakiDictationHudNative, 1);
    hud->dpy = dpy;
    hud->screen = DefaultScreen (dpy);
    hud->root = RootWindow (dpy, hud->screen);
    hud->screen_w = DisplayWidth (dpy, hud->screen);
    hud->screen_h = DisplayHeight (dpy, hud->screen);
    hud->text = g_strdup ("");
    return hud;
}

void
kaki_dictation_hud_native_free (KakiDictationHudNative *hud)
{
    if (hud == NULL)
        return;

    if (hud->created) {
        XDestroyWindow (hud->dpy, hud->win);
        if (hud->depth == 32 && hud->colormap != None)
            XFreeColormap (hud->dpy, hud->colormap);
    }
    if (hud->dpy != NULL)
        XCloseDisplay (hud->dpy);
    g_free (hud->text);
    g_free (hud);
}

void
kaki_dictation_hud_native_show (KakiDictationHudNative *hud)
{
    int x;
    int y;

    if (hud == NULL)
        return;

    ensure_window (hud);
    x = (hud->screen_w - hud->win_w) / 2;
    y = hud->screen_h - hud->win_h - HUD_BOTTOM_MARGIN;
    XMoveResizeWindow (hud->dpy, hud->win, x, y,
                       (unsigned) hud->win_w, (unsigned) hud->win_h);
    XMapRaised (hud->dpy, hud->win);
    hud->mapped = 1;
    redraw (hud);
}

void
kaki_dictation_hud_native_hide (KakiDictationHudNative *hud)
{
    if (hud == NULL || !hud->created)
        return;

    if (hud->mapped) {
        XUnmapWindow (hud->dpy, hud->win);
        hud->mapped = 0;
        XFlush (hud->dpy);
    }
    g_free (hud->text);
    hud->text = g_strdup ("");
}

void
kaki_dictation_hud_native_set_text (KakiDictationHudNative *hud,
                                    const char *text)
{
    if (hud == NULL)
        return;

    g_free (hud->text);
    hud->text = g_strdup (text != NULL ? text : "");
    if (hud->mapped)
        redraw (hud);
}