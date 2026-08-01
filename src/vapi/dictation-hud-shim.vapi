/* dictation-hud-shim.vapi
 *
 * Hand-written bindings for the in-process X11 dictation OSD shim.
 * Only the subset Owlet calls is exposed.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

[CCode (cheader_filename = "dictation-hud-shim.h")]
namespace Owlet.DictationHudShim {
    [Compact]
    [CCode (cname = "OwletDictationHudNative",
            free_function = "owlet_dictation_hud_native_free")]
    public class Native {
        // Factory (not a constructor) so a NULL return from XOpenDisplay
        // failure maps cleanly to a Vala null without aborting.
        [CCode (cname = "owlet_dictation_hud_native_new")]
        public static Native? create ();

        [CCode (cname = "owlet_dictation_hud_native_show")]
        public void show ();

        [CCode (cname = "owlet_dictation_hud_native_hide")]
        public void hide ();

        [CCode (cname = "owlet_dictation_hud_native_set_text")]
        public void set_text (string text);
    }
}
