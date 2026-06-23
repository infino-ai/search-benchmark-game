# infino

[infino](https://github.com/infino-ai/infino) is a search-optimized
lakehouse format: one file is a valid Apache Parquet file with an embedded
BM25 full-text index baked in. This engine benchmarks infino's **supertable**
query path (manifest + per-segment fan-out) — the production query surface —
built as multiple segments and read fully in memory.

## Scope: benchmarked commands

| Command / query | Status | Reason |
|---|---|---|
| `TOP_10` / `TOP_100` / `TOP_1000` | ✅ benchmarked | ranked top-k with BlockMaxWAND / Block-Max-MaxScore pruning |
| union (`a b`) | ✅ | `BoolMode::Or` |
| intersection (`+a +b`) | ✅ | `BoolMode::And` |
| `COUNT`, `TOP_*_COUNT` | ⚠️ benchmarked (unoptimized) | no dedicated count path — runs full unpruned search and counts hits |
| negation (`-term`) | ❌ UNSUPPORTED | no NOT operator in the FTS API |
| phrase (`"a b"`) | ❌ UNSUPPORTED | no positional postings |
| `TOP_*_FF` | ❌ UNSUPPORTED | results are score-ordered only |

## Tokenization & scoring

infino's `AsciiLowerTokenizer`: split on any byte outside `[A-Za-z0-9]`,
ASCII-lowercase, no stemming — equivalent to whitespace splitting on the
pre-transformed corpus, matching Lucene's `StandardTokenizer` here. BM25 with
Lucene defaults (`k1 = 1.2`, `b = 0.75`) and Lucene-style IDF.

## Build & read

`build_index` streams JSON from stdin into a supertable with a multi-thread
writer pool and a 4 GiB auto-flush threshold, producing several segments with
bounded build memory (tuned for c7i.2xlarge / 16 GiB). After ingest, it calls
`optimize()` to compact all segments into one — matching the single-segment
shape that tantivy and Lucene produce, so query-path fan-out overhead is
equivalent. `do_query` opens the persisted supertable and preloads every
segment into an in-memory reader tier, so the query path is fully synchronous
— no per-query async/tokio overhead.
