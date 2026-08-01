/*
 * dictation-hud-shim.h
 *
 * In-process X11 override-redirect OSD for background dictation.
 * Soft-fails (new returns NULL) when DISPLAY / X11 is unavailable.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef OWLET_DICTATION_HUD_SHIM_H
#define OWLET_DICTATION_HUD_SHIM_H

typedef struct OwletDictationHudNative OwletDictationHudNative;

/* Returns NULL if XOpenDisplay fails (no X11 / no XWayland). */
OwletDictationHudNative *owlet_dictation_hud_native_new (void);
void owlet_dictation_hud_native_free (OwletDictationHudNative *hud);

void owlet_dictation_hud_native_show (OwletDictationHudNative *hud);
void owlet_dictation_hud_native_hide (OwletDictationHudNative *hud);
void owlet_dictation_hud_native_set_text (OwletDictationHudNative *hud,
                                        const char *text);

#endif /* OWLET_DICTATION_HUD_SHIM_H */
