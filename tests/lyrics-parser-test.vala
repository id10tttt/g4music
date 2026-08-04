using G4;

private void test_multiple_timestamps () {
    var lines = parse_lrc ("[00:01.00][00:02.50]Hello\n");
    assert (lines.length == 2);
    assert (lines[0].time_ms == 1000);
    assert (lines[0].text == "Hello");
    assert (lines[1].time_ms == 2500);
    assert (lines[1].text == "Hello");
}

private void test_positive_offset () {
    var lines = parse_lrc ("[00:01.00]First\n[offset:+500]\n[00:02.00]Second\n");
    assert (lines.length == 2);
    assert (lines[0].time_ms == 1500);
    assert (lines[1].time_ms == 2500);
}

private void test_negative_offset_is_clamped () {
    var lines = parse_lrc ("[offset:-1500]\n[00:01.00]First\n[00:02.00]Second\n");
    assert (lines.length == 2);
    assert (lines[0].time_ms == 0);
    assert (lines[1].time_ms == 500);
}

private void test_fraction_and_invalid_time () {
    var lines = parse_lrc ("[00:01.1234]Valid\n[00:60.00]Invalid\n");
    assert (lines.length == 1);
    assert (lines[0].time_ms == 1123);
    assert (lines[0].text == "Valid");
}

private void test_same_timestamp_is_merged () {
    var lines = parse_lrc ("[00:01.00]Original\n[00:01.00]Translation\n");
    assert (lines.length == 1);
    assert (lines[0].text == "Original\nTranslation");
}

public int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/lyrics/multiple-timestamps", test_multiple_timestamps);
    Test.add_func ("/lyrics/positive-offset", test_positive_offset);
    Test.add_func ("/lyrics/negative-offset", test_negative_offset_is_clamped);
    Test.add_func ("/lyrics/fraction-and-invalid-time", test_fraction_and_invalid_time);
    Test.add_func ("/lyrics/merge-same-timestamp", test_same_timestamp_is_merged);
    return Test.run ();
}
