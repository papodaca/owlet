/* tts_cli.vala — CLI test helper around Owlet.SpeechPlayer for TTS integration tests.
 *
 * Usage:
 *   owlet-tts-cli play MODEL_DIR DOC_PATH [START_INDEX]
 *   owlet-tts-cli pause-resume MODEL_DIR DOC_PATH
 *   owlet-tts-cli stop MODEL_DIR DOC_PATH
 *   owlet-tts-cli to-wav MODEL_DIR DOC_PATH OUT_WAV
 */

int main (string[] args) {
    if (args.length < 3) {
        stderr.printf ("usage: %s <play|pause-resume|stop|to-wav> MODEL_DIR DOC_PATH [ARG]\n", args[0]);
        return 2;
    }

    string command = args[1];
    string model_dir = args[2];
    string doc_path = args[3];

    var doc = Owlet.Document.load (doc_path);
    if (doc.status != Owlet.DocumentStatus.OK) {
        stderr.printf ("failed to load document: %s\n", doc.status.token ());
        return 1;
    }

    if (command == "play") {
        int start_idx = (args.length >= 5) ? int.parse (args[4]) : 0;
        var player = new Owlet.SpeechPlayer ();
        var loop = new MainLoop ();
        int exit_code = 0;

        player.playback_started.connect (() => {
            stdout.printf ("event: started\n");
        });
        player.position_changed.connect ((idx, total) => {
            stdout.printf ("position: %d / %d\n", idx, total);
        });
        player.playback_stopped.connect ((natural_end) => {
            stdout.printf ("event: stopped (natural_end: %s)\n", natural_end ? "true" : "false");
            loop.quit ();
        });
        player.error_occurred.connect ((msg) => {
            stderr.printf ("error: %s\n", msg);
            exit_code = 1;
            loop.quit ();
        });

        player.play (doc, model_dir, start_idx);
        loop.run ();
        return exit_code;
    }

    if (command == "pause-resume") {
        var player = new Owlet.SpeechPlayer ();
        var loop = new MainLoop ();
        int exit_code = 0;
        bool did_pause = false;

        player.playback_started.connect (() => {
            stdout.printf ("event: started\n");
        });
        player.position_changed.connect ((idx, total) => {
            stdout.printf ("position: %d / %d\n", idx, total);
            if (!did_pause && idx >= 1) {
                did_pause = true;
                player.pause ();
                stdout.printf ("event: paused (index: %d)\n", player.current_sentence_index);
                Timeout.add (50, () => {
                    stdout.printf ("event: resuming\n");
                    player.resume ();
                    return false;
                });
            }
        });
        player.playback_stopped.connect ((natural_end) => {
            stdout.printf ("event: stopped (natural_end: %s)\n", natural_end ? "true" : "false");
            loop.quit ();
        });
        player.error_occurred.connect ((msg) => {
            stderr.printf ("error: %s\n", msg);
            exit_code = 1;
            loop.quit ();
        });

        player.play (doc, model_dir, 0);
        loop.run ();
        return exit_code;
    }

    if (command == "stop") {
        var player = new Owlet.SpeechPlayer ();
        var loop = new MainLoop ();
        int exit_code = 0;

        player.playback_started.connect (() => {
            stdout.printf ("event: started\n");
            Idle.add (() => {
                player.stop ();
                return false;
            });
        });
        player.playback_stopped.connect ((natural_end) => {
            stdout.printf ("event: stopped (natural_end: %s)\n", natural_end ? "true" : "false");
            stdout.printf ("index_after_stop: %d\n", player.current_sentence_index);
            loop.quit ();
        });
        player.error_occurred.connect ((msg) => {
            stderr.printf ("error: %s\n", msg);
            exit_code = 1;
            loop.quit ();
        });

        player.play (doc, model_dir, 0);
        loop.run ();
        return exit_code;
    }

    if (command == "to-wav") {
        if (args.length < 5) {
            stderr.printf ("usage: %s to-wav MODEL_DIR DOC_PATH OUT_WAV\n", args[0]);
            return 2;
        }
        string out_wav = args[4];

        string model_path = Path.build_filename (model_dir, "model.onnx");
        string voices_path = Path.build_filename (model_dir, "voices.bin");
        string tokens_path = Path.build_filename (model_dir, "tokens.txt");
        string data_dir_path = Path.build_filename (model_dir, "espeak-ng-data");

        SherpaOnnx.OfflineTtsConfig config = {};
        config.model.kokoro.model = model_path;
        config.model.kokoro.voices = voices_path;
        config.model.kokoro.tokens = tokens_path;
        config.model.kokoro.data_dir = data_dir_path;
        config.model.kokoro.length_scale = 1.0f;
        config.model.num_threads = 2;
        config.model.provider = "cpu";
        config.model.debug = 0;

        var engine = SherpaOnnx.OfflineTts.create (ref config);
        if (engine == null) {
            stderr.printf ("failed to initialize engine\n");
            return 1;
        }

        int sample_rate = engine.sample_rate ();
        var mem_stream = new MemoryOutputStream.resizable ();
        var pcm_stream = new DataOutputStream (mem_stream);
        pcm_stream.set_byte_order (DataStreamByteOrder.LITTLE_ENDIAN);
        int total_pcm_samples = 0;

        foreach (unowned string sentence in doc.sentences) {
            var audio = engine.generate (sentence, 1, 1.0f);
            if (audio != null && audio.n > 0) {
                for (int i = 0; i < audio.n; i++) {
                    float sample = audio.samples[i];
                    float clamped = sample.clamp (-1.0f, 1.0f);
                    int16 pcm16 = (int16) (clamped * 32767.0f);
                    try {
                        pcm_stream.put_int16 (pcm16);
                    } catch (Error e) {
                        stderr.printf ("write error: %s\n", e.message);
                        return 1;
                    }
                }
                total_pcm_samples += audio.n;
            }
        }

        if (total_pcm_samples == 0) {
            stderr.printf ("no audio generated\n");
            return 1;
        }

        // Write WAV header and 16-bit PCM samples
        try {
            var file = File.new_for_path (out_wav);
            var stream = file.replace (null, false, FileCreateFlags.REPLACE_DESTINATION);
            var data_stream = new DataOutputStream (stream);
            data_stream.set_byte_order (DataStreamByteOrder.LITTLE_ENDIAN);

            int num_samples = total_pcm_samples;
            int num_channels = 1;
            int bits_per_sample = 16;
            int byte_rate = sample_rate * num_channels * (bits_per_sample / 8);
            int block_align = num_channels * (bits_per_sample / 8);
            int subchunk2_size = num_samples * num_channels * (bits_per_sample / 8);
            int chunk_size = 36 + subchunk2_size;

            data_stream.write ("RIFF".data);
            data_stream.put_int32 (chunk_size);
            data_stream.write ("WAVE".data);
            data_stream.write ("fmt ".data);
            data_stream.put_int32 (16); // Subchunk1Size (16 for PCM)
            data_stream.put_int16 (1);  // AudioFormat (1 for PCM)
            data_stream.put_int16 ((int16) num_channels);
            data_stream.put_int32 (sample_rate);
            data_stream.put_int32 (byte_rate);
            data_stream.put_int16 ((int16) block_align);
            data_stream.put_int16 ((int16) bits_per_sample);
            data_stream.write ("data".data);
            data_stream.put_int32 (subchunk2_size);

            unowned uint8[] pcm_bytes = mem_stream.get_data ();
            pcm_bytes.length = (int) mem_stream.get_data_size ();
            data_stream.write (pcm_bytes);

            data_stream.close ();
            stdout.printf ("wav_written: %s (samples: %d, rate: %d)\n", out_wav, num_samples, sample_rate);
            return 0;
        } catch (Error e) {
            stderr.printf ("failed to write wav: %s\n", e.message);
            return 1;
        }
    }

    stderr.printf ("unknown command: %s\n", command);
    return 2;
}
