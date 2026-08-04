namespace G4 {

    public class LyricLine : Object {
        public int64 time_ms;
        public string text;

        public LyricLine (int64 time_ms, string text) {
            this.time_ms = time_ms;
            this.text = text;
        }
    }

    /**
     * 解析 LRC 文本，支持一行多个时间标签和全局 offset 标签。
     */
    public GenericArray<LyricLine> parse_lrc (string content) {
        var parsed_lines = new GenericArray<LyricLine> ();
        int64 offset_ms = 0;

        foreach (unowned var raw_line in content.split ("\n")) {
            var line = raw_line.strip ();
            if (line.length == 0)
                continue;

            int position = 0;
            int64[] timestamps = {};
            while (position < line.length && line[position] == '[') {
                var close = line.index_of_char (']', position + 1);
                if (close < 0)
                    break;

                var tag = line.substring (position + 1, close - position - 1).strip ();
                int64 timestamp;
                int64 parsed_offset;
                if (try_parse_lrc_time_tag (tag, out timestamp)) {
                    timestamps += timestamp;
                    position = close + 1;
                    continue;
                }
                if (try_parse_offset_tag (tag, out parsed_offset))
                    offset_ms = parsed_offset;
                break;
            }

            if (timestamps.length == 0)
                continue;

            var text = line.substring (position).strip ();
            foreach (var timestamp in timestamps)
                parsed_lines.add (new LyricLine (timestamp, text));
        }

        foreach (var lyric_line in parsed_lines)
            lyric_line.time_ms = int64.max (0, lyric_line.time_ms + offset_ms);

        parsed_lines.sort ((first, second) => {
            if (first.time_ms < second.time_ms)
                return -1;
            if (first.time_ms > second.time_ms)
                return 1;
            return 0;
        });

        return merge_same_timestamp_lines (parsed_lines);
    }

    private bool try_parse_offset_tag (string tag, out int64 offset_ms) {
        offset_ms = 0;
        var colon = tag.index_of_char (':');
        if (colon <= 0 || tag.substring (0, colon).ascii_down () != "offset")
            return false;

        var value = tag.substring (colon + 1).strip ();
        return value.length > 0 && int64.try_parse (value, out offset_ms, null, 10);
    }

    private bool try_parse_lrc_time_tag (string tag, out int64 time_ms) {
        time_ms = 0;
        var colon = tag.index_of_char (':');
        if (colon <= 0)
            return false;

        int minutes;
        if (!int.try_parse (tag.substring (0, colon), out minutes, null, 10) || minutes < 0)
            return false;

        var seconds_and_fraction = tag.substring (colon + 1);
        var separator = seconds_and_fraction.index_of_char ('.');
        if (separator < 0)
            separator = seconds_and_fraction.index_of_char (':');

        var seconds_text = separator >= 0
            ? seconds_and_fraction.substring (0, separator)
            : seconds_and_fraction;
        var fraction_text = separator >= 0
            ? seconds_and_fraction.substring (separator + 1)
            : "";

        int seconds;
        if (!int.try_parse (seconds_text, out seconds, null, 10)
                || seconds < 0 || seconds >= 60)
            return false;

        int fraction_ms = 0;
        if (fraction_text.length > 0) {
            if (fraction_text.length > 3)
                fraction_text = fraction_text.substring (0, 3);
            if (!int.try_parse (fraction_text, out fraction_ms, null, 10))
                return false;
            for (var index = fraction_text.length; index < 3; index++)
                fraction_ms *= 10;
        }

        time_ms = ((int64) minutes * 60 + seconds) * 1000 + fraction_ms;
        return true;
    }

    private GenericArray<LyricLine> merge_same_timestamp_lines (
        GenericArray<LyricLine> parsed_lines
    ) {
        var result = new GenericArray<LyricLine> ();
        foreach (var lyric_line in parsed_lines) {
            if (result.length == 0
                    || result[result.length - 1].time_ms != lyric_line.time_ms) {
                result.add (lyric_line);
                continue;
            }

            var previous = result[result.length - 1];
            if (lyric_line.text.length > 0 && previous.text != lyric_line.text) {
                previous.text = previous.text.length > 0
                    ? previous.text + "\n" + lyric_line.text
                    : lyric_line.text;
            }
        }
        return result;
    }
}
