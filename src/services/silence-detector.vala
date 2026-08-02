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
    // Default speech energy floor. 0.01 was far too high for typical
    // Pulse/PipeWire capture (quiet source volume never resets the
    // timer, so dictation dies after pause_ms ≈ one word). 0.002 still
    // sits well above ambient hiss on a sane mic level while keeping
    // mid-phrase dips from looking like end-of-utterance. Overridable
    // via GSettings / Preferences for noisy rooms or quiet mics.
    public const float DEFAULT_SPEECH_RMS_THRESHOLD = 0.002f;

    public int pause_ms { get; set; default = 1200; }
    public float speech_rms_threshold { get; set; default = DEFAULT_SPEECH_RMS_THRESHOLD; }

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

        float threshold = speech_rms_threshold;
        if (threshold < 0.0001f)
            threshold = 0.0001f;
        else if (threshold > 0.05f)
            threshold = 0.05f;

        if (rms >= threshold) {
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
