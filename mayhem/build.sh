#!/usr/bin/env bash
#
# xsv/mayhem/build.sh — build the `xsv` Mayhem target as an IN-PROCESS libFuzzer
# harness (cargo-fuzz + ASan, the fleet's proven Rust route), plus the project's
# own test suite with normal flags so mayhem/test.sh only RUNS it.
#
# The harness (mayhem/fuzz/fuzz_targets/xsv.rs) drives xsv's own command entry
# point — cmd::stats::run with --everything, via a shim lib that #[path]-includes
# xsv's own src/ modules (mayhem/fuzz/src/lib.rs; upstream stays untouched) —
# i.e. the SAME `xsv stats --everything <input>` code path as the original raw-CLI
# integration, and keeps the legacy target name `xsv` (run-history parity).
#
# WHY the raw CLI was converted in-process (unfuzzable-raw-CLI rule) — every raw-CLI
# form was tried against Mayhem's current infra and cannot record coverage:
#   - plain CLI binary (exact original form): launches + fuzzes, but 0 edges —
#     run #19 (the old 109k-edge run #16 predates the current infra).
#   - ASan CLI binary: launch smoke test timeout → run #17 failed, 0 edges.
#   - cargo-afl CLI binary (afl: true): SIGILL at launch under Mayhem's runner →
#     run #18 failed, 0 edges — despite fuzzing cleanly under local AFL++ 4.21c.
# In-process libFuzzer+ASan is what every healthy Rust target in this fleet uses.
#
# We produce:
#   /mayhem/xsv — libFuzzer+ASan harness over cmd::stats::run (DWARF-3)
#   the cargo test binaries (normal flags, cached in target/) for mayhem/test.sh
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
#   - This FIRST build (in CI, online) populates the cargo registry under $CARGO_HOME.
#   - The PATCH re-run resolves crates from that cache. The rlenv runtime exports
#     CARGO_NET_OFFLINE=true for the re-run so cargo won't refresh the crates.io
#     index — so do NOT hard-code `--offline` here.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Debug-info contract (SPEC §6.2 item 10): DWARF <= 3 on the fuzz binary (Mayhem
# triage cannot read DWARF >= 4). Overridable via $RUST_DEBUG_FLAGS (the rust arm
# of the DEBUG_FLAGS contract verify-repo checks).
: "${RUST_DEBUG_FLAGS:=-Cdebuginfo=2 -Zdwarf-version=3}"
# Sanitizer contract: $SANITIZER_FLAGS comes from the base ENV (clang syntax); rustc
# takes -Zsanitizer instead, so map non-empty -> ASan and an EXPLICIT empty -> none.
SANITIZER_FLAGS="${SANITIZER_FLAGS=-fsanitize=address}"
RUST_SANITIZER=""
[ -n "$SANITIZER_FLAGS" ] && RUST_SANITIZER="-Zsanitizer=address"
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing ${RUST_SANITIZER} ${RUST_DEBUG_FLAGS} -Cforce-frame-pointers"

# DWARF<4 first-CU anchor (netnew-fleet-playbook §6): rustc's prebuilt ASan runtime
# ships DWARF-5 and would land at .debug_info offset 0. Link a clang -gdwarf-3
# anchor object FIRST via a -Clinker cc-wrapper so the first CU is DWARF-3.
ANCHOR_DIR=/tmp/mayhem-dwarf3
mkdir -p "$ANCHOR_DIR"
echo 'int mayhem_dwarf3_anchor(void) { return 0; }' > "$ANCHOR_DIR/anchor.c"
clang -c -gdwarf-3 -O2 -o "$ANCHOR_DIR/anchor.o" "$ANCHOR_DIR/anchor.c"
printf '#!/usr/bin/env bash\nexec cc %s "$@"\n' "$ANCHOR_DIR/anchor.o" > "$ANCHOR_DIR/cc-wrap.sh"
chmod +x "$ANCHOR_DIR/cc-wrap.sh"
export RUSTFLAGS="$RUSTFLAGS -Clinker=$ANCHOR_DIR/cc-wrap.sh"

FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
# --debug-assertions: overflow/bounds checks become panics → halting bugs libFuzzer
# catches. Uses the image's DEFAULT toolchain (the Dockerfile pinned it).
cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions xsv
bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/xsv"
[ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
cp "$bin" /mayhem/xsv
echo "built /mayhem/xsv"

# Build the project TEST suite with the project's NORMAL flags (a clean,
# non-sanitized build) so mayhem/test.sh only RUNS it. The integration suite
# (tests/tests.rs) drives the xsv binary from the same target dir, so build it too.
# NB: -Cdebug-assertions=off for the TEST build only — modern rustc's debug-assertion
# UB checks abort inside the vintage rand_core 0.2 dependency (misaligned read in
# BlockRng, a dep bug that predates the check); upstream's own toolchain never ran
# these checks. test.sh uses the same flags so the cache is reused (no recompile).
echo "=== cargo test --no-run (normal flags) ==="
env RUSTFLAGS="-Cdebug-assertions=off" cargo test --no-run
env RUSTFLAGS="-Cdebug-assertions=off" cargo build   # tests exec target/debug/xsv

echo "build.sh complete"
