/* document.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Loads a plain-text or markdown file from disk into a validated,
 * speech-ready document: an ordered sentence list plus one of the
 * explicit NotText / UnsupportedEncoding / Empty outcomes (KTD-8).
 *
 * Load pipeline: File.load_contents → BOM sniff (UTF-16/32 BOM →
 * UnsupportedEncoding) → NUL-byte check → UTF-8 validate → the KTD-4
 * prepare seam (verbatim in v1; fence/front-matter stripping lands
 * here later as an additive change) → sentence segmentation.
 *
 * Segmentation splits on [.!?…] followed by whitespace or end of
 * text, treats blank lines as hard boundaries, collapses whitespace
 * runs, and caps oversized segments at the last space under
 * MAX_SEGMENT_CHARS (protects synthesis latency and pause
 * granularity: at the U11 spike's ~5× real-time rate, one 300-char
 * segment costs well under a second of pending audio). Three
 * no-split rules keep the sentence index honest on real prose:
 * never split a terminator between digits ("3.14" — falls out of
 * the base "followed by whitespace" rule);
 * never after a short known abbreviation/honorific ("Dr.", "etc.",
 * "i.e."); never after a single-letter + period sequence (initials,
 * "U.S."). A period embedded in a URL/domain token ("acme.com")
 * never splits either — it is never followed by whitespace.
 *
 * The class is UI-free by design: tests exercise the identical code
 * path through the owlet-document-cli helper (tests/helpers/).
 */

public enum Owlet.DocumentStatus {
    OK,
    EMPTY,
    NOT_TEXT,
    UNSUPPORTED_ENCODING,
    IO_ERROR;

    /* Stable machine token used by the owlet-document-cli stdout
     * contract that tests/unit/test_document_model.py asserts. */
    public unowned string token () {
        switch (this) {
        case OK: return "ok";
        case EMPTY: return "empty";
        case NOT_TEXT: return "not-text";
        case UNSUPPORTED_ENCODING: return "unsupported-encoding";
        case IO_ERROR: return "io-error";
        default: assert_not_reached ();
        }
    }
}

public class Owlet.Document : GLib.Object {
    /* Hard cap on one speech segment, in characters. */
    public const int MAX_SEGMENT_CHARS = 300;

    /* Short tokens whose trailing period never ends a sentence.
     * Case-insensitive; "e.g"/"i.e" include their interior period. */
    private const string[] ABBREVIATIONS = {
        "dr", "mr", "mrs", "ms", "prof", "fig", "approx", "etc",
        "e.g", "i.e", "vs", "st", "no",
    };

    public DocumentStatus status { get; private set; }
    public string error_message { get; private set; default = ""; }
    public string[] sentences { get; private set; default = {}; }

    public static Document load (string path) {
        var doc = new Document ();
        var file = File.new_for_path (path);

        uint8[] bytes;
        try {
            file.load_contents (null, out bytes, null);
        } catch (Error e) {
            doc.status = DocumentStatus.IO_ERROR;
            doc.error_message = _("Could not read the file: %s").printf (e.message);
            return doc;
        }

        // BOM sniff first: the UTF-32 BE BOM (00 00 FE FF) itself
        // contains NUL bytes, so this must precede the NUL check.
        // UTF-32 patterns are checked before UTF-16 because FF FE
        // 00 00 (UTF-32 LE) starts with the UTF-16 LE BOM.
        if (has_bytes (bytes, 0, { 0x00, 0x00, 0xFE, 0xFF }) ||
            has_bytes (bytes, 0, { 0xFF, 0xFE, 0x00, 0x00 })) {
            return doc.unsupported_encoding ();
        }
        if (has_bytes (bytes, 0, { 0xFF, 0xFE }) ||
            has_bytes (bytes, 0, { 0xFE, 0xFF })) {
            return doc.unsupported_encoding ();
        }

        foreach (uint8 b in bytes) {
            if (b == 0) {
                return doc.not_text ();
            }
        }

        // NULs are gone, so g_file_load_contents()'s implicit
        // trailing terminator makes this cast safe.
        unowned string text = (string) bytes;
        if (!text.validate ()) {
            return doc.not_text ();
        }

        return Document.from_validated_text (text);
    }

    /* Prepare + segment text that is already known to be valid UTF-8
     * with no NUL bytes (as produced by load()). */
    public static Document from_validated_text (string text) {
        var doc = new Document ();
        string prepared = prepare (text);
        if (is_all_whitespace (prepared)) {
            doc.status = DocumentStatus.EMPTY;
            return doc;
        }
        doc.sentences = segment (prepared);
        doc.status = DocumentStatus.OK;
        return doc;
    }

    /* Emptiness check without the full-text allocation strip() makes. */
    private static bool is_all_whitespace (string text) {
        int index = 0;
        unichar c;
        while (text.get_next_char (ref index, out c)) {
            if (!c.isspace ()) {
                return false;
            }
        }
        return true;
    }

    /* KTD-4 text-preparation seam: raw text → speech text. v1 reads
     * markdown verbatim; only the (invisible) UTF-8 BOM is removed.
     * Fence/front-matter stripping is added here later without
     * touching transport or the position model. */
    private static string prepare (string raw) {
        const string BOM = "\uFEFF";
        if (raw.has_prefix (BOM)) {
            return raw.substring (BOM.length);
        }
        return raw;
    }

    private Document unsupported_encoding () {
        status = DocumentStatus.UNSUPPORTED_ENCODING;
        error_message = _("This file's text encoding is not supported yet (UTF-16/UTF-32). Convert it to UTF-8.");
        return this;
    }

    private Document not_text () {
        status = DocumentStatus.NOT_TEXT;
        error_message = _("This file does not look like a text or markdown file.");
        return this;
    }

    private static bool has_bytes (uint8[] bytes, size_t offset, uint8[] expected) {
        if (bytes.length < offset + expected.length) {
            return false;
        }
        for (size_t i = 0; i < expected.length; i++) {
            if (bytes[offset + i] != expected[i]) {
                return false;
            }
        }
        return true;
    }

    /* --- Segmentation ------------------------------------------- */

    private static bool is_terminator (unichar c) {
        return c == '.' || c == '!' || c == '?' || c == '…';
    }

    private static string[] segment (string text) {
        // GenericArray (GPtrArray) grows in place; GLib.List would
        // re-bind its head pointer on append into an empty list,
        // which is invisible to the caller here.
        var segs = new GLib.GenericArray<string> ();
        var cur = new StringBuilder ();

        int text_len = (int) text.length;
        int index = 0;
        unichar c;
        while (text.get_next_char (ref index, out c)) {
            // index now sits just past c.
            unichar next_c = (index < text_len) ? text.get_char (index) : '\0';

            if (c.isspace ()) {
                int newlines = (c == '\n') ? 1 : 0;
                // Consume the rest of the whitespace run.
                while (index < text_len) {
                    unichar w = text.get_char (index);
                    if (!w.isspace ()) {
                        break;
                    }
                    if (w == '\n') {
                        newlines++;
                    }
                    text.get_next_char (ref index, out w);
                }
                if (newlines >= 2) {
                    // Blank line: hard boundary.
                    emit (cur, segs);
                } else if (cur.len > 0) {
                    // Collapse the run into a single space (also drops
                    // leading whitespace of fresh segments).
                    cur.append (" ");
                }
                continue;
            }

            if (is_terminator (c) && (next_c == '\0' || next_c.isspace ())) {
                unichar prev_c = tail_char (cur, 0);
                unichar prev2_c = tail_char (cur, 1);
                // Initial / letter-dot chain ("J.", "U.S."): the letter
                // before the period must stand alone — preceded by
                // start, whitespace, or another chain period. A mere
                // non-letter (e.g. the apostrophe in "James's.") must
                // NOT qualify, or possessives would never split.
                bool initial = prev_c.isalpha () &&
                    (prev2_c == '\0' || prev2_c == '.' || prev2_c.isspace ());
                if (!initial && !(tail_token (cur).down () in ABBREVIATIONS)) {
                    cur.append_unichar (c);
                    emit (cur, segs);
                    continue;
                }
            }

            cur.append_unichar (c);
        }
        emit (cur, segs);

        string[] result = new string[segs.length];
        for (int i = 0; i < segs.length; i++) {
            result[i] = segs[i];
        }
        return result;
    }

    /* The unichar `back` positions before the cursor ('\0' when the
     * segment is shorter). */
    private static unichar tail_char (StringBuilder sb, int back) {
        int index = (int) sb.len;
        unichar c = '\0';
        for (int i = 0; i <= back; i++) {
            if (!sb.str.get_prev_char (ref index, out c)) {
                return '\0';
            }
        }
        return c;
    }

    /* The run of letters / periods immediately before the cursor —
     * the token an abbreviation period would close. */
    private static string tail_token (StringBuilder sb) {
        int end = (int) sb.len;
        int index = end;
        while (index > 0) {
            int at = index;
            unichar c;
            if (!sb.str.get_prev_char (ref index, out c)) {
                break;
            }
            if (!c.isalpha () && c != '.') {
                return sb.str.substring (at, end - at);
            }
        }
        return sb.str.substring (0, end);
    }

    /* Append the finished segment (budget-splitting when oversized).
     * The scan loop already collapses whitespace runs to single
     * spaces and never lets a leading space into `cur`; the only
     * residue it can leave is one trailing space from a whitespace
     * run at end of text.
     *
     * Forward pass: oversized chunks are cut at the last space inside
     * the budget (hard char cut when the window holds no space). The
     * remainder is never re-copied or re-counted, keeping large
     * segments linear. */
    private static void emit (StringBuilder cur, GLib.GenericArray<string> segs) {
        if (cur.len == 0) {
            return;
        }
        if (cur.str[cur.len - 1] == ' ') {
            cur.truncate (cur.len - 1);
        }
        string chunk = cur.str;
        cur.truncate (0);

        int chunk_len = (int) chunk.length;
        int remaining = chunk.char_count ();
        int start = 0;

        while (remaining > MAX_SEGMENT_CHARS) {
            int end = start;
            int last_space = -1;
            int seen_at_last_space = -1;
            int seen = 0;
            unichar u;
            for (; seen < MAX_SEGMENT_CHARS && end < chunk_len; seen++) {
                if (chunk.get_char (end).isspace ()) {
                    last_space = end;
                    seen_at_last_space = seen;
                }
                chunk.get_next_char (ref end, out u);
            }

            int cut;
            int chars_in_cut;
            if (last_space > start) {
                cut = last_space;
                chars_in_cut = seen_at_last_space;
            } else {
                cut = end;
                chars_in_cut = seen;
            }

            string head = chunk.substring (start, cut - start).strip ();
            if (head != "") {
                segs.add (head);
            }

            start = cut;
            // Advance past separator space(s)
            while (start < chunk_len) {
                unichar w = chunk.get_char (start);
                if (!w.isspace ()) {
                    break;
                }
                chunk.get_next_char (ref start, out w);
                remaining--;
            }
            remaining -= chars_in_cut;
        }

        if (start < chunk_len) {
            string tail = chunk.substring (start).strip ();
            if (tail != "") {
                segs.add (tail);
            }
        }
    }
}
