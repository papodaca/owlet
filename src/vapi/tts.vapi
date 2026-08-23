/* tts.vapi
 *
 * Hand-written Vala binding for the offline TTS subset of sherpa-onnx
 * (subprojects/sherpa-onnx, v1.13.6). Covers model configs (Kokoro and
 * Vits), engine creation/teardown, sample rate / speaker inspection,
 * and speech generation with progress/cancel callbacks.
 */

[CCode (cprefix = "SherpaOnnx", lower_case_cprefix = "sherpa_onnx_", cheader_filename = "c-api.h")]
namespace SherpaOnnx {

    [CCode (cname = "SherpaOnnxOfflineTtsVitsModelConfig", has_type_id = false)]
    public struct OfflineTtsVitsModelConfig {
        public unowned string? model;
        public unowned string? lexicon;
        public unowned string? tokens;
        public unowned string? data_dir;
        public float noise_scale;
        public float noise_scale_w;
        public float length_scale;
        public unowned string? dict_dir;
    }

    [CCode (cname = "SherpaOnnxOfflineTtsKokoroModelConfig", has_type_id = false)]
    public struct OfflineTtsKokoroModelConfig {
        public unowned string? model;
        public unowned string? voices;
        public unowned string? tokens;
        public unowned string? data_dir;
        public float length_scale;
        public unowned string? dict_dir;
        public unowned string? lexicon;
        public unowned string? lang;
    }

    [CCode (cname = "SherpaOnnxOfflineTtsModelConfig", has_type_id = false)]
    public struct OfflineTtsModelConfig {
        public OfflineTtsVitsModelConfig vits;
        public int32 num_threads;
        public int32 debug;
        public unowned string? provider;
        public OfflineTtsKokoroModelConfig kokoro;
    }

    [CCode (cname = "SherpaOnnxOfflineTtsConfig", has_type_id = false)]
    public struct OfflineTtsConfig {
        public OfflineTtsModelConfig model;
        public unowned string? rule_fsts;
        public int32 max_num_sentences;
        public unowned string? rule_fars;
        public float silence_scale;
    }

    [Compact]
    [CCode (cname = "SherpaOnnxGeneratedAudio", free_function = "SherpaOnnxDestroyOfflineTtsGeneratedAudio", has_type_id = false)]
    public class GeneratedAudio {
        [CCode (cname = "samples", array_length_cname = "n")]
        public unowned float[] samples;
        public int32 n;
        public int32 sample_rate;
    }

    [CCode (cname = "SherpaOnnxGeneratedAudioProgressCallbackWithArg", has_target = true)]
    public delegate int32 ProgressCallback ([CCode (array_length_cname = "n")] float[] samples, float progress);

    [Compact]
    [CCode (cname = "SherpaOnnxOfflineTts", free_function = "SherpaOnnxDestroyOfflineTts", has_type_id = false)]
    public class OfflineTts {
        [CCode (cname = "SherpaOnnxCreateOfflineTts")]
        public static OfflineTts? create (ref OfflineTtsConfig config);

        [CCode (cname = "SherpaOnnxOfflineTtsSampleRate")]
        public int32 sample_rate ();

        [CCode (cname = "SherpaOnnxOfflineTtsNumSpeakers")]
        public int32 num_speakers ();

        [CCode (cname = "SherpaOnnxOfflineTtsGenerate")]
        public GeneratedAudio? generate (string text, int32 sid, float speed = 1.0f);

        [CCode (cname = "SherpaOnnxOfflineTtsGenerateWithProgressCallbackWithArg")]
        public GeneratedAudio? generate_with_progress_callback (string text, int32 sid, float speed, ProgressCallback callback);
    }
}
