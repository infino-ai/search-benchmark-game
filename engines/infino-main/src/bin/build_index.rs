//! Build an infino supertable from newline-delimited JSON, then compact it.
//!
//! Each input line is `{"id": "...", "text": "...", "sort_field": <u64>}`.
//! Only `text` is indexed. Docs are streamed in 50 k-doc batches; a 4 GiB
//! auto-flush threshold causes the writer to commit several segments
//! incrementally (bounded build memory). After ingest, `optimize()` compacts
//! all segments into one, matching the single-segment shape that tantivy and
//! Lucene produce — so query-path fan-out overhead is equivalent.

use std::env;
use std::io::{self, BufRead, BufReader};
use std::sync::Arc;
use std::sync::mpsc::sync_channel;
use std::thread;
use std::time::Duration;

use arrow_array::{LargeStringArray, RecordBatch};
use infino::storage::{LocalFsStorageProvider, StorageProvider};
use infino::supertable::Supertable;
use infino::{CompactionSettings, GcSettings, OptimizeOptions};
use serde::Deserialize;

/// Large enough that the entire Wikipedia BM25 index fits in one output segment.
const COMPACT_TARGET_MB: u64 = 8 * 1024;

const BATCH: usize = 50_000;

/// Read buffer in front of stdin: large reads off the corpus file, so the
/// producer thread spends its time on parsing rather than on syscalls.
const STDIN_BUFFER_BYTES: usize = 8 * 1024 * 1024;

#[derive(Deserialize)]
struct Doc {
    text: String,
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let storage: Arc<dyn StorageProvider> =
        Arc::new(LocalFsStorageProvider::new(&args[1]).expect("open local storage"));
    let st = Supertable::create(infino_bench::options(storage)).expect("create supertable");
    let mut writer = st.writer().expect("acquire writer");
    let schema = infino_bench::schema();

    // The corpus is read, parsed and turned into Arrow on its own thread,
    // the way the Lucene and iresearch harnesses hand parsed documents to
    // their indexers: the engine's append and commit never wait on stdin,
    // and stdin is never left idle while the engine builds. Two batches of
    // slack between the two threads.
    let (tx, rx) = sync_channel::<RecordBatch>(2);
    let producer_schema = Arc::clone(&schema);
    let producer = thread::spawn(move || {
        let mut buf: Vec<String> = Vec::with_capacity(BATCH);
        let stdin = io::stdin();
        let mut reader = BufReader::with_capacity(STDIN_BUFFER_BYTES, stdin.lock());
        let mut line = String::new();
        let flush = |buf: &mut Vec<String>| {
            let arr = LargeStringArray::from(buf.iter().map(String::as_str).collect::<Vec<_>>());
            let batch = RecordBatch::try_new(Arc::clone(&producer_schema), vec![Arc::new(arr)])
                .expect("record batch");
            buf.clear();
            tx.send(batch).expect("the appending thread is alive");
        };
        loop {
            line.clear();
            let n = reader.read_line(&mut line).expect("read line");
            if n == 0 {
                break;
            }
            if line.trim().is_empty() {
                continue;
            }
            let doc: Doc = serde_json::from_str(&line).expect("parse json");
            buf.push(doc.text);
            if buf.len() == BATCH {
                flush(&mut buf);
            }
        }
        if !buf.is_empty() {
            flush(&mut buf);
        }
    });

    let mut total: u64 = 0;
    for batch in rx {
        total += batch.num_rows() as u64;
        writer.append(&batch).expect("append batch");
        if total % 1_000_000 == 0 {
            eprintln!("{total}");
        }
    }
    producer.join().expect("producer thread");

    writer.commit().expect("commit");
    drop(writer);
    eprintln!("indexed {total} docs into the supertable");

    eprintln!("compacting…");
    st.optimize(
        &OptimizeOptions::compact(CompactionSettings {
            target_superfile_size_mb: COMPACT_TARGET_MB,
            min_fill_percent: 1,
            max_merge_input_mb: COMPACT_TARGET_MB + 2048,
            ..Default::default()
        })
        .with_gc(GcSettings {
            safety_gap: Duration::ZERO,
        }),
    )
    .expect("optimize");
    eprintln!("compact done");

    // Report how many superfiles the table compacted to. The query path fans
    // out one work unit per superfile, so single-threaded latency (and the
    // fairness of the comparison against tantivy/lucene's single force-merged
    // segment) hinges on this being 1.
    let reader = st.reader().expect("open reader after compact");
    let n_superfiles = reader.manifest().superfiles.len();
    eprintln!("SUPERFILE_COUNT after compact: {n_superfiles}");
    if n_superfiles != 1 {
        // Fail hard: if compaction didn't reach a single superfile (e.g. it ran
        // out of memory and left the ingest segments in place), the query path
        // would fan out over several units single-threaded and publish a
        // silently-degraded, unfair infino result. Better to fail the build
        // (and the whole run, via the Makefile's `|| exit 1`) than bench it.
        eprintln!(
            "ERROR: expected a single compacted superfile, got {n_superfiles} — \
             refusing to bench a multi-superfile index (it would fan out \
             {n_superfiles} units single-threaded). Failing the build."
        );
        std::process::exit(1);
    }
}
