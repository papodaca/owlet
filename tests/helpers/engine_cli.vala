/* engine_cli.vala — thin CLI around SherpaOnnx OfflineTts for engine integration tests.
 *
 * Usage: owlet-engine-cli MODEL_DIR [TEXT]
 * Exit 0 on success; 1 on engine failure; 2 on usage error.
 */

int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("usage: %s MODEL_DIR [TEXT]\n", args[0]);
        return 2;
    }

    string model_dir = args[1];

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

    var tts = SherpaOnnx.OfflineTts.create (ref config);
    if (tts == null) {
        stderr.printf ("failed to initialize offline TTS engine from %s\n", model_dir);
        return 1;
    }

    stdout.printf ("engine: ok\n");
    stdout.printf ("sample_rate: %d\n", tts.sample_rate ());
    stdout.printf ("speakers: %d\n", tts.num_speakers ());

    if (args.length >= 3) {
        string text = args[2];
        int callback_invocations = 0;
        var audio = tts.generate_with_progress_callback (text, 0, 1.0f, (samples, progress) => {
            callback_invocations++;
            return 1; // continue
        });
        if (audio == null) {
            stderr.printf ("synthesis failed\n");
            return 1;
        }
        stdout.printf ("samples: %d\n", audio.n);
        stdout.printf ("callbacks: %d\n", callback_invocations);
    }

    return 0;
}
