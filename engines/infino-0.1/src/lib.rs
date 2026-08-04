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
use infino::supertable::manifest::list::PartitionStrategy;
use infino::supertable::{Consistency, SupertableOptions};

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

/// Number of writer-pool threads. A commit shards its buffered rows across
/// `min(pool_threads, rows)` builders, so this is the number of superfiles a
/// single commit produces.
///
/// Pinned to 1: one writer ⇒ one shard ⇒ one superfile per commit. Combined
/// with auto-flush disabled (`with_commit_threshold_size_mb(0)` below, so the
/// whole corpus is a single commit), the build yields exactly one superfile —
/// no post-ingest compaction needed. This matches tantivy/lucene's single
/// force-merged segment and keeps the query path a single-unit fan-out
/// (genuinely single-threaded).
pub fn writer_threads() -> usize {
    1
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
    .with_partition_strategy(PartitionStrategy::Hash {
        column: "_id".to_string(),
        n_buckets: 1,
    })
    .with_writer_pool(writer_pool)
    .with_reader_pool(reader_pool)
    // Snapshot read consistency: the bench index is built once and read many
    // times in-process, so pin the manifest at open and never pay the
    // per-query pointer re-check that the default BoundedStaleness policy does.
    .with_read_consistency(Consistency::Snapshot)
    // Disable auto-flush (0 = never flush on buffer size). The whole corpus is
    // buffered and written in a single commit, which — with `writer_threads = 1`
    // — produces exactly one superfile directly at ingest, so no compaction is
    // needed. (A non-zero threshold flushes mid-ingest, emitting one superfile
    // per flush round and forcing a compaction to re-merge them.)
    .with_commit_threshold_size_mb(0)
    .with_storage(storage)
}
