/* speech-player.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Speech player service that coordinates local neural TTS synthesis
 * (sherpa-onnx) with streaming GStreamer playback (appsrc -> audioconvert
 * -> audioresample -> autoaudiosink / OWLET_TTS_SINK).
 *
 * Features:
 *   - Streaming per-sentence synthesis on a background worker thread
 *   - Sentence-index position tracking (KTD-3)
 *   - Play / Pause / Resume / Stop transport controls
 *   - In-flight bounds: pause-flush preserves sentence index, stop resets to 0
 *   - Lazy engine initialization, held strongly across play invocations
 */

using Gst;

public enum Owlet.PlayerState {
    STOPPED,
    PLAYING,
    PAUSED;

    public unowned string token () {
        switch (this) {
        case STOPPED: return "stopped";
        case PLAYING: return "playing";
        case PAUSED: return "paused";
        default: assert_not_reached ();
        }
    }
}

public class Owlet.SpeechPlayer : GLib.Object {
    public PlayerState state { get; private set; default = PlayerState.STOPPED; }
    public int current_sentence_index { get; private set; default = 0; }
    public int total_sentences { get; private set; default = 0; }

    public bool is_playing { get { return state == PlayerState.PLAYING; } }
    public bool is_paused  { get { return state == PlayerState.PAUSED; } }
    public bool is_stopped { get { return state == PlayerState.STOPPED; } }

    public signal void position_changed (int sentence_index, int total);
    public signal void playback_started ();
    public signal void playback_stopped (bool natural_end);
    public signal void error_occurred (string message);

    private SherpaOnnx.OfflineTts? _engine = null;
    private string? _cached_voice_dir = null;

    private Pipeline? _pipeline = null;
    private App.Src? _appsrc = null;
    private uint _bus_watch_id = 0;

    private Thread<void*>? _worker = null;
    private bool _cancel_worker = false;
    private Mutex _worker_mutex;
    private Cond _worker_cond;

    private Owlet.Document? _current_doc = null;
    private string _current_voice_dir = "";
    private int _current_sid = 1;
    private float _current_speed = 1.0f;
    private int _synth_index = 0;
    // Last sentence successfully pushed into appsrc (0-based), or -1.
    // Pause flushes that in-flight buffer; resume re-synthesizes it.
    private int _last_pushed_index = -1;

    private static bool _gst_inited = false;

    construct {
        _worker_mutex = Mutex ();
        _worker_cond = Cond ();
    }

    private static void ensure_gst_init () {
        if (_gst_inited)
            return;
        try {
            unowned string[]? args = null;
            Gst.init_check (ref args);
            _gst_inited = true;
        } catch (Error e) {
            // best effort
        }
    }

    public void invalidate_engine () {
        _engine = null;
        _cached_voice_dir = null;
    }

    private bool ensure_engine (string voice_dir) {
        if (_engine != null && _cached_voice_dir == voice_dir) {
            return true;
        }

        _engine = null;
        _cached_voice_dir = null;

        string model_path = Path.build_filename (voice_dir, "model.onnx");
        string voices_path = Path.build_filename (voice_dir, "voices.bin");
        string tokens_path = Path.build_filename (voice_dir, "tokens.txt");
        string data_dir_path = Path.build_filename (voice_dir, "espeak-ng-data");

        SherpaOnnx.OfflineTtsConfig config = {};
        config.model.kokoro.model = model_path;
        config.model.kokoro.voices = voices_path;
        config.model.kokoro.tokens = tokens_path;
        config.model.kokoro.data_dir = data_dir_path;
        config.model.kokoro.length_scale = 1.0f;
        config.model.num_threads = 2;
        config.model.provider = "cpu";
        config.model.debug = 0;

        _engine = SherpaOnnx.OfflineTts.create (ref config);
        if (_engine == null) {
            string msg = _("Failed to initialize speech synthesis engine from %s").printf (voice_dir);
            Idle.add (() => {
                error_occurred (msg);
                return false;
            });
            return false;
        }

        _cached_voice_dir = voice_dir;
        return true;
    }

    public void play (Owlet.Document document,
                      string voice_dir,
                      int start_index = 0,
                      int sid = 1,
                      float speed = 1.0f) {
        if (document.status != Owlet.DocumentStatus.OK || document.sentences.length == 0) {
            Idle.add (() => {
                error_occurred (_("Document has no readable text"));
                return false;
            });
            return;
        }

        stop_internal (false);

        if (!ensure_engine (voice_dir)) {
            return;
        }

        _current_doc = document;
        _current_voice_dir = voice_dir;
        _current_sid = sid;
        _current_speed = speed;
        total_sentences = document.sentences.length;
        current_sentence_index = (start_index >= 0 && start_index < total_sentences) ? start_index : 0;
        _synth_index = current_sentence_index;
        _last_pushed_index = -1;

        if (!setup_pipeline (_engine.sample_rate ())) {
            return;
        }

        state = PlayerState.PLAYING;
        playback_started ();

        start_worker ();
    }

    public void pause () {
        if (state != PlayerState.PLAYING) {
            return;
        }

        stop_worker ();
        // Drop queued PCM immediately (KTD-3). Position stays frozen;
        // resume re-synthesizes the flushed in-flight sentence.
        teardown_pipeline ();
        state = PlayerState.PAUSED;
    }

    public void resume () {
        if (state != PlayerState.PAUSED || _current_doc == null) {
            return;
        }

        if (!ensure_engine (_current_voice_dir)) {
            return;
        }

        // Re-synthesize the sentence whose PCM we flushed, if any.
        _synth_index = (_last_pushed_index >= 0) ? _last_pushed_index : current_sentence_index;
        _last_pushed_index = -1;

        if (!setup_pipeline (_engine.sample_rate ())) {
            return;
        }

        state = PlayerState.PLAYING;
        playback_started ();

        start_worker ();
    }

    public void stop () {
        stop_internal (true);
    }

    private void stop_internal (bool emit_signal) {
        stop_worker ();
        teardown_pipeline ();

        bool was_active = (state != PlayerState.STOPPED);
        state = PlayerState.STOPPED;
        current_sentence_index = 0;
        total_sentences = 0;
        _last_pushed_index = -1;
        _current_doc = null;

        if (emit_signal && was_active) {
            playback_stopped (false);
        }
    }

    private bool setup_pipeline (int sample_rate) {
        ensure_gst_init ();
        teardown_pipeline ();

        var pipeline = new Pipeline ("owlet-tts-player");
        _pipeline = pipeline;

        var src = (App.Src) ElementFactory.make ("appsrc", "src");
        if (src == null) {
            error_occurred (_("Failed to create GStreamer appsrc"));
            teardown_pipeline ();
            return false;
        }

        src.set_property ("format", Format.TIME);
        src.set_property ("is-live", false);
        src.set_property ("block", true);
        // One in-flight sentence: the next push blocks until the sink
        // drains (or pause tears the pipeline down).
        src.set_property ("max-buffers", 1u);
        src.set_caps (Caps.from_string (
            "audio/x-raw, format=F32LE, channels=1, rate=%d, layout=interleaved".printf (sample_rate)));
        _appsrc = src;

        var convert  = ElementFactory.make ("audioconvert", "convert");
        var resample = ElementFactory.make ("audioresample", "resample");

        string? sink_override = Environment.get_variable ("OWLET_TTS_SINK");
        Element? sink = null;
        if (sink_override != null && sink_override != "") {
            sink = ElementFactory.make (sink_override, "sink");
            if (sink_override == "fakesink" && sink != null) {
                sink.set_property ("sync", true);
            }
        }
        if (sink == null) {
            sink = ElementFactory.make ("autoaudiosink", "sink");
        }
        if (sink == null) {
            sink = ElementFactory.make ("fakesink", "sink");
        }

        pipeline.add_many (src, convert, resample, sink);
        if (!src.link_many (convert, resample, sink)) {
            error_occurred (_("Failed to link TTS playback pipeline"));
            teardown_pipeline ();
            return false;
        }

        var bus = pipeline.get_bus ();
        _bus_watch_id = bus.add_watch (GLib.Priority.DEFAULT, on_bus_message);

        var ret = pipeline.set_state (State.PLAYING);
        if (ret == StateChangeReturn.FAILURE) {
            error_occurred (_("Failed to start TTS playback pipeline"));
            teardown_pipeline ();
            return false;
        }

        return true;
    }

    private void teardown_pipeline () {
        if (_bus_watch_id != 0) {
            Source.remove (_bus_watch_id);
            _bus_watch_id = 0;
        }
        if (_pipeline != null) {
            _pipeline.set_state (State.NULL);
            _pipeline = null;
            _appsrc = null;
        }
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
        switch (message.type) {
        case MessageType.EOS:
            Idle.add (() => {
                if (state == PlayerState.PLAYING) {
                    stop_internal (false);
                    playback_stopped (true);
                }
                return false;
            });
            break;
        case MessageType.ERROR:
            GLib.Error err;
            string debug;
            message.parse_error (out err, out debug);
            Idle.add (() => {
                error_occurred (_("Audio playback error: %s").printf (err.message));
                stop_internal (true);
                return false;
            });
            break;
        default:
            break;
        }
        return true;
    }

    private void start_worker () {
        stop_worker ();
        _cancel_worker = false;
        try {
            _worker = new Thread<void*> ("tts-worker", worker_func);
        } catch (Error e) {
            error_occurred (_("Failed to start synthesis worker thread: %s").printf (e.message));
        }
    }

    private void stop_worker () {
        _cancel_worker = true;
        if (_worker != null) {
            _worker.join ();
            _worker = null;
        }
    }

    private void* worker_func () {
        while (!_cancel_worker && _current_doc != null) {
            int idx = _synth_index;
            if (idx >= _current_doc.sentences.length) {
                if (_appsrc != null) {
                    _appsrc.end_of_stream ();
                }
                break;
            }

            string sentence_text = _current_doc.sentences[idx];
            int sid = _current_sid;
            float speed = _current_speed;

            SherpaOnnx.GeneratedAudio? audio = null;
            if (_engine != null) {
                audio = _engine.generate_with_progress_callback (
                    sentence_text, sid, speed, (samples, progress) => {
                        return _cancel_worker ? 0 : 1;
                    }
                );
            }

            if (_cancel_worker) {
                break;
            }

            if (audio == null) {
                Idle.add (() => {
                    error_occurred (_("Speech synthesis failed on sentence %d").printf (idx + 1));
                    stop_internal (true);
                    return false;
                });
                break;
            }

            if (audio.n > 0 && _appsrc != null) {
                uint8[] bytes = new uint8[audio.n * sizeof (float)];
                Posix.memcpy (bytes, audio.samples, bytes.length);

                var buf = new Gst.Buffer.wrapped ((owned) bytes);
                var flow = _appsrc.push_buffer (buf);
                if (flow != FlowReturn.OK && flow != FlowReturn.FLUSHING) {
                    break;
                }
                if (flow == FlowReturn.OK) {
                    _last_pushed_index = idx;
                }
            }

            _synth_index = idx + 1;

            int sent_idx = idx + 1;
            int total = total_sentences;
            Idle.add (() => {
                if (state == PlayerState.PLAYING) {
                    current_sentence_index = sent_idx;
                    position_changed (sent_idx, total);
                }
                return false;
            });
        }
        return null;
    }

    public override void dispose () {
        stop_internal (false);
        invalidate_engine ();
        base.dispose ();
    }
}
