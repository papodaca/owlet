/* document_cli.vala — thin CLI around Owlet.Document for unit tests.
 *
 * Usage: owlet-document-cli PATH
 *
 * Stdout contract (asserted by tests/unit/test_document_model.py):
 *     status: ok|empty|not-text|unsupported-encoding|io-error
 *     sentences: N
 *     [0] First sentence.
 *     [1] Second one.
 * The user-visible error_message (if any) goes to stderr.
 *
 * Exit codes: 0 ok/empty · 2 usage · 3 not-text · 4 unsupported-encoding
 * · 5 io-error.
 */

int main (string[] args) {
    if (args.length != 2) {
        stderr.printf ("usage: %s PATH\n", args[0]);
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
