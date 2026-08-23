/* voice-models.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Manages voice model assets (download, SHA256 verification, extraction
 * via libarchive, two-rename promotion, debris sweep, and broken/installed
 * detection).
 *
 * Kept independent of Owlet.Application so tests and helper CLIs can
 * instantiate it standalone.
 */

public enum Owlet.VoiceStatus {
    NOT_INSTALLED,
    INSTALLED,
    BROKEN;

    public unowned string token () {
        switch (this) {
        case NOT_INSTALLED: return "not-installed";
        case INSTALLED: return "installed";
        case BROKEN: return "broken";
        default: assert_not_reached ();
        }
    }
}

public class Owlet.VoiceModels : GLib.Object {
    public const string DEFAULT_ARTIFACT_ID = "kokoro-en-v0_19";
    public const string DEFAULT_SHA256 = "912804859a0f0d1487f5d0fdf29d6be6d5b0ad6c0a7f191b7d59828e88605ac7";
    public const string DEFAULT_VOICE_NAME = "af_bella";
    public const int DEFAULT_VOICE_SID = 1;

    public const string[] DEFAULT_URLS = {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-en-v0_19.tar.bz2",
        "https://huggingface.co/csukuangfj/kokoro-en-v0_19/resolve/main/kokoro-en-v0_19.tar.bz2",
    };

    private const string[] REQUIRED_FILES = {
        "model.onnx",
        "voices.bin",
        "tokens.txt",
        "espeak-ng-data",
    };

    public signal void progress (int64 downloaded, int64 total);
    public signal void completed (string local_dir);
    public signal void failed (string message);
    public signal void busy_changed ();

    public bool download_in_progress { get; private set; default = false; }
    public string? active_transfer_name { get; private set; default = null; }

    private Owlet.ModelDownloader _downloader;
    private Cancellable? _active_cancellable = null;

    public VoiceModels (Owlet.ModelDownloader? downloader = null) {
        _downloader = downloader ?? new Owlet.ModelDownloader ();
    }

    public string get_models_dir () {
        return Path.build_filename (Environment.get_user_data_dir (), "owlet", "models");
    }

    public string get_voices_dir () {
        return Path.build_filename (get_models_dir (), "voices");
    }

    public string get_voice_dir (string artifact_id = DEFAULT_ARTIFACT_ID) {
        return Path.build_filename (get_voices_dir (), artifact_id);
    }

    public VoiceStatus get_status (string artifact_id = DEFAULT_ARTIFACT_ID) {
        sweep_debris (artifact_id);

        string voice_dir = get_voice_dir (artifact_id);
        var dir = File.new_for_path (voice_dir);
        if (!dir.query_exists ()) {
            return VoiceStatus.NOT_INSTALLED;
        }

        foreach (unowned string required_file in REQUIRED_FILES) {
            string file_path = Path.build_filename (voice_dir, required_file);
            if (!File.new_for_path (file_path).query_exists ()) {
                return VoiceStatus.BROKEN;
            }
        }

        return VoiceStatus.INSTALLED;
    }

    public void sweep_debris (string artifact_id = DEFAULT_ARTIFACT_ID) {
        string base_dir = get_voice_dir (artifact_id);
        var new_dir = File.new_for_path (base_dir + ".new");
        var old_dir = File.new_for_path (base_dir + ".old");

        if (new_dir.query_exists ()) {
            delete_directory_recursive (new_dir);
        }
        if (old_dir.query_exists ()) {
            delete_directory_recursive (old_dir);
        }
    }

    public void cancel_download () {
        if (_active_cancellable != null && !_active_cancellable.is_cancelled ()) {
            _active_cancellable.cancel ();
        }
    }

    public async void download_voice_async (string? custom_url = null,
                                           string? custom_sha256 = null,
                                           string artifact_id = DEFAULT_ARTIFACT_ID,
                                           Cancellable? cancellable = null) {
        if (download_in_progress) {
            failed (_("A download is already in progress (%s)").printf (active_transfer_name ?? ""));
            return;
        }

        download_in_progress = true;
        active_transfer_name = artifact_id;
        busy_changed ();

        _active_cancellable = new Cancellable ();
        ulong cancel_handler_id = 0;
        if (cancellable != null) {
            cancel_handler_id = cancellable.connect (() => {
                _active_cancellable.cancel ();
            });
        }

        string voices_dir = get_voices_dir ();
        int rc = DirUtils.create_with_parents (voices_dir, 0700);
        if (rc != 0) {
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            failed (_("Failed to create voice models directory: errno %d").printf (rc));
            return;
        }

        sweep_debris (artifact_id);

        string tarball_path = Path.build_filename (voices_dir, artifact_id + ".tar.bz2");
        string expected_sha256 = custom_sha256 ?? DEFAULT_SHA256;

        string[] urls_to_try;
        if (custom_url != null) {
            urls_to_try = { custom_url };
        } else {
            urls_to_try = DEFAULT_URLS;
        }

        bool downloaded = false;
        string? last_error = null;

        for (int i = 0; i < urls_to_try.length; i++) {
            if (_active_cancellable.is_cancelled ()) {
                break;
            }
            string url = urls_to_try[i];
            string? dl_error = null;
            string? dl_path = null;

            ulong p_id = _downloader.progress.connect ((dl, tot) => {
                progress (dl, tot);
            });
            ulong c_id = _downloader.completed.connect ((path) => {
                dl_path = path;
            });
            ulong f_id = _downloader.failed.connect ((msg) => {
                dl_error = msg;
            });

            yield _downloader.download_async (url, tarball_path, _active_cancellable);

            _downloader.disconnect (p_id);
            _downloader.disconnect (c_id);
            _downloader.disconnect (f_id);

            if (_active_cancellable.is_cancelled ()) {
                last_error = _("cancelled");
                break;
            }

            if (dl_path != null && File.new_for_path (dl_path).query_exists ()) {
                downloaded = true;
                break;
            } else {
                last_error = dl_error ?? _("Download failed");
            }
        }

        var tarball_file = File.new_for_path (tarball_path);

        if (!downloaded) {
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            if (tarball_file.query_exists ()) {
                try { tarball_file.delete (); } catch (Error e) {}
            }
            failed (last_error ?? _("Failed to download voice archive"));
            return;
        }

        // Verify SHA256 checksum
        string actual_sha256;
        try {
            actual_sha256 = compute_file_sha256 (tarball_path, _active_cancellable);
        } catch (Error e) {
            try { tarball_file.delete (); } catch (Error del_e) {}
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            if (_active_cancellable.is_cancelled ())
                failed (_("cancelled"));
            else
                failed (_("Failed to compute checksum: %s").printf (e.message));
            return;
        }

        if (_active_cancellable.is_cancelled ()) {
            try { tarball_file.delete (); } catch (Error del_e) {}
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            failed (_("cancelled"));
            return;
        }

        if (actual_sha256 != expected_sha256) {
            try { tarball_file.delete (); } catch (Error del_e) {}
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            failed (_("SHA256 mismatch: expected %s, got %s").printf (expected_sha256, actual_sha256));
            return;
        }

        // Extract to .new directory
        string voice_dir = get_voice_dir (artifact_id);
        string new_dir_path = voice_dir + ".new";
        string old_dir_path = voice_dir + ".old";

        DirUtils.create_with_parents (new_dir_path, 0700);

        bool extract_ok = extract_archive (tarball_path, new_dir_path);
        // Remove tarball immediately after extraction
        try { tarball_file.delete (); } catch (Error e) {}

        if (!extract_ok || _active_cancellable.is_cancelled ()) {
            var new_dir = File.new_for_path (new_dir_path);
            delete_directory_recursive (new_dir);
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            if (_active_cancellable.is_cancelled ())
                failed (_("cancelled"));
            else
                failed (_("Failed to extract voice archive"));
            return;
        }

        // Two-rename swap:
        // 1. existing voice_dir -> voice_dir.old (if exists)
        // 2. voice_dir.new -> voice_dir
        // 3. delete voice_dir.old
        var current_file = File.new_for_path (voice_dir);
        var old_file = File.new_for_path (old_dir_path);
        var new_file = File.new_for_path (new_dir_path);

        if (current_file.query_exists ()) {
            try {
                current_file.move (old_file, FileCopyFlags.OVERWRITE);
            } catch (Error e) {
                delete_directory_recursive (new_file);
                download_in_progress = false;
                active_transfer_name = null;
                busy_changed ();
                if (cancellable != null && cancel_handler_id != 0) {
                    cancellable.disconnect (cancel_handler_id);
                }
                failed (_("Failed to replace existing voice directory: %s").printf (e.message));
                return;
            }
        }

        try {
            new_file.move (current_file, FileCopyFlags.NONE);
        } catch (Error e) {
            if (old_file.query_exists ()) {
                try { old_file.move (current_file, FileCopyFlags.NONE); } catch (Error re_e) {}
            }
            delete_directory_recursive (new_file);
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            failed (_("Failed to promote new voice directory: %s").printf (e.message));
            return;
        }

        if (old_file.query_exists ()) {
            delete_directory_recursive (old_file);
        }

        // Check if extracted voice is valid
        if (get_status (artifact_id) != VoiceStatus.INSTALLED) {
            download_in_progress = false;
            active_transfer_name = null;
            busy_changed ();
            if (cancellable != null && cancel_handler_id != 0) {
                cancellable.disconnect (cancel_handler_id);
            }
            failed (_("Voice archive is missing required files"));
            return;
        }

        download_in_progress = false;
        active_transfer_name = null;
        busy_changed ();
        if (cancellable != null && cancel_handler_id != 0) {
            cancellable.disconnect (cancel_handler_id);
        }
        completed (voice_dir);
    }

    private static string compute_file_sha256 (string path, Cancellable? cancellable = null) throws Error {
        var file = File.new_for_path (path);
        var input = file.read (cancellable);
        var checksum = new Checksum (ChecksumType.SHA256);
        uint8[] buf = new uint8[64 * 1024];

        while (true) {
            ssize_t n = input.read (buf, cancellable);
            if (n == 0) {
                break;
            }
            if (n < 0) {
                throw new IOError.FAILED (_("Failed to read file for checksum"));
            }
            checksum.update (buf, (size_t) n);
        }
        input.close (cancellable);
        return checksum.get_string ();
    }

    private static bool extract_archive (string tar_path, string dest_dir) {
        var a = new Archive.Read ();
        a.support_filter_all ();
        a.support_format_all ();

        var ext = new Archive.WriteDisk ();
        ext.set_options (Archive.ExtractFlags.TIME | Archive.ExtractFlags.PERM | Archive.ExtractFlags.SECURE_NODOTDOT);

        var r = a.open_filename (tar_path, 16384);
        if (r != Archive.Result.OK) {
            return false;
        }

        unowned Archive.Entry entry;
        while ((r = a.next_header (out entry)) == Archive.Result.OK) {
            unowned string current_file = entry.pathname ();
            // Strip leading root directory component if archive has one (e.g. kokoro-en-v0_19/...)
            int slash_index = current_file.index_of_char ('/');
            string rel_path;
            if (slash_index >= 0) {
                if (slash_index == current_file.length - 1) {
                    continue; // Root directory itself
                }
                rel_path = current_file.substring (slash_index + 1);
            } else {
                rel_path = current_file;
            }

            string full_dest = Path.build_filename (dest_dir, rel_path);
            entry.set_pathname (full_dest);

            var wr = ext.write_header (entry);
            if (wr == Archive.Result.OK) {
                unowned uint8[] buff;
                Archive.int64_t offset;
                while (a.read_data_block (out buff, out offset) == Archive.Result.OK) {
                    ext.write_data_block (buff, offset);
                }
                ext.finish_entry ();
            }
        }

        a.close ();
        ext.close ();

        return r == Archive.Result.EOF;
    }

    private static void delete_directory_recursive (File dir) {
        try {
            var enumerator = dir.enumerate_children (
                FileAttribute.STANDARD_NAME + "," + FileAttribute.STANDARD_TYPE,
                FileQueryInfoFlags.NOFOLLOW_SYMLINKS,
                null
            );
            FileInfo? info;
            while ((info = enumerator.next_file (null)) != null) {
                var child = dir.get_child (info.get_name ());
                if (info.get_file_type () == FileType.DIRECTORY) {
                    delete_directory_recursive (child);
                } else {
                    child.delete (null);
                }
            }
            dir.delete (null);
        } catch (Error e) {
            // Best effort
        }
    }
}
