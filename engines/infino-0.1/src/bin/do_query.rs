//! Serve count / top-k queries against a persisted infino supertable.
//!
//! Reads `COMMAND\t<lucene-query>` lines from stdin and prints one result
//! line per query (stdout is a LineWriter, so each newline flushes).
//!
//! Supported: COUNT, TOP_10/100/1000, TOP_{1,5,10,100,1000}_COUNT.
//! Phrase queries, `*_FF` (fast-field ordering) and UNOPTIMIZED_COUNT are
//! answered "UNSUPPORTED" — see README.md.

use std::env;
use std::io::{self, BufRead};
use std::sync::Arc;

use infino::storage::{LocalFsStorageProvider, StorageProvider};
use infino::superfile::fts::reader::BoolMode;
use infino::supertable::Supertable;
use infino::supertable::reader_cache::{InMemoryReaderCache, SuperfileReaderCache};

use infino_bench::COLUMN;

fn main() {
    let args: Vec<String> = env::args().collect();
    let storage: Arc<dyn StorageProvider> =
        Arc::new(LocalFsStorageProvider::new(&args[1]).expect("open local storage"));

    // Inject our own in-memory reader tier. After open we preload every
    // segment into it, so the query path resolves readers SYNCHRONOUSLY from
    // tier-1 (`store.reader`) and never touches the async disk-cache path —
    // no per-query tokio runtime build on the rayon fan-out workers.
    let store: Arc<dyn SuperfileReaderCache> = Arc::new(InMemoryReaderCache::new());
    let opts = infino_bench::options(Arc::clone(&storage)).with_store(Arc::clone(&store));

    // Supertable::open is sync (bridges internally to async storage I/O).
    // We still need a runtime for the preload loop below.
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    let st = Supertable::open(opts).expect("open supertable");
    let reader = st.reader();

    // Preload all segments into the in-memory tier.
    let uris: Vec<_> = reader.manifest().superfiles.iter().map(|e| e.uri).collect();
    eprintln!("preloading {} segments into memory", uris.len());
    rt.block_on(async {
        for uri in uris {
            let path = uri.storage_path();
            let (bytes, _meta) = storage.get(&path).await.expect("fetch segment bytes");
            store.insert(uri, bytes).expect("insert segment into store");
        }
    });

    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = line.expect("read line");
        let mut parts = line.splitn(2, '\t');
        let command = parts.next().unwrap_or("");
        let query = parts.next().unwrap_or("");

        // UNSUPPORTED: phrase queries ("a b") — no positional postings.
        // Negation (-term) is now supported natively by infino.
        if query.contains('"') {
            println!("UNSUPPORTED");
            continue;
        }

        let mode = query_mode(query);

        let result = match command {
            _ if query.split_whitespace().all(|t| t.starts_with('-') || t.trim().is_empty()) => {
                // negation-only: no positive terms to rank
                Ok(0usize)
            }
            _ if query.trim().is_empty() => Ok(0usize),
            "TOP_10" | "TOP_100" | "TOP_1000" => reader
                .bm25_search(COLUMN, query, top_k(command), mode, None)
                .map(|_| 1),
            // COUNT / *_COUNT: correct but UNOPTIMIZED — infino has no dedicated
            // count path, so we run a full unpruned search and count the hits.
            // Included so the comparison has real latency numbers (expect infino
            // to lose here vs engines with a count-only collector).
            "COUNT" | "TOP_1_COUNT" | "TOP_5_COUNT" | "TOP_10_COUNT"
            | "TOP_100_COUNT" | "TOP_1000_COUNT" => reader
                .bm25_search(COLUMN, query, usize::MAX, mode, None)
                .map(|v| v.len()),
            _ => {
                println!("UNSUPPORTED");
                continue;
            }
        };
        match result {
            Ok(count) => println!("{count}"),
            Err(e) => {
                eprintln!("search error for {command:?} {query:?}: {e}");
                println!("0");
            }
        }
    }
}

fn top_k(command: &str) -> usize {
    match command {
        "TOP_10" => 10,
        "TOP_100" => 100,
        "TOP_1000" => 1000,
        _ => 10,
    }
}

/// Determine BoolMode from the query. `+a +b` (all positive terms required) → AND;
/// anything else → OR. `-term` tokens are negations and excluded from the mode check.
/// The raw query string is passed to infino as-is; its tokenizer handles `+`/`-` stripping.
fn query_mode(query: &str) -> BoolMode {
    let positives: Vec<&str> = query
        .split_whitespace()
        .filter(|t| !t.starts_with('-'))
        .collect();
    if !positives.is_empty() && positives.iter().all(|t| t.starts_with('+')) {
        BoolMode::And
    } else {
        BoolMode::Or
    }
}
