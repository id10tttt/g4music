namespace G4 {

    public class LyricsView : Gtk.Box {
        private const int64 MANUAL_SCROLL_PAUSE_US = 5 * 1000 * 1000;
        private const int FOCUSED_LINE_COUNT = 5;
        private const int MIN_LINE_HEIGHT = 52;

        private Gtk.ScrolledWindow _scroll;
        private Gtk.Box _lyrics_box;
        private Gtk.Label _status_label;
        private GenericArray<LyricLine> _lines = new GenericArray<LyricLine> ();
        private Gtk.Label[] _labels = {};
        private int _current_index = -1;
        private int64 _manual_scroll_until = 0;
        private uint _resume_scroll_handle = 0;
        private Adw.Animation? _scroll_animation = null;

        public LyricsView () {
            orientation = Gtk.Orientation.VERTICAL;
            hexpand = true;
            add_css_class ("lyrics-view");

            _lyrics_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
            _lyrics_box.halign = Gtk.Align.FILL;
            _lyrics_box.hexpand = true;
            _lyrics_box.margin_top = 32;
            _lyrics_box.margin_bottom = 48;
            _lyrics_box.margin_start = 24;
            _lyrics_box.margin_end = 24;

            _status_label = new Gtk.Label ("");
            _status_label.halign = Gtk.Align.CENTER;
            _status_label.valign = Gtk.Align.CENTER;
            _status_label.vexpand = true;
            _status_label.wrap = true;
            _status_label.justify = Gtk.Justification.CENTER;
            _status_label.add_css_class ("dim-label");

            var viewport = new Gtk.Viewport (null, null);
            viewport.hexpand = true;
            viewport.scroll_to_focus = false;
            viewport.child = _lyrics_box;

            _scroll = new Gtk.ScrolledWindow ();
            _scroll.hexpand = true;
            _scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
            _scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
            _scroll.vexpand = true;
            _scroll.child = viewport;
            append (_scroll);
            _scroll.notify["height"].connect (update_line_layout);

            var scroll_controller = new Gtk.EventControllerScroll (
                Gtk.EventControllerScrollFlags.BOTH_AXES);
            scroll_controller.scroll.connect ((delta_x, delta_y) => {
                pause_auto_scroll ();
                return false;
            });
            _scroll.add_controller (scroll_controller);

            var pointer_controller = new Gtk.GestureClick ();
            pointer_controller.pressed.connect (() => pause_auto_scroll ());
            _scroll.add_controller (pointer_controller);
        }

        public void set_loading () {
            clear_labels ();
            _status_label.label = _("Loading lyrics…");
            _lyrics_box.append (_status_label);
        }

        public void set_no_lyrics () {
            clear_labels ();
            _status_label.label = _("No lyrics found");
            _lyrics_box.append (_status_label);
        }

        public void set_lyrics (GenericArray<LyricLine> lines) {
            clear_labels ();
            _lines = lines;
            if (lines.length == 0) {
                set_no_lyrics ();
                return;
            }

            _labels = new Gtk.Label[lines.length];
            for (var index = 0; index < lines.length; index++) {
                var text = lines[index].text;
                var label = new Gtk.Label (text.length > 0 ? text : "  ·  ");
                // 标签必须占满歌词栏，再由 xalign 负责文字居中；否则 GTK
                // 会按可换行标签的最小宽度分配空间，造成英文逐字换行。
                label.halign = Gtk.Align.FILL;
                label.hexpand = true;
                label.xalign = 0.5f;
                label.wrap = true;
                label.wrap_mode = Pango.WrapMode.WORD_CHAR;
                label.justify = Gtk.Justification.CENTER;
                label.selectable = false;
                label.add_css_class ("lyrics-line");
                _lyrics_box.append (label);
                _labels[index] = label;
            }
            _scroll.vadjustment.value = 0;
            update_line_layout ();
        }

        /**
         * 根据毫秒位置更新当前歌词，返回高亮行是否发生变化。
         */
        public bool update_position (int64 position_ms) {
            if (_lines.length == 0 || _labels.length == 0)
                return false;

            int lower = 0;
            int upper = _lines.length - 1;
            int new_index = -1;
            while (lower <= upper) {
                var middle = (lower + upper) / 2;
                if (_lines[middle].time_ms <= position_ms) {
                    new_index = middle;
                    lower = middle + 1;
                } else {
                    upper = middle - 1;
                }
            }

            if (new_index == _current_index)
                return false;
            _current_index = new_index;
            if (_current_index >= 0 && _current_index < _labels.length) {
                update_line_styles ();
                if (get_monotonic_time () >= _manual_scroll_until)
                    scroll_to_label (_labels[_current_index]);
            } else {
                update_line_styles ();
            }
            return true;
        }

        private void pause_auto_scroll () {
            _manual_scroll_until = get_monotonic_time () + MANUAL_SCROLL_PAUSE_US;
            _scroll_animation?.pause ();
            _scroll_animation = null;
            if (_resume_scroll_handle != 0)
                Source.remove (_resume_scroll_handle);
            _resume_scroll_handle = Timeout.add (5000, () => {
                _resume_scroll_handle = 0;
                _manual_scroll_until = 0;
                if (_current_index >= 0 && _current_index < _labels.length)
                    scroll_to_label (_labels[_current_index]);
                return false;
            });
        }

        private void clear_labels () {
            _labels = {};
            _lines = new GenericArray<LyricLine> ();
            _current_index = -1;
            _manual_scroll_until = 0;
            if (_resume_scroll_handle != 0) {
                Source.remove (_resume_scroll_handle);
                _resume_scroll_handle = 0;
            }
            _scroll_animation?.pause ();
            _scroll_animation = null;
            _lyrics_box.margin_top = 32;
            _lyrics_box.margin_bottom = 48;

            var child = _lyrics_box.get_first_child ();
            while (child != null) {
                var next = ((!) child).get_next_sibling ();
                _lyrics_box.remove ((!) child);
                child = next;
            }
        }

        /**
         * 根据歌词视口高度调整行距，使自动跟随时聚焦当前行前后各两行。
         */
        private void update_line_layout () {
            var viewport_height = _scroll.get_height ();
            if (_labels.length == 0 || viewport_height <= 0)
                return;

            var line_height = int.max (MIN_LINE_HEIGHT,
                viewport_height / FOCUSED_LINE_COUNT);
            var edge_margin = int.max (32, (viewport_height - line_height) / 2);
            _lyrics_box.margin_top = edge_margin;
            _lyrics_box.margin_bottom = edge_margin;
            foreach (var label in _labels)
                label.height_request = line_height;
        }

        /**
         * 按歌词与当前行的距离设置高亮和淡化层级。
         */
        private void update_line_styles () {
            for (var index = 0; index < _labels.length; index++) {
                var label = _labels[index];
                label.remove_css_class ("lyrics-current");
                label.remove_css_class ("lyrics-near");
                label.remove_css_class ("lyrics-far");

                var distance = (index - _current_index).abs ();
                if (_current_index >= 0 && distance == 0)
                    label.add_css_class ("lyrics-current");
                else if (_current_index >= 0 && distance == 1)
                    label.add_css_class ("lyrics-near");
                else if (_current_index >= 0 && distance == 2)
                    label.add_css_class ("lyrics-far");
            }
        }

        private void scroll_to_label (Gtk.Label label) {
            Graphene.Rect bounds;
            if (!label.compute_bounds (_lyrics_box, out bounds))
                return;

            var adjustment = _scroll.vadjustment;
            var target = (double) bounds.origin.y
                + (double) bounds.size.height / 2
                - (double) _scroll.get_height () / 2;
            target = target.clamp (
                adjustment.lower,
                double.max (adjustment.lower, adjustment.upper - adjustment.page_size));

            _scroll_animation?.pause ();
            var animation_target = new Adw.CallbackAnimationTarget (
                (value) => adjustment.value = value);
            var animation = new Adw.TimedAnimation (
                _scroll, adjustment.value, target, 380, animation_target);
            animation.easing = Adw.Easing.EASE_OUT_CUBIC;
            _scroll_animation = animation;
            animation.play ();
        }
    }
}
