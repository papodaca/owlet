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
 *
 * Mic capture levels vary wildly with Pulse/PipeWire source volume
 * (e.g. 15% ≈ −50 dB). A fixed absolute RMS gate like 0.01 misses
 * real speech on quiet inputs and stops after pause_ms of "silence"
 * that was actually talking. Track a min-biased noise floor instead
 * and treat speech as a multiple of that floor.
 */

public class Owlet.SilenceDetector : GLib.Object {
    // Below this, treat as digital silence regardless of noise floor.
    public const float ABS_MIN_SPEECH_RMS = 1e-5f;
    // Frame is speech when RMS >= noise_rms * this ratio.
    public const float SPEECH_TO_NOISE_RATIO = 3.5f;
    // When RMS is above the floor, creep the estimate upward slowly
    // so a louder room can adapt without locking onto speech.
    public const float NOISE_RISE_ALPHA = 0.01f;
    // When RMS is below the floor, follow downward quickly.
    public const float NOISE_FALL_ALPHA = 0.20f;

    public int pause_ms { get; set; default = 1200; }

    private double silence_ms = 0.0;
    private float noise_rms = ABS_MIN_SPEECH_RMS;
    private bool noise_inited = false;
    private bool fired = false;

    public void reset () {
        silence_ms = 0.0;
        noise_rms = ABS_MIN_SPEECH_RMS;
        noise_inited = false;
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

        if (!noise_inited) {
            // Prefer the first non-trivial frame so leading digital-zero
            // buffers don't pin the floor forever.
            if (rms >= ABS_MIN_SPEECH_RMS) {
                noise_rms = rms;
                noise_inited = true;
            }
        } else if (rms < noise_rms) {
            noise_rms = noise_rms * (1.0f - NOISE_FALL_ALPHA) + rms * NOISE_FALL_ALPHA;
        } else {
            noise_rms = noise_rms * (1.0f - NOISE_RISE_ALPHA) + rms * NOISE_RISE_ALPHA;
        }
        if (noise_rms < ABS_MIN_SPEECH_RMS)
            noise_rms = ABS_MIN_SPEECH_RMS;

        float threshold = noise_rms * SPEECH_TO_NOISE_RATIO;
        if (threshold < ABS_MIN_SPEECH_RMS)
            threshold = ABS_MIN_SPEECH_RMS;

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
