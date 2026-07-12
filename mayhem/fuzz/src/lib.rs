// Shim library over xsv's OWN source (included via #[path] — upstream src/ is not
// modified) so the in-process fuzz harness (fuzz_targets/xsv.rs) can drive the exact
// command code paths the CLI binary runs. 2015 edition, matching upstream: the cmd
// modules import crate-root items (`use CliResult;`, wout!/werr!/fail!), so this
// crate root mirrors those items from src/main.rs verbatim.

extern crate byteorder;
extern crate crossbeam_channel as channel;
extern crate csv;
extern crate csv_index;
extern crate docopt;
extern crate filetime;
extern crate num_cpus;
extern crate rand;
extern crate regex;
extern crate serde;
#[macro_use]
extern crate serde_derive;
extern crate stats;
extern crate tabwriter;
extern crate threadpool;

use std::fmt;
use std::io;

macro_rules! wout {
    ($($arg:tt)*) => ({
        use std::io::Write;
        (writeln!(&mut ::std::io::stdout(), $($arg)*)).unwrap();
    });
}

macro_rules! werr {
    ($($arg:tt)*) => ({
        use std::io::Write;
        (writeln!(&mut ::std::io::stderr(), $($arg)*)).unwrap();
    });
}

macro_rules! fail {
    ($e:expr) => (Err(::std::convert::From::from($e)));
}

#[path = "../../../src/cmd/mod.rs"]
pub mod cmd;
#[path = "../../../src/config.rs"]
pub mod config;
#[path = "../../../src/index.rs"]
pub mod index;
#[path = "../../../src/select.rs"]
pub mod select;
#[path = "../../../src/util.rs"]
pub mod util;

pub type CliResult<T> = Result<T, CliError>;

#[derive(Debug)]
pub enum CliError {
    Flag(docopt::Error),
    Csv(csv::Error),
    Io(io::Error),
    Other(String),
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match *self {
            CliError::Flag(ref e) => { e.fmt(f) }
            CliError::Csv(ref e) => { e.fmt(f) }
            CliError::Io(ref e) => { e.fmt(f) }
            CliError::Other(ref s) => { f.write_str(&**s) }
        }
    }
}

impl From<docopt::Error> for CliError {
    fn from(err: docopt::Error) -> CliError {
        CliError::Flag(err)
    }
}

impl From<csv::Error> for CliError {
    fn from(err: csv::Error) -> CliError {
        if !err.is_io_error() {
            return CliError::Csv(err);
        }
        match err.into_kind() {
            csv::ErrorKind::Io(v) => From::from(v),
            _ => unreachable!(),
        }
    }
}

impl From<io::Error> for CliError {
    fn from(err: io::Error) -> CliError {
        CliError::Io(err)
    }
}

impl From<String> for CliError {
    fn from(err: String) -> CliError {
        CliError::Other(err)
    }
}

impl<'a> From<&'a str> for CliError {
    fn from(err: &'a str) -> CliError {
        CliError::Other(err.to_owned())
    }
}

impl From<regex::Error> for CliError {
    fn from(err: regex::Error) -> CliError {
        CliError::Other(format!("{:?}", err))
    }
}
