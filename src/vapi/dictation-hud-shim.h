/*
 * dictation-hud-shim.h
 *
 * In-process X11 override-redirect OSD for background dictation.
 * Soft-fails (new returns NULL) when DISPLAY / X11 is unavailable.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#ifndef KAKI_DICTATION_HUD_SHIM_H
#define KAKI_DICTATION_HUD_SHIM_H

typedef struct KakiDictationHudNative KakiDictationHudNative;

/* Returns NULL if XOpenDisplay fails (no X11 / no XWayland). */
KakiDictationHudNative *kaki_dictation_hud_native_new (void);
void kaki_dictation_hud_native_free (KakiDictationHudNative *hud);

void kaki_dictation_hud_native_show (KakiDictationHudNative *hud);
void kaki_dictation_hud_native_hide (KakiDictationHudNative *hud);
void kaki_dictation_hud_native_set_text (KakiDictationHudNative *hud,
                                        const char *text);

#endif /* KAKI_DICTATION_HUD_SHIM_H */
