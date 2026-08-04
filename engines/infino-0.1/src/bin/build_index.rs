//! Build an infino supertable from newline-delimited JSON as a single superfile.
//!
//! Each input line is `{"id": "...", "text": "...", "sort_field": <u64>}`.
//! Only `text` is indexed. Docs are streamed in 50 k-doc batches and written
//! in one commit (auto-flush is disabled and the writer pool is a single
//! thread — see `infino_bench::options`), so ingest emits exactly one
//! superfile. That matches the single force-merged segment tantivy and Lucene
//! produce, so no post-ingest compaction is needed and the query path is a
//! single-unit fan-out.

use std::env;
use std::io::{self, BufRead};
use std::sync::Arc;

use arrow_array::{LargeStringArray, RecordBatch};
use infino::storage::{LocalFsStorageProvider, StorageProvider};
use infino::supertable::Supertable;
use serde::Deserialize;

const BATCH: usize = 50_000;

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

    let mut buf: Vec<String> = Vec::with_capacity(BATCH);
    let mut total: u64 = 0;
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let line = line.expect("read line");
        if line.trim().is_empty() {
            continue;
        }
        let doc: Doc = serde_json::from_str(&line).expect("parse json");
        buf.push(doc.text);
        if buf.len() == BATCH {
            total += buf.len() as u64;
            append(&mut writer, &schema, &mut buf);
            if total % 1_000_000 == 0 {
                eprintln!("{total}");
            }
        }
    }
    if !buf.is_empty() {
        total += buf.len() as u64;
        append(&mut writer, &schema, &mut buf);
    }

    writer.commit().expect("commit");
    drop(writer);
    eprintln!("indexed {total} docs into the supertable");

    // Report how many superfiles ingest produced. With a single-thread writer
    // pool and auto-flush disabled the whole corpus commits as one superfile,
    // so this must be 1 — the query path fans out one work unit per superfile,
    // and single-threaded fairness against tantivy/lucene's single segment
    // hinges on it. If it prints > 1, the build split (e.g. auto-flush fired)
    // and the query path would fan out over several units single-threaded.
    let reader = st.reader().expect("open reader after build");
    let n_superfiles = reader.manifest().superfiles.len();
    eprintln!("SUPERFILE_COUNT after build: {n_superfiles}");
    if n_superfiles != 1 {
        // Fail hard: a multi-superfile index fans out single-threaded and would
        // publish a silently-degraded, unfair infino result. Better to fail the
        // build (and the whole run) than bench a bad index.
        eprintln!(
            "ERROR: expected a single superfile, got {n_superfiles} — \
             refusing to bench a multi-superfile index (it would fan out \
             {n_superfiles} units single-threaded). Failing the build."
        );
        std::process::exit(1);
    }
}

fn append(
    writer: &mut infino::supertable::SupertableWriter,
    schema: &Arc<arrow_schema::Schema>,
    buf: &mut Vec<String>,
) {
    let arr = LargeStringArray::from(buf.iter().map(String::as_str).collect::<Vec<_>>());
    let batch = RecordBatch::try_new(schema.clone(), vec![Arc::new(arr)]).expect("record batch");
    writer.append(&batch).expect("append batch");
    buf.clear();
}
