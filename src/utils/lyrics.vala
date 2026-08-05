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
        private const uint SEARCH_REQUEST_INTERVAL_MS = 250;
        private const string CACHE_VERSION = "v1";

        private Soup.Session _session = new Soup.Session ();
        private File _cache_dir;

        public LyricsProvider () {
            _session.user_agent = "%s/%s (https://gitlab.gnome.org/neithern/g4music)".printf (
                Config.CODE_NAME, Config.VERSION);
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
            string[] suffixes = { ".lrc", ".LRC" };
            foreach (unowned var suffix in suffixes) {
                var lyrics_file = get_local_lrc_file (music, suffix);
                if (lyrics_file == null)
                    return null;
                try {
                    uint8[] contents;
                    string? etag;
                    yield ((!) lyrics_file).load_contents_async (
                        cancellable, out contents, out etag);
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

            var artists = get_artist_candidates (music);
            var track_artist = artists.length > 0 ? artists[0] : "";
            var cache_key = create_cache_key (music, track_artist, duration_seconds);
            var cached_lyrics = yield load_cache (cache_key, cancellable);
            if (cached_lyrics != null) {
                var cached_lines = parse_lrc ((!) cached_lyrics);
                if (cached_lines.length > 0) {
                    yield save_local_lrc (music, (!) cached_lyrics, cancellable);
                    return cached_lines;
                }
            }

            string? synced_lyrics = null;
            if (duration_seconds > 0 && artists.length > 0
                    && is_known_album (music.album)) {
                synced_lyrics = yield request_exact (
                    music, track_artist, duration_seconds, cancellable);
            }
            if (cancellable?.is_cancelled () ?? false)
                return null;

            if (synced_lyrics == null) {
                foreach (unowned var artist in artists) {
                    yield wait_before_search (cancellable);
                    if (cancellable?.is_cancelled () ?? false)
                        return null;
                    var url = "https://lrclib.net/api/search?track_name=%s&artist_name=%s".printf (
                        escape_query_value (music.title), escape_query_value (artist));
                    synced_lyrics = yield search_best_match (
                        url, music, duration_seconds, cancellable);
                    if (synced_lyrics != null)
                        break;
                }
            }
            if (synced_lyrics == null && artists.length > 0) {
                yield wait_before_search (cancellable);
                if (cancellable?.is_cancelled () ?? false)
                    return null;
                var keywords = "%s %s".printf (music.title, artists[0]);
                var url = "https://lrclib.net/api/search?q=%s".printf (
                    escape_query_value (keywords));
                synced_lyrics = yield search_best_match (
                    url, music, duration_seconds, cancellable);
            }
            if (synced_lyrics == null && artists.length == 0) {
                yield wait_before_search (cancellable);
                if (cancellable?.is_cancelled () ?? false)
                    return null;
                var url = "https://lrclib.net/api/search?track_name=%s".printf (
                    escape_query_value (music.title));
                synced_lyrics = yield search_best_match (
                    url, music, duration_seconds, cancellable);
            }
            if (synced_lyrics == null || ((!) synced_lyrics).strip ().length == 0)
                return null;

            var lines = parse_lrc ((!) synced_lyrics);
            if (lines.length == 0)
                return null;

            save_cache (cache_key, (!) synced_lyrics);
            yield save_local_lrc (music, (!) synced_lyrics, cancellable);
            return lines;
        }

        /**
         * 将在线歌词保存为歌曲旁的同名 LRC，不覆盖用户已有文件。
         */
        private async void save_local_lrc (
            Music music,
            string synced_lyrics,
            Cancellable? cancellable
        ) {
            var lyrics_file = get_local_lrc_file (music, ".lrc");
            var uppercase_file = get_local_lrc_file (music, ".LRC");
            if (lyrics_file == null || uppercase_file == null)
                return;
            var lowercase_exists = yield local_lrc_exists (
                (!) lyrics_file, cancellable);
            var uppercase_exists = yield local_lrc_exists (
                (!) uppercase_file, cancellable);
            if (lowercase_exists || uppercase_exists)
                return;

            var created = false;
            try {
                var stream = yield ((!) lyrics_file).create_async (
                    FileCreateFlags.PRIVATE, Priority.DEFAULT, cancellable);
                created = true;
                var contents = synced_lyrics.has_suffix ("\n")
                    ? synced_lyrics
                    : synced_lyrics + "\n";
                size_t bytes_written;
                yield stream.write_all_async (
                    contents.data,
                    Priority.DEFAULT,
                    null,
                    out bytes_written);
                yield stream.close_async (Priority.DEFAULT, null);
            } catch (Error error) {
                if (created) {
                    try {
                        yield ((!) lyrics_file).delete_async (
                            Priority.DEFAULT, null);
                    } catch (Error cleanup_error) {
                        warning ("Clean incomplete lyrics failed for %s: %s",
                            music.uri, cleanup_error.message);
                    }
                }
                if (!(error is IOError.EXISTS) && !(error is IOError.CANCELLED)) {
                    warning ("Save lyrics beside music failed for %s: %s",
                        music.uri, error.message);
                }
            }
        }

        private async bool local_lrc_exists (
            File lyrics_file,
            Cancellable? cancellable
        ) {
            try {
                yield lyrics_file.query_info_async (
                    FileAttribute.STANDARD_TYPE,
                    FileQueryInfoFlags.NONE,
                    Priority.DEFAULT,
                    cancellable);
                return true;
            } catch (Error error) {
                if (error is IOError.NOT_FOUND)
                    return false;
                if (!(error is IOError.CANCELLED)) {
                    warning ("Check lyrics file failed for %s: %s",
                        lyrics_file.get_uri (), error.message);
                }
                return true;
            }
        }

        private File? get_local_lrc_file (Music music, string suffix) {
            var music_file = File.new_for_uri (music.uri);
            var parent = music_file.get_parent ();
            var basename = music_file.get_basename ();
            if (parent == null || basename == null)
                return null;

            var extension = ((!) basename).last_index_of_char ('.');
            var stem = extension > 0
                ? ((!) basename).substring (0, extension)
                : (!) basename;
            return ((!) parent).get_child (stem + suffix);
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
            string url,
            Music music,
            int duration_seconds,
            Cancellable? cancellable
        ) {
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

                var score = score_record (record, music, duration_seconds);
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
            for (var attempt = 0; attempt < 2; attempt++) {
                try {
                    var message = new Soup.Message ("GET", url);
                    var bytes = yield _session.send_and_read_async (
                        message, Priority.DEFAULT, cancellable);
                    if (message.status_code == 429 && attempt == 0) {
                        var retry_seconds = get_retry_after_seconds (message);
                        warning ("LRCLIB rate limited, retry after %u seconds",
                            retry_seconds);
                        yield wait_milliseconds (retry_seconds * 1000);
                        if (cancellable?.is_cancelled () ?? false)
                            return null;
                        continue;
                    }
                    if (message.status_code != 200)
                        return null;

                    unowned uint8[] response = bytes.get_data ();
                    var parser = new Json.Parser ();
                    parser.load_from_data ((string) response, response.length);
                    return parser.get_root ()?.copy ();
                } catch (Error error) {
                    if (!(error is IOError.CANCELLED))
                        warning ("LRCLIB request failed: %s", error.message);
                    return null;
                }
            }
            return null;
        }

        private uint get_retry_after_seconds (Soup.Message message) {
            var value = message.response_headers.get_one ("Retry-After");
            uint seconds = 0;
            if (value != null && uint.try_parse ((!) value, out seconds))
                return seconds.clamp (1, 30);
            return 1;
        }

        private async void wait_before_search (Cancellable? cancellable) {
            if (cancellable == null || !((!) cancellable).is_cancelled ())
                yield wait_milliseconds (SEARCH_REQUEST_INTERVAL_MS);
        }

        private async void wait_milliseconds (uint milliseconds) {
            Timeout.add (milliseconds, () => {
                wait_milliseconds.callback ();
                return false;
            });
            yield;
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

            var result_artist = normalize_match_text (record.artist_name);
            var artists = get_artist_candidates (music);
            var artist_match_score = int.MIN;
            foreach (unowned var artist in artists) {
                var wanted_artist = normalize_match_text (artist);
                if (wanted_artist == result_artist)
                    artist_match_score = int.max (artist_match_score, 60);
                else if (wanted_artist.length > 0 && result_artist.length > 0
                        && (wanted_artist.contains (result_artist)
                            || result_artist.contains (wanted_artist)))
                    artist_match_score = int.max (artist_match_score, 35);
            }
            if (artist_match_score != int.MIN)
                score += artist_match_score;
            else if (artists.length > 0)
                score -= 30;

            var wanted_album = normalize_match_text (music.album);
            var result_album = normalize_match_text (record.album_name);
            if (is_known_album (music.album) && wanted_album == result_album)
                score += 15;

            if (duration_seconds > 0 && record.duration > 0) {
                var difference = (duration_seconds - record.duration).abs ();
                if (difference <= 2)
                    score += 50;
                else if (difference <= 5)
                    score += 20;
                else if (difference > 15)
                    score -= 50;
            }
            return score;
        }

        private GenericArray<string> get_artist_candidates (Music music) {
            var artists = new GenericArray<string> ();
            add_artist_candidate (artists, music.artist);
            add_artist_candidate (artists, music.album_artist);
            return artists;
        }

        private void add_artist_candidate (
            GenericArray<string> artists,
            string artist
        ) {
            var value = artist.strip ();
            if (value.length == 0 || value == UNKNOWN_ARTIST)
                return;
            var normalized = normalize_match_text (value);
            foreach (unowned var existing in artists) {
                if (normalize_match_text (existing) == normalized)
                    return;
            }
            artists.add (value);
        }

        private bool is_known_album (string album) {
            var value = album.strip ();
            return value.length > 0 && value != UNKNOWN_ALBUM;
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
