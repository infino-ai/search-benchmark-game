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

    // `Supertable::open` and segment fetch are async; search is sync. One
    // runtime drives open + preload, then we leave it.
    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    let st = rt
        .block_on(Supertable::open(opts))
        .expect("open supertable");
    let reader = st.reader();

    // Preload all segments into the in-memory tier.
    let uris: Vec<_> = reader.manifest().superfiles.iter().map(|e| e.uri).collect();
    eprintln!("preloading {} segments into memory", uris.len());
    rt.block_on(async {
        for uri in uris {
            let path = format!("data/seg-{}.sf", uri.0);
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

        // UNSUPPORTED — infino has no optimized path for these, so reporting
        // a number would misrepresent the engine rather than compare fairly:
        //   - phrase ("a b")     : no positional postings.
        //   - negation (-term)   : no NOT operator in the FTS API.
        //   - COUNT / *_COUNT    : no dedicated count; would ride a full
        //                          unpruned scoring search.
        // Only the pruned, ranked top-k path (TOP_10/100/1000) is benchmarked.
        if query.contains('"') || query.split_whitespace().any(|t| t.starts_with('-')) {
            println!("UNSUPPORTED");
            continue;
        }

        let (cleaned, mode) = parse_query(query);

        let result = match command {
            _ if cleaned.is_empty() => Ok(0usize),
            "TOP_10" | "TOP_100" | "TOP_1000" => reader
                .bm25_search(COLUMN, &cleaned, top_k(command), mode)
                .map(|_| 1),
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

/// Split into `(cleaned_query_string, mode)`. `+a +b` (all required) -> AND;
/// `a b` -> OR. The `+`/`-` prefixes are stripped; the supertable tokenizes
/// the returned string itself (ascii_lower), so query and corpus tokenization
/// match exactly.
fn parse_query(query: &str) -> (String, BoolMode) {
    let raw: Vec<&str> = query.split_whitespace().collect();
    let all_required = !raw.is_empty() && raw.iter().all(|t| t.starts_with('+'));
    let mode = if all_required {
        BoolMode::And
    } else {
        BoolMode::Or
    };
    let cleaned = raw
        .iter()
        .map(|t| t.trim_start_matches(['+', '-']))
        .collect::<Vec<_>>()
        .join(" ");
    (cleaned, mode)
}
