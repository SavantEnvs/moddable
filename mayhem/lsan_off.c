/* Build-time LeakSanitizer opt-out, linked into every ASan binary (xst and xst-standalone).
 * Leaks are not the bug class this target is fuzzed for; ASan memory-corruption checks stay on.
 * All runtime ASan/LSan/libFuzzer options are left to the fuzzing platform. */
int __lsan_is_turned_off(void) { return 1; }
