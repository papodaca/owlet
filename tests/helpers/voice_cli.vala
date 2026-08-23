/* voice_cli.vala — thin CLI around Owlet.VoiceModels for integration tests.
 *
 * Usage:
 *   owlet-voice-cli status [ARTIFACT_ID]
 *   owlet-voice-cli download URL SHA256 [ARTIFACT_ID]
 *   owlet-voice-cli double-download URL1 SHA1 URL2 SHA2
 *   owlet-voice-cli cancel URL SHA256
 */

int main (string[] args) {
    if (args.length < 2) {
        stderr.printf ("usage: %s <status|download|double-download|cancel> ...\n", args[0]);
        return 2;
    }

    string command = args[1];
    var voice_models = new Owlet.VoiceModels ();

    if (command == "status") {
        string artifact_id = (args.length >= 3) ? args[2] : Owlet.VoiceModels.DEFAULT_ARTIFACT_ID;
        var status = voice_models.get_status (artifact_id);
        stdout.printf ("status: %s\n", status.token ());
        stdout.printf ("dir: %s\n", voice_models.get_voice_dir (artifact_id));
        return 0;
    }

    if (command == "download") {
        if (args.length < 4) {
            stderr.printf ("usage: %s download URL SHA256 [ARTIFACT_ID]\n", args[0]);
            return 2;
        }
        string url = args[2];
        string sha256 = args[3];
        string artifact_id = (args.length >= 5) ? args[4] : Owlet.VoiceModels.DEFAULT_ARTIFACT_ID;

        var loop = new MainLoop ();
        int exit_code = 1;

        voice_models.completed.connect ((dir) => {
            stdout.printf ("completed: %s\n", dir);
            exit_code = 0;
            loop.quit ();
        });
        voice_models.failed.connect ((msg) => {
            stderr.printf ("failed: %s\n", msg);
            exit_code = 1;
            loop.quit ();
        });

        voice_models.download_voice_async.begin (url, sha256, artifact_id);
        loop.run ();
        return exit_code;
    }

    if (command == "double-download") {
        if (args.length < 6) {
            stderr.printf ("usage: %s double-download URL1 SHA1 URL2 SHA2\n", args[0]);
            return 2;
        }
        string url1 = args[2];
        string sha1 = args[3];
        string url2 = args[4];
        string sha2 = args[5];

        var loop = new MainLoop ();
        int exit_code = 1;
        bool second_failed = false;
        string? second_error = null;

        // First download listener
        voice_models.completed.connect ((dir) => {
            if (second_failed) {
                stdout.printf ("first_completed: %s\n", dir);
                stdout.printf ("second_error: %s\n", second_error ?? "");
                exit_code = 0;
            }
            loop.quit ();
        });
        voice_models.failed.connect ((msg) => {
            loop.quit ();
        });

        // Start first download
        voice_models.download_voice_async.begin (url1, sha1, "voice1");

        // Immediately try to start second download
        voice_models.failed.connect ((msg) => {
            second_failed = true;
            second_error = msg;
        });

        voice_models.download_voice_async.begin (url2, sha2, "voice2");
        loop.run ();

        return exit_code;
    }

    if (command == "cancel") {
        if (args.length < 4) {
            stderr.printf ("usage: %s cancel URL SHA256\n", args[0]);
            return 2;
        }
        string url = args[2];
        string sha256 = args[3];

        var loop = new MainLoop ();
        int exit_code = 1;
        var cancellable = new Cancellable ();

        voice_models.failed.connect ((msg) => {
            stdout.printf ("failed: %s\n", msg);
            exit_code = 0;
            loop.quit ();
        });
        voice_models.completed.connect ((dir) => {
            exit_code = 1;
            loop.quit ();
        });

        voice_models.download_voice_async.begin (url, sha256, Owlet.VoiceModels.DEFAULT_ARTIFACT_ID, cancellable);
        // Cancel after entering loop
        Idle.add (() => {
            cancellable.cancel ();
            return false;
        });

        loop.run ();
        return exit_code;
    }

    stderr.printf ("unknown command: %s\n", command);
    return 2;
}
