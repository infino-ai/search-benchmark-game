//! Shared configuration for the build and query binaries.
//!
//! `build_index` and `do_query` MUST construct byte-identical
//! `SupertableOptions` — the supertable stamps a digest of the options
//! into the manifest at commit time and verifies it on `open`. Centralizing
//! the schema / FTS column / tokenizer / pool config here guarantees they
//! agree.

use std::collections::HashSet;
use std::sync::Arc;

use arrow_schema::{DataType, Field, Schema};
use infino::storage::StorageProvider;
use infino::superfile::builder::FtsConfig;
use infino::supertable::manifest::list::PartitionStrategy;
use infino::supertable::reader_cache::{DiskCacheConfig, DiskCacheStore};
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

/// Options shared by builder and reader.
///
/// The writer pool is the engine's default (`writer_threads: auto`): the
/// bench sets nothing, so the build runs the way the engine runs it. A
/// post-ingest `optimize` (see `build_index`) compacts every segment into
/// one superfile, so the pool width never reaches the query side.
///
/// Bounded-memory build: the writer pool builds segments in parallel and a
/// `with_commit_threshold_size_mb` auto-flush caps the in-memory write
/// buffer, so the corpus is committed in several rounds rather than held whole
/// in RAM. This emits multiple superfiles; `build_index`'s post-ingest
/// `optimize` compacts them into one.
pub fn options(storage: Arc<dyn StorageProvider>) -> SupertableOptions {
    let reader_pool = Arc::new(
        rayon::ThreadPoolBuilder::new()
            .num_threads(1)
            .build()
            .expect("build reader pool"),
    );

    let disk_cache = DiskCacheStore::new(
        Arc::clone(&storage),
        DiskCacheConfig {
            cache_root: std::env::temp_dir().join("infino-bench-disk-cache"),
            ..Default::default()
        },
        Arc::new(HashSet::new),
    )
    .expect("build disk cache");

    SupertableOptions::new(
        schema(),
        // Token positions on (phrase queries are first-class); the text is
        // index-only (stored(false)), matching how the other engines build
        // the SBG index — Lucene does not store the body either. The
        // default `standard` analyzer (UAX #29 + Unicode lowercase) is the
        // Lucene-parity tokenizer, same as the infino-0.11.17 engine.
        vec![FtsConfig::new(COLUMN).positions(true).stored(false)],
        vec![],
    )
    .expect("valid supertable options")
    .with_partition_strategy(PartitionStrategy::Hash {
        column: "_id".to_string(),
        n_buckets: 1,
    })
    .with_reader_pool(reader_pool)
    // Snapshot read consistency: the bench index is built once and read many
    // times in-process, so pin the manifest at open and never pay the
    // per-query pointer re-check that the default BoundedStaleness policy does.
    .with_read_consistency(Consistency::Snapshot)
    // Auto-flush every 4 GiB of buffered rows so each commit's peak memory
    // stays bounded (buffer + that chunk's index) instead of the whole corpus
    // at once. Ingest emits several superfiles; `build_index`'s post-ingest
    // `optimize` compacts them into one.
    .with_commit_threshold_size_mb(4096)
    .with_storage(storage)
    .with_disk_cache(disk_cache)
    // No table-level term index: `build_index` compacts the corpus to one
    // superfile, so there is nothing for the index to route between, and
    // its objects would only count against infino's index size on the
    // page. The other engines' single force-merged segments carry no such
    // index either.
    .with_term_index(false)
}
