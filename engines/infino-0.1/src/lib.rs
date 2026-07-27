//! Shared configuration for the build and query binaries.
//!
//! `build_index` and `do_query` MUST construct byte-identical
//! `SupertableOptions` — the supertable stamps a digest of the options
//! into the manifest at commit time and verifies it on `open`. Centralizing
//! the schema / FTS column / tokenizer / pool config here guarantees they
//! agree.

use std::sync::Arc;

use arrow_schema::{DataType, Field, Schema};
use infino::storage::StorageProvider;
use infino::superfile::builder::FtsConfig;
use infino::superfile::fts::tokenize::AsciiLowerTokenizer;
use infino::supertable::SupertableOptions;

/// The single indexed full-text column.
pub const COLUMN: &str = "text";

/// User schema (the `_id` column is auto-injected by the supertable).
pub fn schema() -> Arc<Schema> {
    Arc::new(Schema::new(vec![Field::new(
        COLUMN,
        DataType::LargeUtf8,
        false,
    )]))
}

/// Number of writer-pool threads (also the number of segments produced per
/// commit, since a commit shards across `min(pool_threads, rows)`).
///
/// Tuned for c7i.2xlarge (8 vCPU, 16 GiB). Capped at 4: fewer threads → fewer
/// segments per commit (~12 total vs ~24 at 8) → less query-time fan-out, and
/// lower build peak memory (4 parallel shard builds instead of 8). Build is a
/// little slower but stays well within 16 GiB.
pub fn writer_threads() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
        .min(4)
}

/// Options shared by builder and reader.
///
/// Multi-threaded build: a multi-thread writer pool builds segments in
/// parallel, and a 1 GiB auto-flush threshold caps the in-memory write
/// buffer — so the corpus is committed in several rounds rather than held
/// whole in RAM. This produces multiple segments (the realistic supertable
/// shape) but builds fast and with bounded memory.
pub fn options(storage: Arc<dyn StorageProvider>) -> SupertableOptions {
    let writer_pool = Arc::new(
        rayon::ThreadPoolBuilder::new()
            .num_threads(writer_threads())
            .build()
            .expect("build writer pool"),
    );
    let reader_pool = Arc::new(
        rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .build()
            .expect("build reader pool"),
    );
    SupertableOptions::new(
        schema(),
        vec![FtsConfig {
            column: COLUMN.to_string(),
            // Token positions on: phrase queries are first-class.
            positions: true,
        }],
        vec![],
        Some(Arc::new(AsciiLowerTokenizer)),
    )
    .expect("valid supertable options")
    .with_writer_pool(writer_pool)
    .with_reader_pool(reader_pool)
    .with_commit_threshold_size_mb(4096)
    .with_storage(storage)
}
