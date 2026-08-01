/* silence-detector.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Host-side RMS silence tracker for dictation auto-stop. Pure /
 * testable — no GSettings, GTK, or GStreamer. Observes float PCM
 * chunks (16 kHz mono F32LE from Recorder) and reports once when
 * consecutive silence reaches pause_ms.
 */

public class Owlet.SilenceDetector : GLib.Object {
    // Fixed speech energy floor for v1. Tuned against a quiet room mic
    // so soft speech still resets; ambient hiss stays below.
    public const float SPEECH_RMS_THRESHOLD = 0.01f;

    public int pause_ms { get; set; default = 1200; }

    private double silence_ms = 0.0;
    private bool fired = false;

    public void reset () {
        silence_ms = 0.0;
        fired = false;
    }

    /** @return true once when silence has lasted ≥ pause_ms */
    public bool observe (float[] samples, int sample_rate = 16000) {
        if (fired || samples.length == 0 || sample_rate <= 0)
            return false;

        double sum_sq = 0.0;
        for (int i = 0; i < samples.length; i++) {
            double s = samples[i];
            sum_sq += s * s;
        }
        float rms = (float) Math.sqrt (sum_sq / samples.length);

        if (rms >= SPEECH_RMS_THRESHOLD) {
            silence_ms = 0.0;
            return false;
        }

        silence_ms += (samples.length * 1000.0) / sample_rate;
        if (silence_ms < pause_ms)
            return false;

        fired = true;
        return true;
    }
}
