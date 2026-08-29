/* word-spans.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Character-weighted word timing for the document reader's follow-along
 * highlight (KTD1). The TTS engine reports no word boundaries, so each
 * sentence's measured PCM duration is divided between its words in
 * proportion to their letter/digit grapheme counts.
 *
 * Pure: no GStreamer, no GTK. The synthesis worker thread computes spans
 * off the sentence string and `audio.n / sample_rate`; the caller must
 * not pass a duration already scaled by the speed dropdown, because the
 * generate rate is baked into the sample count.
 */

namespace Owlet {

    /* One highlightable word inside a single display sentence.
     *
     * `start` / `end` are GTK character offsets into that sentence (not
     * UTF-8 byte indices); `t0` / `t1` are seconds from the start of the
     * sentence's PCM.
     */
    public struct WordSpan {
        public int start;
        public int end;
        public double t0;
        public double t1;
    }

    namespace WordSpans {

        /* Ordered spans covering `sentence`, together spanning exactly
         * [0, duration_s].
         *
         * Tokens are split on Unicode whitespace, so trailing punctuation
         * and contractions stay attached to their word. Whitespace is
         * never highlighted, and a token holding no letter or digit
         * grapheme (a bare fence, an ellipsis) is not a span — which also
         * makes every recorded weight at least 1. The last span absorbs
         * the rounding remainder so the table matches the PCM.
         */
        public WordSpan[] estimate (string sentence, double duration_s) {
            if (duration_s <= 0.0) {
                return {};
            }

            int[] starts;
            int[] ends;
            int[] weights;
            collect_tokens (sentence, out starts, out ends, out weights);

            if (starts.length == 0) {
                return {};
            }

            int total_weight = 0;
            foreach (int w in weights) {
                total_weight += w;
            }

            var spans = new WordSpan[starts.length];
            double elapsed = 0.0;
            for (int i = 0; i < starts.length; i++) {
                double t1 = (i == starts.length - 1)
                    ? duration_s
                    : double.min (duration_s,
                                  elapsed + duration_s * weights[i] / total_weight);
                WordSpan span = { starts[i], ends[i], elapsed, t1 };
                spans[i] = span;
                elapsed = t1;
            }
            return spans;
        }

        /* Character offset of the token containing `char_offset`, or the
         * next token if the offset sits in whitespace. Past the last
         * token this is sentence.char_count (), so a slice from there
         * is empty and playback can move to the next sentence. */
        public int token_start_at (string sentence, int char_offset) {
            int[] starts;
            int[] ends;
            int[] weights;
            collect_tokens (sentence, out starts, out ends, out weights);
            if (starts.length == 0)
                return 0;
            if (char_offset < 0)
                char_offset = 0;

            for (int i = 0; i < starts.length; i++) {
                if (char_offset < ends[i])
                    return starts[i];
            }
            return (int) sentence.char_count ();
        }

        private void collect_tokens (string sentence,
                                     out int[] starts,
                                     out int[] ends,
                                     out int[] weights) {
            int[] tok_starts = {};
            int[] tok_ends = {};
            int[] tok_weights = {};

            int token_start = -1;
            int token_weight = 0;
            int offset = 0;
            int index = 0;
            unichar ch = 0;

            while (sentence.get_next_char (ref index, out ch)) {
                if (ch.isspace ()) {
                    if (token_start >= 0 && token_weight > 0) {
                        tok_starts += token_start;
                        tok_ends += offset;
                        tok_weights += token_weight;
                    }
                    token_start = -1;
                    token_weight = 0;
                } else {
                    if (token_start < 0) {
                        token_start = offset;
                    }
                    if (ch.isalnum ()) {
                        token_weight++;
                    }
                }
                offset++;
            }
            if (token_start >= 0 && token_weight > 0) {
                tok_starts += token_start;
                tok_ends += offset;
                tok_weights += token_weight;
            }
            starts = tok_starts;
            ends = tok_ends;
            weights = tok_weights;
        }
    }
}
