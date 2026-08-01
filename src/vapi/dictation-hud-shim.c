/*
 * dictation-hud-shim.c
 *
 * Always-on-top, non-focus-stealing dictation OSD via override-redirect
 * X11 windows (native X11 or XWayland). Drawn with Cairo + Pango; click-
 * through via an empty ShapeInput region. Never calls XSetInputFocus.
 *
 * One OSD is mirrored onto every active XRandR CRTC. On GNOME Wayland,
 * XQueryPointer stays frozen while the cursor is over Wayland-native
 * surfaces, so "follow the pointer" cannot work from an X11 client;
 * mirroring keeps the HUD visible on whichever head the user is using.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "dictation-hud-shim.h"

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/Xrandr.h>
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
#define HUD_MAX_MONITORS     8

typedef struct {
    Window win;
    int mon_x;
    int mon_y;
    int mon_w;
    int mon_h;
    int win_w;
    int win_h;
    int created;
    int mapped;
} HudSurface;

struct OwletDictationHudNative {
    Display *dpy;
    int screen;
    Window root;
    Visual *visual;
    Colormap colormap;
    int depth;
    int visual_ready;
    HudSurface surfaces[HUD_MAX_MONITORS];
    int n_surfaces;
    char *text;
    int mapped;
};

static void
hud_position (const HudSurface *surf, int *x_out, int *y_out)
{
    *x_out = surf->mon_x + (surf->mon_w - surf->win_w) / 2;
    *y_out = surf->mon_y + surf->mon_h - surf->win_h - HUD_BOTTOM_MARGIN;
}

static int
monitor_already_listed (const OwletDictationHudNative *hud,
                        int n,
                        int x,
                        int y,
                        int w,
                        int h)
{
    int i;

    for (i = 0; i < n; i++) {
        if (hud->surfaces[i].mon_x == x
            && hud->surfaces[i].mon_y == y
            && hud->surfaces[i].mon_w == w
            && hud->surfaces[i].mon_h == h)
            return 1;
    }
    return 0;
}

/* Collect active CRTC boxes. Falls back to the virtual screen when RandR
 * is unavailable or reports nothing usable. */
static void
query_monitors (OwletDictationHudNative *hud)
{
    int event_base = 0;
    int error_base = 0;
    XRRScreenResources *res = NULL;
    int n = 0;
    int i;

    if (!XRRQueryExtension (hud->dpy, &event_base, &error_base))
        goto fallback;

    res = XRRGetScreenResourcesCurrent (hud->dpy, hud->root);
    if (res == NULL)
        goto fallback;

    for (i = 0; i < res->ncrtc && n < HUD_MAX_MONITORS; i++) {
        XRRCrtcInfo *cinfo = XRRGetCrtcInfo (hud->dpy, res, res->crtcs[i]);
        int x;
        int y;
        int w;
        int h;

        if (cinfo == NULL)
            continue;
        if (cinfo->mode == None || cinfo->noutput == 0
            || cinfo->width == 0 || cinfo->height == 0) {
            XRRFreeCrtcInfo (cinfo);
            continue;
        }

        x = cinfo->x;
        y = cinfo->y;
        w = (int) cinfo->width;
        h = (int) cinfo->height;
        XRRFreeCrtcInfo (cinfo);

        if (monitor_already_listed (hud, n, x, y, w, h))
            continue;

        hud->surfaces[n].mon_x = x;
        hud->surfaces[n].mon_y = y;
        hud->surfaces[n].mon_w = w;
        hud->surfaces[n].mon_h = h;
        n++;
    }

    XRRFreeScreenResources (res);
    if (n > 0) {
        hud->n_surfaces = n;
        return;
    }

fallback:
    hud->surfaces[0].mon_x = 0;
    hud->surfaces[0].mon_y = 0;
    hud->surfaces[0].mon_w = DisplayWidth (hud->dpy, hud->screen);
    hud->surfaces[0].mon_h = DisplayHeight (hud->dpy, hud->screen);
    hud->n_surfaces = 1;
}

static void
ensure_visual (OwletDictationHudNative *hud)
{
    XVisualInfo vinfo;

    if (hud->visual_ready)
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
    hud->visual_ready = 1;
}

static void
ensure_surface_window (OwletDictationHudNative *hud, HudSurface *surf)
{
    XSetWindowAttributes attrs;
    unsigned long valuemask;
    Atom net_wm_state;
    Atom net_wm_window_type;
    Atom atoms[4];
    int natoms = 0;
    int x;
    int y;

    if (surf->created)
        return;

    ensure_visual (hud);

    memset (&attrs, 0, sizeof (attrs));
    attrs.override_redirect = True;
    attrs.background_pixel = 0;
    attrs.border_pixel = 0;
    attrs.colormap = hud->colormap;
    attrs.event_mask = ExposureMask | StructureNotifyMask;
    valuemask = CWOverrideRedirect | CWBackPixel | CWBorderPixel
                | CWColormap | CWEventMask;

    surf->win_w = 320;
    surf->win_h = 48;
    hud_position (surf, &x, &y);
    surf->win = XCreateWindow (hud->dpy, hud->root, x, y,
                               (unsigned) surf->win_w, (unsigned) surf->win_h,
                               0, hud->depth, InputOutput, hud->visual,
                               valuemask, &attrs);

    /* Click-through: empty input shape so pointer events pass through. */
    XShapeCombineRectangles (hud->dpy, surf->win, ShapeInput,
                             0, 0, NULL, 0, ShapeSet, Unsorted);

    net_wm_state = XInternAtom (hud->dpy, "_NET_WM_STATE", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_ABOVE", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_SKIP_TASKBAR", False);
    atoms[natoms++] = XInternAtom (hud->dpy, "_NET_WM_STATE_SKIP_PAGER", False);
    XChangeProperty (hud->dpy, surf->win, net_wm_state, XA_ATOM, 32,
                     PropModeReplace, (unsigned char *) atoms, natoms);

    net_wm_window_type = XInternAtom (hud->dpy, "_NET_WM_WINDOW_TYPE", False);
    atoms[0] = XInternAtom (hud->dpy, "_NET_WM_WINDOW_TYPE_NOTIFICATION", False);
    XChangeProperty (hud->dpy, surf->win, net_wm_window_type, XA_ATOM, 32,
                     PropModeReplace, (unsigned char *) atoms, 1);

    XStoreName (hud->dpy, surf->win, "Owlet Dictation");
    surf->created = 1;
}

static void
destroy_surface (OwletDictationHudNative *hud, HudSurface *surf)
{
    if (!surf->created)
        return;

    XDestroyWindow (hud->dpy, surf->win);
    surf->win = None;
    surf->created = 0;
    surf->mapped = 0;
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
redraw_surface (OwletDictationHudNative *hud, HudSurface *surf)
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

    if (!surf->created || !surf->mapped)
        return;

    max_w = (int) (surf->mon_w * HUD_MAX_WIDTH_FRAC);
    if (max_w < 200)
        max_w = 200;

    /* Temporary surface for measuring with the real visual. */
    surface = cairo_xlib_surface_create (hud->dpy, surf->win, hud->visual,
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

    if (new_w != surf->win_w || new_h != surf->win_h) {
        surf->win_w = new_w;
        surf->win_h = new_h;
        hud_position (surf, &x, &y);
        XMoveResizeWindow (hud->dpy, surf->win, x, y,
                           (unsigned) surf->win_w, (unsigned) surf->win_h);
        /* Re-apply empty input shape after resize. */
        XShapeCombineRectangles (hud->dpy, surf->win, ShapeInput,
                                 0, 0, NULL, 0, ShapeSet, Unsorted);
    }

    surface = cairo_xlib_surface_create (hud->dpy, surf->win, hud->visual,
                                         surf->win_w, surf->win_h);
    cairo_xlib_surface_set_size (surface, surf->win_w, surf->win_h);
    cr = cairo_create (surface);

    cairo_set_operator (cr, CAIRO_OPERATOR_SOURCE);
    cairo_set_source_rgba (cr, 0, 0, 0, 0);
    cairo_paint (cr);

    cairo_set_operator (cr, CAIRO_OPERATOR_OVER);
    rounded_rect (cr, 0.5, 0.5,
                  surf->win_w - 1.0, surf->win_h - 1.0, HUD_CORNER_RADIUS);
    cairo_set_source_rgba (cr, 0.08, 0.08, 0.10, 0.82);
    cairo_fill_preserve (cr);
    cairo_set_source_rgba (cr, 1.0, 1.0, 1.0, 0.12);
    cairo_set_line_width (cr, 1.0);
    cairo_stroke (cr);

    max_text_w = surf->win_w - (int) (HUD_PAD_X * 2 + HUD_DOT_RADIUS * 2 + HUD_DOT_GAP);
    if (max_text_w < 80)
        max_text_w = 80;
    measure_and_layout (cr, hud->text, max_text_w, &layout, &text_w, &text_h);

    dot_cx = HUD_PAD_X + HUD_DOT_RADIUS;
    dot_cy = surf->win_h / 2.0;
    cairo_arc (cr, dot_cx, dot_cy, HUD_DOT_RADIUS, 0, 2 * G_PI);
    cairo_set_source_rgba (cr, 0.90, 0.18, 0.18, 1.0);
    cairo_fill (cr);

    text_x = HUD_PAD_X + HUD_DOT_RADIUS * 2 + HUD_DOT_GAP;
    text_y = (surf->win_h - text_h) / 2.0;
    cairo_move_to (cr, text_x, text_y);
    cairo_set_source_rgba (cr, 0.95, 0.95, 0.97, 1.0);
    pango_cairo_show_layout (cr, layout);

    g_object_unref (layout);
    cairo_destroy (cr);
    cairo_surface_destroy (surface);
}

static void
redraw_all (OwletDictationHudNative *hud)
{
    int i;

    for (i = 0; i < hud->n_surfaces; i++)
        redraw_surface (hud, &hud->surfaces[i]);
    if (hud->mapped)
        XFlush (hud->dpy);
}

OwletDictationHudNative *
owlet_dictation_hud_native_new (void)
{
    OwletDictationHudNative *hud;
    Display *dpy;

    dpy = XOpenDisplay (NULL);
    if (dpy == NULL)
        return NULL;

    hud = g_new0 (OwletDictationHudNative, 1);
    hud->dpy = dpy;
    hud->screen = DefaultScreen (dpy);
    hud->root = RootWindow (dpy, hud->screen);
    query_monitors (hud);
    hud->text = g_strdup ("");
    return hud;
}

void
owlet_dictation_hud_native_free (OwletDictationHudNative *hud)
{
    int i;

    if (hud == NULL)
        return;

    for (i = 0; i < HUD_MAX_MONITORS; i++)
        destroy_surface (hud, &hud->surfaces[i]);

    if (hud->visual_ready && hud->depth == 32 && hud->colormap != None)
        XFreeColormap (hud->dpy, hud->colormap);
    if (hud->dpy != NULL)
        XCloseDisplay (hud->dpy);
    g_free (hud->text);
    g_free (hud);
}

void
owlet_dictation_hud_native_show (OwletDictationHudNative *hud)
{
    HudSurface old[HUD_MAX_MONITORS];
    int old_n;
    int i;
    int j;

    if (hud == NULL)
        return;

    /* Preserve existing X windows across a monitor re-query so we can
     * reuse geometry-matched surfaces instead of flickering. */
    memcpy (old, hud->surfaces, sizeof (old));
    old_n = hud->n_surfaces;
    memset (hud->surfaces, 0, sizeof (hud->surfaces));
    query_monitors (hud);

    for (i = 0; i < hud->n_surfaces; i++) {
        HudSurface *surf = &hud->surfaces[i];

        for (j = 0; j < old_n; j++) {
            if (!old[j].created)
                continue;
            if (old[j].mon_x == surf->mon_x
                && old[j].mon_y == surf->mon_y
                && old[j].mon_w == surf->mon_w
                && old[j].mon_h == surf->mon_h) {
                surf->win = old[j].win;
                surf->win_w = old[j].win_w;
                surf->win_h = old[j].win_h;
                surf->created = 1;
                surf->mapped = old[j].mapped;
                old[j].created = 0;
                break;
            }
        }
    }

    for (j = 0; j < old_n; j++)
        destroy_surface (hud, &old[j]);

    for (i = 0; i < hud->n_surfaces; i++) {
        HudSurface *surf = &hud->surfaces[i];
        int x;
        int y;

        ensure_surface_window (hud, surf);
        hud_position (surf, &x, &y);
        XMoveResizeWindow (hud->dpy, surf->win, x, y,
                           (unsigned) surf->win_w, (unsigned) surf->win_h);
        XMapRaised (hud->dpy, surf->win);
        surf->mapped = 1;
    }

    hud->mapped = 1;
    redraw_all (hud);
}

void
owlet_dictation_hud_native_hide (OwletDictationHudNative *hud)
{
    int i;

    if (hud == NULL)
        return;

    for (i = 0; i < hud->n_surfaces; i++) {
        HudSurface *surf = &hud->surfaces[i];

        if (surf->created && surf->mapped) {
            XUnmapWindow (hud->dpy, surf->win);
            surf->mapped = 0;
        }
    }
    if (hud->mapped)
        XFlush (hud->dpy);
    hud->mapped = 0;
    g_free (hud->text);
    hud->text = g_strdup ("");
}

void
owlet_dictation_hud_native_set_text (OwletDictationHudNative *hud,
                                    const char *text)
{
    if (hud == NULL)
        return;

    g_free (hud->text);
    hud->text = g_strdup (text != NULL ? text : "");
    if (hud->mapped)
        redraw_all (hud);
}
