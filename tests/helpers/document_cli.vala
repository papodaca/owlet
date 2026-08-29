/* document_cli.vala — thin CLI around Owlet.Document for unit tests.
 *
 * Usage: owlet-document-cli PATH
 *        owlet-document-cli estimate DURATION_S TEXT
 *        owlet-document-cli at-offset PATH OFFSET
 *
 * Stdout contract (asserted by tests/unit/test_document_model.py):
 *     status: ok|empty|not-text|unsupported-encoding|io-error
 *     sentences: N
 *     [0] First sentence.
 *     [1] Second one.
 * The user-visible error_message (if any) goes to stderr.
 *
 * The `estimate` mode prints Owlet.WordSpans instead (asserted by
 * tests/unit/test_word_spans.py):
 *     spans: N
 *     [0] START END T0 T1 TOKEN
 * `at-offset` prints the sentence index for a character offset into
 * the reader display buffer (sentences joined by "\n\n"):
 *     status: ok
 *     index: N
 * One argument is always a PATH, so `owlet-document-cli estimate` or
 * `at-offset` alone reads as a file name rather than a truncated
 * subcommand.
 *
 * Exit codes: 0 ok/empty/estimate/at-offset · 2 usage · 3 not-text
 * · 4 unsupported-encoding · 5 io-error.
 */

int print_estimate (double duration_s, string text) {
    var spans = Owlet.WordSpans.estimate (text, duration_s);
    stdout.printf ("spans: %d\n", spans.length);
    for (int i = 0; i < spans.length; i++) {
        long from = text.index_of_nth_char (spans[i].start);
        long to = text.index_of_nth_char (spans[i].end);
        stdout.printf ("[%d] %d %d %.6f %.6f %s\n",
                       i, spans[i].start, spans[i].end,
                       spans[i].t0, spans[i].t1,
                       text.slice (from, to));
    }
    return 0;
}

int print_at_offset (string path, int offset) {
    var doc = Owlet.Document.load (path);
    stdout.printf ("status: %s\n", doc.status.token ());
    stdout.printf ("index: %d\n", doc.sentence_index_at_display_offset (offset));
    if (doc.error_message != "")
        stderr.printf ("%s\n", doc.error_message);
    switch (doc.status) {
    case Owlet.DocumentStatus.OK:
    case Owlet.DocumentStatus.EMPTY:
        return 0;
    case Owlet.DocumentStatus.NOT_TEXT:
        return 3;
    case Owlet.DocumentStatus.UNSUPPORTED_ENCODING:
        return 4;
    case Owlet.DocumentStatus.IO_ERROR:
        return 5;
    default:
        return 1;
    }
}

int main (string[] args) {
    if (args.length > 2 && args[1] == "estimate") {
        if (args.length != 4) {
            stderr.printf ("usage: %s estimate DURATION_S TEXT\n", args[0]);
            return 2;
        }
        return print_estimate (double.parse (args[2]), args[3]);
    }

    if (args.length > 2 && args[1] == "at-offset") {
        if (args.length != 4) {
            stderr.printf ("usage: %s at-offset PATH OFFSET\n", args[0]);
            return 2;
        }
        return print_at_offset (args[2], int.parse (args[3]));
    }

    if (args.length != 2) {
        stderr.printf ("usage: %s PATH | %s estimate DURATION_S TEXT | %s at-offset PATH OFFSET\n",
                       args[0], args[0], args[0]);
        return 2;
    }

    var doc = Owlet.Document.load (args[1]);

    stdout.printf ("status: %s\n", doc.status.token ());
    stdout.printf ("sentences: %d\n", doc.sentences.length);
    for (int i = 0; i < doc.sentences.length; i++) {
        stdout.printf ("[%d] %s\n", i, doc.sentences[i]);
    }

    if (doc.error_message != "") {
        stderr.printf ("%s\n", doc.error_message);
    }

    switch (doc.status) {
    case Owlet.DocumentStatus.OK:
    case Owlet.DocumentStatus.EMPTY:
        return 0;
    case Owlet.DocumentStatus.NOT_TEXT:
        return 3;
    case Owlet.DocumentStatus.UNSUPPORTED_ENCODING:
        return 4;
    case Owlet.DocumentStatus.IO_ERROR:
        return 5;
    default:
        return 1;
    }
}
