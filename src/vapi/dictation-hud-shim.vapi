/* dictation-hud-shim.vapi
 *
 * Hand-written bindings for the in-process X11 dictation OSD shim.
 * Only the subset Kaki calls is exposed.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

[CCode (cheader_filename = "dictation-hud-shim.h")]
namespace Kaki.DictationHudShim {
    [Compact]
    [CCode (cname = "KakiDictationHudNative",
            free_function = "kaki_dictation_hud_native_free")]
    public class Native {
        // Factory (not a constructor) so a NULL return from XOpenDisplay
        // failure maps cleanly to a Vala null without aborting.
        [CCode (cname = "kaki_dictation_hud_native_new")]
        public static Native? create ();

        [CCode (cname = "kaki_dictation_hud_native_show")]
        public void show ();

        [CCode (cname = "kaki_dictation_hud_native_hide")]
        public void hide ();

        [CCode (cname = "kaki_dictation_hud_native_set_text")]
        public void set_text (string text);
    }
}
