//! Build a single-segment infino supertable from newline-delimited JSON.
//!
//! Each input line is `{"id": "...", "text": "...", "sort_field": <u64>}`.
//! Only `text` is indexed. Docs are buffered (auto-flush disabled) and a
//! single `commit()` at the end — on a 1-thread writer pool — produces
//! exactly one superfile segment, persisted to `<idx>/` via the local-FS
//! storage provider so `do_query` can reopen it in a separate process.
//!
//! NOTE: a single segment means the entire corpus is held in memory until
//! the final commit (the supertable write buffer does not spill). At full
//! Wikipedia scale this needs a large-RAM host.

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
    let st = Supertable::create(infino_bench::options(storage));
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
}

fn append(writer: &mut infino::supertable::SupertableWriter, schema: &Arc<arrow_schema::Schema>, buf: &mut Vec<String>) {
    let arr = LargeStringArray::from(buf.iter().map(String::as_str).collect::<Vec<_>>());
    let batch = RecordBatch::try_new(schema.clone(), vec![Arc::new(arr)]).expect("record batch");
    writer.append(&batch).expect("append batch");
    buf.clear();
}
