namespace G4 {

    [GtkTemplate (ui = "/com/github/neithern/g4music/gtk/play-panel.ui")]
    public class PlayPanel : Gtk.Box, SizeWatcher {
        [GtkChild]
        private unowned Gtk.MenuButton action_btn;
        [GtkChild]
        private unowned Gtk.Button back_btn;
        [GtkChild]
        private unowned Gtk.Stack cover_stack;
        [GtkChild]
        private unowned Gtk.HeaderBar header_bar;
        [GtkChild]
        private unowned Gtk.Label index_label;
        [GtkChild]
        private unowned Gtk.Box music_box;
        [GtkChild]
        private unowned Gtk.Image music_cover;
        [GtkChild]
        private unowned Gtk.Overlay music_info;
        [GtkChild]
        private unowned StableLabel music_album;
        [GtkChild]
        private unowned StableLabel music_artist;
        [GtkChild]
        private unowned StableLabel music_title;
        [GtkChild]
        private unowned Gtk.Label initial_label;

        private PlayBar _play_bar = new PlayBar ();
        private LyricsView _lyrics_view = new LyricsView ();
        private LyricsProvider _lyrics_provider = new LyricsProvider ();
        private Gtk.Box _fullscreen_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        private Gtk.Box _fullscreen_left = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        private Gtk.Box _fullscreen_right = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        private Gtk.Picture _fullscreen_cover = new Gtk.Picture ();

        private Application _app;
        private double _degrees_per_second = 360 / 20; // 20s per lap
        private CrossFadePaintable _crossfade_paintable = new CrossFadePaintable ();
        private MatrixPaintable _matrix_paintable = new MatrixPaintable ();
        private RoundPaintable _round_paintable = new RoundPaintable ();
        private bool _rotate_cover = true;
        private bool _show_peak = true;
        private bool _size_allocated = false;
        private bool _fullscreen_mode = false;
        private bool _normal_lyrics_visible = false;
        private int _current_duration_seconds = 0;
        private Cancellable? _lyrics_cancellable = null;
        private uint _lyrics_duration_wait_handle = 0;
        private bool _online_lyrics_loading = false;
        private bool _lyrics_retry_when_duration_ready = false;
        private int _lyrics_request_duration_seconds = 0;

        public signal void cover_changed (Music? music, CrossFadePaintable cover);
        public signal void fullscreen_requested (bool visible);

        public PlayPanel (Application app, Window win, Leaflet leaflet) {
            _app = app;

            _play_bar.halign = Gtk.Align.FILL;
            _play_bar.position_seeked.connect (on_position_seeked);
            _play_bar.lyrics_toggled.connect (set_lyrics_visible);
            _play_bar.fullscreen_toggled.connect ((visible) => fullscreen_requested (visible));
            music_box.append (_play_bar);

            _lyrics_view.vexpand = true;
            cover_stack.add_named (_lyrics_view, "lyrics");

            leaflet.bind_property ("folded", back_btn, "visible", BindingFlags.SYNC_CREATE);

            action_btn.set_create_popup_func (() => action_btn.menu_model = create_music_action_menu ());

            back_btn.clicked.connect (leaflet.pop);

            setup_fullscreen_layout ();

            _matrix_paintable.paintable = _round_paintable;
            _crossfade_paintable.paintable = _matrix_paintable;
            _crossfade_paintable.queue_draw.connect (() => {
                music_cover.queue_draw ();
                _fullscreen_cover.queue_draw ();
            });
            music_cover.paintable = _crossfade_paintable;
            _fullscreen_cover.paintable = _crossfade_paintable;
            create_drag_source ();

            index_label.tooltip_text = _("Playing");
            make_widget_clickable (index_label).released.connect (() => win.open_playing_page ());

            initial_label.activate_link.connect (on_music_folder_clicked);

            music_album.tooltip_text = _("Search Album");
            music_artist.tooltip_text = _("Search Artist");
            music_title.tooltip_text = _("Search Title");
            make_widget_clickable (music_album).released.connect (
                () => win.start_search (music_album.label, SearchMode.ALBUM));
            make_widget_clickable (music_artist).released.connect (
                () => win.start_search (music_artist.label, SearchMode.ARTIST));
            make_widget_clickable (music_title).released.connect (
                () => win.start_search (music_title.label, SearchMode.TITLE));
            make_right_clickable (music_box, show_popover_menu);

            make_widget_clickable (music_cover).released.connect (() => {
                set_lyrics_visible (true);
            });

            app.index_changed.connect (on_index_changed);
            app.music_changed.connect (on_music_changed);
            app.music_cover_parsed.connect (on_music_cover_parsed);
            app.player.state_changed.connect (on_player_state_changed);
            app.player.duration_changed.connect (on_duration_changed);
            app.player.position_updated.connect (on_position_updated);

            var settings = app.settings;
            settings.bind ("rotate-cover", this, "rotate-cover", SettingsBindFlags.DEFAULT);
            settings.bind ("show-peak", this, "show-peak", SettingsBindFlags.DEFAULT);
        }

        public bool rotate_cover {
            get {
                return _rotate_cover;
            }
            set {
                _rotate_cover = value;
                _round_paintable.ratio = value && !_fullscreen_mode ? 0.5 : 0.05;
                _matrix_paintable.rotation = value && !_fullscreen_mode
                    ? _play_bar.position * _degrees_per_second : 0;
                on_player_state_changed (_app.player.state);
            }
        }

        public bool show_peak {
            get {
                return _show_peak;
            }
            set {
                _show_peak = value;
                on_player_state_changed (_app.player.state);
            }
        }

        public bool fullscreen_mode {
            get {
                return _fullscreen_mode;
            }
            set {
                if (_fullscreen_mode == value)
                    return;
                _fullscreen_mode = value;
                update_fullscreen_layout ();
            }
        }

        public void first_allocated () {
            // Delay update info after the window size allocated to avoid showing slowly
            _size_allocated = true;
            on_music_changed (_app.current_music);
        }

        public void size_to_change (int width, int height) {
            if (_fullscreen_mode) {
                size_fullscreen_layout (width, height);
                return;
            }

            var max_size = int.max (width * 3 / 4, music_cover.pixel_size);
            var margin_horz = (width - max_size) / 2;
            var margin_cover = int.max (margin_horz, 32);
            music_cover.margin_start = margin_cover;
            music_cover.margin_end = margin_cover;

            var margin_bar = int.max (margin_horz / 2, 16);
            var spacing = (height - 540).clamp (8, 16);
            _play_bar.margin_start = margin_bar;
            _play_bar.margin_end = margin_bar;
            _play_bar.margin_top = spacing;
            _play_bar.margin_bottom = spacing * 2;
            _play_bar.on_size_changed (width - margin_bar * 2, spacing);
        }

        /**
         * 创建全屏双栏容器，实际内容在进入全屏时复用现有控件。
         */
        private void setup_fullscreen_layout () {
            _fullscreen_box.visible = false;
            _fullscreen_box.hexpand = true;
            _fullscreen_box.vexpand = true;
            _fullscreen_box.add_css_class ("fullscreen-player");

            _fullscreen_left.vexpand = true;
            _fullscreen_left.valign = Gtk.Align.CENTER;
            _fullscreen_cover.halign = Gtk.Align.CENTER;
            _fullscreen_cover.valign = Gtk.Align.CENTER;
            _fullscreen_cover.can_shrink = true;
            _fullscreen_cover.content_fit = Gtk.ContentFit.COVER;
            _fullscreen_left.append (_fullscreen_cover);

            _fullscreen_right.hexpand = true;
            _fullscreen_right.vexpand = true;
            _fullscreen_right.halign = Gtk.Align.FILL;
            _fullscreen_box.append (_fullscreen_left);
            _fullscreen_box.append (_fullscreen_right);
            append (_fullscreen_box);
        }

        /**
         * 在普通播放页和全屏双栏布局之间移动共享控件。
         */
        private void update_fullscreen_layout () {
            if (_fullscreen_mode) {
                _normal_lyrics_visible = cover_stack.visible_child_name == "lyrics";
                cover_stack.remove (_lyrics_view);
                music_box.remove (music_info);
                music_box.remove (_play_bar);
                _fullscreen_left.append (music_info);
                _fullscreen_left.append (_play_bar);
                _fullscreen_right.append (_lyrics_view);

                music_title.halign = Gtk.Align.START;
                music_artist.halign = Gtk.Align.START;
                music_album.halign = Gtk.Align.START;
                header_bar.visible = false;
                music_box.visible = false;
                _fullscreen_box.visible = true;
                _play_bar.lyrics_button_visible = false;
                _play_bar.fullscreen_visible = true;
                _round_paintable.ratio = 0.05;
                _matrix_paintable.rotation = 0;
                _lyrics_view.update_position (
                    (int64) (_app.player.position / Gst.MSECOND));
                _lyrics_view.recenter_current ();
            } else {
                _fullscreen_left.remove (music_info);
                _fullscreen_left.remove (_play_bar);
                _fullscreen_right.remove (_lyrics_view);
                cover_stack.add_named (_lyrics_view, "lyrics");
                music_box.append (music_info);
                music_box.append (_play_bar);

                music_title.halign = Gtk.Align.CENTER;
                music_artist.halign = Gtk.Align.CENTER;
                music_album.halign = Gtk.Align.CENTER;
                music_info.halign = Gtk.Align.FILL;
                music_info.width_request = -1;
                cover_stack.visible_child_name = _normal_lyrics_visible ? "lyrics" : "cover";
                _play_bar.lyrics_button_visible = true;
                _play_bar.lyrics_visible = _normal_lyrics_visible;
                _play_bar.fullscreen_visible = false;
                _play_bar.halign = Gtk.Align.FILL;
                _play_bar.width_request = -1;
                _round_paintable.ratio = _rotate_cover ? 0.5 : 0.05;
                _matrix_paintable.rotation = _rotate_cover
                    ? _play_bar.position * _degrees_per_second : 0;
                _fullscreen_box.visible = false;
                music_box.visible = true;
                header_bar.visible = true;
                music_info.margin_start = 16;
                music_info.margin_end = 16;
                music_info.margin_top = 8;
                if (_normal_lyrics_visible)
                    _lyrics_view.recenter_current ();
            }
        }

        /**
         * 按固定比例调整全屏左右栏、封面和歌词留白。
         */
        private void size_fullscreen_layout (int width, int height) {
            var left_column_width = (int) (width * 0.44);
            var right_column_width = width - left_column_width;
            var outer_margin = (width / 32).clamp (24, 64);
            var content_width = int.max (180,
                left_column_width - outer_margin * 2);
            var cover_size = int.min (content_width,
                (int) (height * 0.52)).clamp (180, 640);

            // Gtk.Box 会把 margin 计入子控件的总占用宽度，因此 width_request
            // 只申请扣除边距后的内容宽度，避免左栏挤压歌词栏。
            _fullscreen_left.width_request = int.max (180,
                left_column_width - outer_margin * 2);
            _fullscreen_left.margin_start = outer_margin;
            _fullscreen_left.margin_end = outer_margin;
            _fullscreen_cover.set_size_request (cover_size, cover_size);
            music_info.halign = Gtk.Align.CENTER;
            music_info.width_request = cover_size;
            music_info.margin_start = 0;
            music_info.margin_end = 0;
            music_info.margin_top = 16;
            _play_bar.margin_start = 0;
            _play_bar.margin_end = 0;
            _play_bar.halign = Gtk.Align.CENTER;
            _play_bar.width_request = cover_size;
            _play_bar.margin_top = 12;
            _play_bar.margin_bottom = 0;
            _play_bar.on_size_changed (cover_size, 8);

            var lyrics_margin = (width / 40).clamp (24, 56);
            _fullscreen_right.width_request = int.max (180,
                right_column_width - lyrics_margin * 2);
            _fullscreen_right.margin_start = lyrics_margin;
            _fullscreen_right.margin_end = lyrics_margin;
            _fullscreen_right.margin_top = (height / 14).clamp (32, 80);
            _fullscreen_right.margin_bottom = (height / 14).clamp (32, 80);
        }

        private void create_drag_source () {
            var point = Graphene.Point ();
            var source = new Gtk.DragSource ();
            source.actions = Gdk.DragAction.LINK;
            source.drag_begin.connect ((drag) => source.set_icon (create_widget_paintable (music_cover, ref point), (int) point.x, (int) point.y));
            source.prepare.connect ((x, y) => {
                var pt = Graphene.Point ();
                pt.init ((float) x, (float) y);
                var width = music_cover.get_width ();
                var height = music_cover.get_height ();
                if (width > height)
                    pt.x -= (width - height) * 0.5f;
                else if (height > width)
                    pt.y -= (height - width) * 0.5f;
                var music = _app.current_music;
                if (music != null && _round_paintable.contains (pt)) {
                    point.init ((float) x, (float) y);
                    var playlist = to_playlist ({ (!)music });
                    return create_content_provider (playlist);
                }
                return null;
            });
            music_cover.add_controller (source);
        }

        private Menu create_music_action_menu () {
            var music = _app.current_music ?? new Music.empty ();
            return create_menu_for_music (music, _app.current_cover != null);
        }

        private void on_index_changed (int index, uint size) {
            root.action_set_enabled (ACTION_APP + ACTION_PREV, index > 0);
            root.action_set_enabled (ACTION_APP + ACTION_NEXT, index < (int) size - 1);
            index_label.label = size > 0 ? @"$(index+1)/$(size)" : "";
        }

        private void on_music_changed (Music? music) {
            if (!_size_allocated)
                return;

            music_album.label = music?.album ?? "";
            music_artist.label = music?.artist ?? "";
            music_title.label = music?.title ?? "";

            var empty = _app.current_music == null && _app.current_list.get_n_items () == 0;
            initial_label.visible = empty;
            if (empty) {
                if (_app.loading || !_app.loader.library.empty)
                    initial_label.label = "";
                else
                    update_initial_label (_app.music_folder);
            }

            var enabled = music != null;
            _play_bar.lyrics_enabled = enabled;
            _play_bar.fullscreen_enabled = enabled;
            if (!enabled) {
                update_cover_paintables (music, _app.icon);
            }
            action_btn.sensitive = enabled;
            root.action_set_enabled (ACTION_APP + ACTION_PLAY_PAUSE, enabled);
            Window.get_default ()?.set_title (music?.get_artist_and_title () ?? _app.name);

            cancel_lyrics_load ();
            if (music != null) {
                _current_duration_seconds = 0;
                _lyrics_view.set_loading ();
                var cancellable = new Cancellable ();
                _lyrics_cancellable = cancellable;
                load_lyrics.begin ((!) music, cancellable);
            } else {
                if (_fullscreen_mode)
                    fullscreen_requested (false);
                set_lyrics_visible (false);
                _lyrics_view.set_no_lyrics ();
            }
        }

        /**
         * 在封面与歌词视图之间切换，并同步播放栏按钮状态。
         */
        private void set_lyrics_visible (bool visible) {
            var show_lyrics = visible && _app.current_music != null;
            cover_stack.visible_child_name = show_lyrics ? "lyrics" : "cover";
            _play_bar.lyrics_visible = show_lyrics;
            if (show_lyrics) {
                _lyrics_view.update_position (
                    (int64) (_app.player.position / Gst.MSECOND));
                _lyrics_view.recenter_current ();
            }
        }

        private bool on_music_folder_clicked (string uri) {
            pick_music_folder (_app, root as Window,
                (dir) => update_initial_label (dir.get_uri ()));
            return true;
        }

        private async void on_music_cover_parsed (Music music, Gdk.Pixbuf? pixbuf, string? uri) {
            var paintable = pixbuf != null ? Gdk.Texture.for_pixbuf ((!)pixbuf)
                            : _app.thumbnailer.create_music_default_paintable (
                                music, Thumbnailer.DEFAULT_COVER_SIZE);
            update_cover_paintables (music, paintable);
        }

        private void on_duration_changed (Gst.ClockTime duration) {
            var music = _app.current_music;
            if (music == null || _app.player.uri != ((!) music).uri)
                return;

            _current_duration_seconds = (int) (GstPlayer.to_second (duration) + 0.5);
            if (_current_duration_seconds <= 0)
                return;

            var cancellable = _lyrics_cancellable;
            if (cancellable == null
                    || !is_current_lyrics_request ((!) music, (!) cancellable))
                return;

            if (_lyrics_duration_wait_handle != 0) {
                Source.remove (_lyrics_duration_wait_handle);
                _lyrics_duration_wait_handle = 0;
                load_online_lyrics.begin ((!) music, (!) cancellable);
            } else if (_online_lyrics_loading
                    && _lyrics_request_duration_seconds <= 0) {
                _lyrics_retry_when_duration_ready = true;
            } else if (_lyrics_retry_when_duration_ready) {
                _lyrics_retry_when_duration_ready = false;
                load_online_lyrics.begin ((!) music, (!) cancellable);
            }
        }

        private void on_position_updated (Gst.ClockTime position) {
            if (_fullscreen_mode || cover_stack.visible_child_name == "lyrics")
                _lyrics_view.update_position ((int64) (position / Gst.MSECOND));
        }

        private Adw.Animation? _scale_animation = null;
        private uint _tick_handler = 0;
        private int64 _tick_last_time = 0;

        private void on_player_state_changed (Gst.State state) {
            var playing = state == Gst.State.PLAYING;
            if (state >= Gst.State.PAUSED) {
                var target = new Adw.CallbackAnimationTarget ((value) => _matrix_paintable.scale = value);
                _scale_animation?.pause ();
                _scale_animation = new Adw.TimedAnimation (music_cover, _matrix_paintable.scale,
                                        _rotate_cover || playing ? 1 : 0.85, 500, target);
                _scale_animation?.play ();
            }

            var need_tick = _rotate_cover || _show_peak;
            if (need_tick && playing && _tick_handler == 0) {
                _tick_last_time = get_monotonic_time ();
                _tick_handler = add_tick_callback (on_tick_callback);
            } else if ((!need_tick || !playing) && _tick_handler != 0) {
                remove_tick_callback (_tick_handler);
                _tick_handler = 0;
            }
        }

        private void on_position_seeked (double pos) {
            if (_rotate_cover)
                _matrix_paintable.rotation = pos * _degrees_per_second;
        }

        private bool on_tick_callback (Gtk.Widget widget, Gdk.FrameClock clock) {
            if (_rotate_cover && !_fullscreen_mode) {
                var now = get_monotonic_time ();
                var elapsed = (now - _tick_last_time) / 1e6;
                var angle = elapsed * _degrees_per_second;
                _matrix_paintable.rotation += angle;
                _tick_last_time = now;
            }
            if (_show_peak) {
                var peak = _app.player.peak;
                _play_bar.peak = peak;
            }
            return true;
        }

        private void show_popover_menu (Gtk.Widget widget, double x, double y) {
            if (_app.current_music != null) {
                var menu = create_music_action_menu ();
                var popover = create_popover_menu (menu, x, y);
                popover.set_parent (widget);
                popover.popup ();
            }
        }

        private void update_cover_paintables (Music? music, Gdk.Paintable? paintable) {
            _round_paintable = new RoundPaintable (paintable);
            _round_paintable.ratio = _rotate_cover && !_fullscreen_mode ? 0.5 : 0.05;
            _round_paintable.queue_draw.connect (() => {
                music_cover.queue_draw ();
                _fullscreen_cover.queue_draw ();
            });
            _matrix_paintable = new MatrixPaintable (_round_paintable);
            _matrix_paintable.queue_draw.connect (() => {
                music_cover.queue_draw ();
                _fullscreen_cover.queue_draw ();
            });
            _crossfade_paintable.paintable = _matrix_paintable;
            cover_changed (music, _crossfade_paintable);
        }

        private void update_initial_label (string uri) {
            var dir_name = Uri.escape_string (get_display_name (uri));
            var link = @"<a href=\"change_dir\">$dir_name</a>";
            initial_label.set_markup (_("Drag and drop music files here,\nor change music location: ") + link);
        }

        private async void load_lyrics (Music music, Cancellable cancellable) {
            var lines = yield _lyrics_provider.load_local_lrc (music, cancellable);
            if (!is_current_lyrics_request (music, cancellable))
                return;
            if (lines != null) {
                _lyrics_view.set_lyrics ((!) lines);
                return;
            }

            if (_current_duration_seconds > 0) {
                load_online_lyrics.begin (music, cancellable);
                return;
            }

            _lyrics_duration_wait_handle = Timeout.add (1200, () => {
                _lyrics_duration_wait_handle = 0;
                if (is_current_lyrics_request (music, cancellable))
                    load_online_lyrics.begin (music, cancellable);
                return false;
            });
        }

        private async void load_online_lyrics (Music music, Cancellable cancellable) {
            if (_online_lyrics_loading) {
                if (_lyrics_request_duration_seconds <= 0
                        && _current_duration_seconds > 0)
                    _lyrics_retry_when_duration_ready = true;
                return;
            }

            var request_duration_seconds = _current_duration_seconds;
            _online_lyrics_loading = true;
            _lyrics_request_duration_seconds = request_duration_seconds;
            var lines = yield _lyrics_provider.fetch_online (
                music, request_duration_seconds, cancellable);
            if (!is_current_lyrics_request (music, cancellable))
                return;

            _online_lyrics_loading = false;
            _lyrics_request_duration_seconds = 0;
            if (lines != null) {
                _lyrics_retry_when_duration_ready = false;
                _lyrics_view.set_lyrics ((!) lines);
            } else if (request_duration_seconds <= 0
                    && _current_duration_seconds > 0) {
                _lyrics_retry_when_duration_ready = false;
                load_online_lyrics.begin (music, cancellable);
            } else {
                _lyrics_retry_when_duration_ready = request_duration_seconds <= 0;
                _lyrics_view.set_no_lyrics ();
            }
        }

        private bool is_current_lyrics_request (Music music, Cancellable cancellable) {
            return !cancellable.is_cancelled ()
                && cancellable == _lyrics_cancellable
                && music == _app.current_music;
        }

        private void cancel_lyrics_load () {
            _lyrics_cancellable?.cancel ();
            _lyrics_cancellable = null;
            _online_lyrics_loading = false;
            _lyrics_retry_when_duration_ready = false;
            _lyrics_request_duration_seconds = 0;
            if (_lyrics_duration_wait_handle != 0) {
                Source.remove (_lyrics_duration_wait_handle);
                _lyrics_duration_wait_handle = 0;
            }
        }
    }
}
