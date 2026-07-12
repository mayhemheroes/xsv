// In-process libFuzzer harness for the legacy `xsv` Mayhem target: drives the SAME
// code path as the original raw-CLI integration (`xsv stats --everything <input>`)
// through xsv's own command entry point (cmd::stats::run — docopt parse, Config,
// CSV reader, per-column type inference + full statistics), converted in-process
// per the unfuzzable-raw-CLI rule (the raw CLI records 0 edges on current Mayhem
// infra; see mayhem/build.sh). xsv's source is pulled in via the xsv_shim lib.
//
// stats reads its input from a path (or stdin), so each iteration writes the fuzz
// input to one fixed per-process scratch file — the parsing/statistics code under
// test is exercised in-process. --jobs 1 keeps it single-threaded/deterministic.
#![no_main]

#[macro_use]
extern crate libfuzzer_sys;
extern crate xsv_shim;

use std::io::Write;

fuzz_target!(|data: &[u8]| {
    let mut path = std::env::temp_dir();
    path.push(format!("xsv-fuzz-{}.csv", std::process::id()));
    {
        let mut f = std::fs::File::create(&path).expect("scratch file");
        f.write_all(data).expect("scratch write");
    }
    let p = path.to_str().expect("utf-8 tmp path");
    let _ = xsv_shim::cmd::stats::run(&["xsv", "stats", "--everything", "--jobs", "1", p]);
});
