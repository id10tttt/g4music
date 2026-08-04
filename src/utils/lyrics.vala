namespace G4 {

    private class LrclibRecord : Object {
        public string track_name = "";
        public string artist_name = "";
        public string album_name = "";
        public string synced_lyrics = "";
        public int duration = 0;
    }

    public class LyricsProvider : Object {
        private const int REQUEST_TIMEOUT_SECONDS = 15;
        private const int MINIMUM_SEARCH_SCORE = 115;
        private const string CACHE_VERSION = "v1";

        private Soup.Session _session = new Soup.Session ();
        private File _cache_dir;

        public LyricsProvider () {
            _session.user_agent = Config.APP_ID + "/" + Config.VERSION;
            _session.timeout = REQUEST_TIMEOUT_SECONDS;
            _cache_dir = File.new_build_filename (
                Environment.get_user_cache_dir (), Config.APP_ID, "lyrics");
        }

        /**
         * 优先读取音频文件旁边的同名 LRC 文件。
         */
        public async GenericArray<LyricLine>? load_local_lrc (
            Music music,
            Cancellable? cancellable = null
        ) {
            var music_file = File.new_for_uri (music.uri);
            var parent = music_file.get_parent ();
            var basename = music_file.get_basename ();
            if (parent == null || basename == null)
                return null;

            var extension = ((!) basename).last_index_of_char ('.');
            var stem = extension > 0 ? ((!) basename).substring (0, extension) : (!) basename;
            string[] suffixes = { ".lrc", ".LRC" };
            foreach (unowned var suffix in suffixes) {
                var lyrics_file = ((!) parent).get_child (stem + suffix);
                try {
                    uint8[] contents;
                    string? etag;
                    yield lyrics_file.load_contents_async (cancellable, out contents, out etag);
                    var lines = parse_lrc ((string) contents);
                    if (lines.length > 0)
                        return lines;
                } catch (Error error) {
                    if (error is IOError.CANCELLED)
                        return null;
                    if (!(error is IOError.NOT_FOUND)) {
                        warning ("Load local lyrics failed for %s: %s",
                            music.uri, error.message);
                    }
                }
            }
            return null;
        }

        /**
         * 从磁盘缓存或 LRCLIB 获取同步歌词。
         */
        public async GenericArray<LyricLine>? fetch_online (
            Music music,
            int duration_seconds,
            Cancellable? cancellable = null
        ) {
            if (music.title.strip ().length == 0)
                return null;

            var track_artist = get_track_artist (music);
            var cache_key = create_cache_key (music, track_artist, duration_seconds);
            var cached_lyrics = yield load_cache (cache_key, cancellable);
            if (cached_lyrics != null) {
                var cached_lines = parse_lrc ((!) cached_lyrics);
                if (cached_lines.length > 0)
                    return cached_lines;
            }

            string? synced_lyrics = null;
            if (duration_seconds > 0 && music.album.strip ().length > 0) {
                synced_lyrics = yield request_exact (
                    music, track_artist, duration_seconds, cancellable);
            }
            if (cancellable?.is_cancelled () ?? false)
                return null;

            if (synced_lyrics == null) {
                synced_lyrics = yield search_best_match (
                    music, track_artist, duration_seconds, cancellable);
            }
            if (synced_lyrics == null || ((!) synced_lyrics).strip ().length == 0)
                return null;

            var lines = parse_lrc ((!) synced_lyrics);
            if (lines.length == 0)
                return null;

            save_cache (cache_key, (!) synced_lyrics);
            return lines;
        }

        private async string? request_exact (
            Music music,
            string track_artist,
            int duration_seconds,
            Cancellable? cancellable
        ) {
            var url = "https://lrclib.net/api/get?track_name=%s&artist_name=%s&album_name=%s&duration=%d".printf (
                escape_query_value (music.title),
                escape_query_value (track_artist),
                escape_query_value (music.album),
                duration_seconds);
            var root = yield request_json (url, cancellable);
            if (root == null || ((!) root).get_node_type () != Json.NodeType.OBJECT)
                return null;

            return parse_record ((!) root).synced_lyrics;
        }

        private async string? search_best_match (
            Music music,
            string track_artist,
            int duration_seconds,
            Cancellable? cancellable
        ) {
            var url = "https://lrclib.net/api/search?track_name=%s&artist_name=%s".printf (
                escape_query_value (music.title), escape_query_value (track_artist));
            var root = yield request_json (url, cancellable);
            if (root == null || ((!) root).get_node_type () != Json.NodeType.ARRAY)
                return null;

            LrclibRecord? best_record = null;
            var best_score = int.MIN;
            var records = ((!) root).get_array ();
            if (records == null)
                return null;
            for (uint index = 0; index < ((!) records).get_length (); index++) {
                var node = ((!) records).get_element (index);
                if (node.get_node_type () != Json.NodeType.OBJECT)
                    continue;
                var record = parse_record (node);
                if (record.synced_lyrics.strip ().length == 0)
                    continue;

                var score = score_record (
                    record, music, track_artist, duration_seconds);
                if (score > best_score) {
                    best_score = score;
                    best_record = record;
                }
            }

            return best_score >= MINIMUM_SEARCH_SCORE
                ? best_record?.synced_lyrics
                : null;
        }

        private async Json.Node? request_json (
            string url,
            Cancellable? cancellable
        ) {
            try {
                var message = new Soup.Message ("GET", url);
                var bytes = yield _session.send_and_read_async (
                    message, Priority.DEFAULT, cancellable);
                if (message.status_code != 200)
                    return null;

                unowned uint8[] response = bytes.get_data ();
                var parser = new Json.Parser ();
                parser.load_from_data ((string) response, response.length);
                return parser.get_root ()?.copy ();
            } catch (Error error) {
                if (!(error is IOError.CANCELLED))
                    warning ("LRCLIB request failed: %s", error.message);
            }
            return null;
        }

        private LrclibRecord parse_record (Json.Node node) {
            var record = new LrclibRecord ();
            var object = node.get_object ();
            if (object == null)
                return record;
            record.track_name = get_json_string ((!) object, "trackName");
            record.artist_name = get_json_string ((!) object, "artistName");
            record.album_name = get_json_string ((!) object, "albumName");
            record.synced_lyrics = get_json_string ((!) object, "syncedLyrics");
            if (has_json_value ((!) object, "duration"))
                record.duration = (int) ((!) object).get_int_member ("duration");
            return record;
        }

        private int score_record (
            LrclibRecord record,
            Music music,
            string track_artist,
            int duration_seconds
        ) {
            var wanted_title = normalize_match_text (music.title);
            var result_title = normalize_match_text (record.track_name);
            int score;
            if (wanted_title == result_title) {
                score = 100;
            } else if (wanted_title.length > 0 && result_title.length > 0
                    && (wanted_title.contains (result_title)
                        || result_title.contains (wanted_title))) {
                score = 65;
            } else {
                return int.MIN;
            }

            var wanted_artist = normalize_match_text (track_artist);
            var result_artist = normalize_match_text (record.artist_name);
            if (wanted_artist.length > 0 && wanted_artist == result_artist)
                score += 60;
            else if (wanted_artist.length > 0 && result_artist.length > 0
                    && (wanted_artist.contains (result_artist)
                        || result_artist.contains (wanted_artist)))
                score += 35;
            else if (wanted_artist.length > 0)
                score -= 30;

            var wanted_album = normalize_match_text (music.album);
            var result_album = normalize_match_text (record.album_name);
            if (wanted_album.length > 0 && wanted_album == result_album)
                score += 15;

            if (duration_seconds > 0 && record.duration > 0) {
                var difference = (duration_seconds - record.duration).abs ();
                if (difference <= 2)
                    score += 40;
                else if (difference <= 5)
                    score += 20;
                else if (difference > 15)
                    score -= 50;
            }
            return score;
        }

        private string get_track_artist (Music music) {
            if (music.artist.length > 0 && music.artist != UNKNOWN_ARTIST)
                return music.artist;
            return music.album_artist;
        }

        private string normalize_match_text (string value) {
            try {
                var separators = new Regex ("[\\p{P}\\p{S}\\p{Z}_]+");
                return separators.replace (value.casefold (), -1, 0, "");
            } catch (RegexError error) {
                return value.casefold ().strip ();
            }
        }

        private string escape_query_value (string value) {
            return Uri.escape_string (value, null, false);
        }

        private string create_cache_key (
            Music music,
            string track_artist,
            int duration_seconds
        ) {
            var identity = "%s\n%s\n%s\n%s\n%d".printf (
                CACHE_VERSION,
                normalize_match_text (music.title),
                normalize_match_text (track_artist),
                normalize_match_text (music.album),
                duration_seconds);
            return Checksum.compute_for_string (ChecksumType.SHA256, identity);
        }

        private async string? load_cache (
            string cache_key,
            Cancellable? cancellable
        ) {
            var cache_file = _cache_dir.get_child (cache_key + ".lrc");
            try {
                uint8[] contents;
                string? etag;
                yield cache_file.load_contents_async (cancellable, out contents, out etag);
                return (string) contents;
            } catch (Error error) {
                if (!(error is IOError.NOT_FOUND) && !(error is IOError.CANCELLED))
                    warning ("Load lyrics cache failed: %s", error.message);
            }
            return null;
        }

        private void save_cache (string cache_key, string synced_lyrics) {
            try {
                if (!_cache_dir.query_exists ())
                    _cache_dir.make_directory_with_parents ();
                var cache_file = _cache_dir.get_child (cache_key + ".lrc");
                string? new_etag;
                cache_file.replace_contents (
                    synced_lyrics.data,
                    null,
                    false,
                    FileCreateFlags.PRIVATE,
                    out new_etag);
            } catch (Error error) {
                warning ("Save lyrics cache failed: %s", error.message);
            }
        }

        private bool has_json_value (Json.Object object, string member) {
            if (!object.has_member (member))
                return false;
            var node = object.get_member (member);
            return node != null
                && ((!) node).get_node_type () != Json.NodeType.NULL;
        }

        private string get_json_string (Json.Object object, string member) {
            return has_json_value (object, member)
                ? object.get_string_member (member)
                : "";
        }
    }
}
