/* libei-shim.c
 *
 * C helpers wrapping libei's sentinel-terminated variadic functions
 * so they can be called from Vala without binding the varargs. Only
 * the KEYBOARD + TEXT (since libei 1.6) capabilities are bound, which
 * is all Owlet's dictation mode needs.
 *
 * TEXT (EI_DEVICE_CAP_TEXT) and ei_device_text_utf8* were added in
 * libei 1.6. Meson only compiles this shim when EI_DEVICE_CAP_TEXT is
 * present in libei.h; older distro libei (e.g. 1.5) is treated as
 * unavailable and dictation falls back to ydotool / xdotool.
 *
 * SPDX-License-Identifier: MIT
 */

#include "libei-shim.h"

void
owlet_ei_seat_bind_keyboard_text(struct ei_seat *seat)
{
    ei_seat_bind_capabilities(seat,
                              EI_DEVICE_CAP_KEYBOARD,
                              EI_DEVICE_CAP_TEXT,
                              NULL);
}

void
owlet_ei_seat_unbind_keyboard_text(struct ei_seat *seat)
{
    ei_seat_unbind_capabilities(seat,
                                EI_DEVICE_CAP_KEYBOARD,
                                EI_DEVICE_CAP_TEXT,
                                NULL);
}
