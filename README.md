
# Welcome to Search Benchmark, the Game!

This repository is standardized benchmark for comparing the speed of various
aspects of search engine technologies.

The results are available at:

- **[full benchmark](https://infino-ai.github.io/search-benchmark-game/)** — 962-query standard set (infino, tantivy, lucene, iresearch), updated nightly. Also served at `/full`.
- **[turbopuffer comparison](https://infino-ai.github.io/search-benchmark-game/tpuf)** — infino vs tantivy vs lucene vs turbopuffer on turbopuffer's 31-query set, updated nightly
- **per-fork branch page** — `https://infino-ai.github.io/search-benchmark-game/<fork_user>/full`, the same full benchmark with the latest branch run from a public infino fork spliced in as an extra infino column. Produced by dispatching the nightly workflow with `infino_repo`/`infino_branch` inputs; each fork's page is overwritten by that fork's next run.

This benchmark is both
- **for users** to make it easy for users to compare different libraries
- **for library** developers to identify optimization opportunities by comparing
their implementation to other implementations.

Currently, the benchmark includes infino, tantivy, Lucene, and iresearch
(plus turbopuffer's published numbers on the `/tpuf` page).
It is reasonably simple to add another engine.

You are free to communicate about the results of this benchmark **in
a reasonable manner**.
For instance, twisting this benchmark in marketing material to claim that your search engine is 31x faster than Lucene,
because your product was 31x on one of the test is not tolerated. If this happens, the benchmark will publicly
host a wall of shame.
Bullshit claims about performance are a plague in the database world.


## The benchmark

Different search engine implementation are benched over different real-life tests.
The corpus used is the English wikipedia. Stemming is disabled. Queries have been derived
 from the [AOL query dataset](https://en.wikipedia.org/wiki/AOL_search_data_leak)
 (but do not contain any personal information).

Out of a random sample of query, we filtered queries that had at least two terms and yield at least 1 hit when searches as
a phrase query.

For each of these query, we then run them as :
- `intersection`
- `unions`
- `phrase queries`

with the following collection options :
- `COUNT` only count documents, no need to score them
- `TOP 10` : Identify the 10 documents with the best BM25 score.
- `TOP 10 + COUNT`: Identify the 10  documents with the best BM25 score, and count the matching documents.

We also reintroduced artificially a couple of term queries with different term frequencies.

All tests are run once in order to make sure that
- all of the data is loaded and in page cache
- Java's JIT already kicked in.

Test are run in a single thread.
Out of 10 runs, we only retain the best score, so Garbage Collection likely does not matter.

### Benchmark environment

The local results (infino, tantivy, lucene) were generated on:

| | |
|---|---|
| Instance | AWS **c7i.2xlarge** (8 vCPU, 16 GiB RAM), us-east-1 |
| CPU | Intel Xeon Platinum 8488C |
| OS | Amazon Linux 2023, kernel `6.1.148-173.267.amzn2023.x86_64` |
| Rust | 1.95.0 |
| JDK | Adoptium Temurin 21.0.8+9 |

The c7i.2xlarge was chosen specifically to match the instance type used by turbopuffer in their published benchmark.

### How turbopuffer numbers are sourced

We do not re-run turbopuffer ourselves — instead we take the numbers directly
from turbopuffer's own published benchmark snapshot
(`data/turbopuffer-2026-05-20.json`, sourced from
`turbopuffer.github.io/search-benchmark-game`).

After running infino, tantivy, and lucene locally, `scripts/merge_turbopuffer.py`
splices turbopuffer's per-query durations into our `results.json` for the
commands that appear in both files. Only the 31 queries in `queries-tpuf.txt`
(derived verbatim from the turbopuffer snapshot) are used for this comparison —
query alignment is verified by exact string match, so any drift is surfaced as
a warning.

### Apples-to-apples considerations

The comparison is **methodologically equivalent**:

| | infino / tantivy / lucene | turbopuffer |
|---|---|---|
| Hardware | AWS c7i.2xlarge, us-east-1 | AWS c7i.2xlarge (per their published benchmark) |
| Benchmark harness | subprocess stdin/stdout | local HTTP server on the same box |
| Latency measured | wall time including IPC overhead | wall time including localhost HTTP overhead |
| Query set | turbopuffer's exact 31 queries | same 31 queries |
| Commands compared | TOP_10, TOP_100, TOP_1000, COUNT | same |

Turbopuffer's benchmark engine starts a **local** turbopuffer server process
on the EC2 box and queries it via `http://localhost:3001` — no external network
call. All four engines (infino, tantivy, lucene, turbopuffer) run on the same
c7i.2xlarge hardware; the communication overhead difference (stdin/stdout vs
localhost HTTP) is negligible, so the comparison is apples-to-apples.

## Engine specific detail

### Lucene

- Query cache is disabled.
- GC should not influence the results as we pick the best out of 5 runs.
- The `-bp` variant implements document reordering via the bipartite graph partitioning algorithm, also called recursive graph bisection.

### Tantivy

- Tantivy returns slightly more results because its tokenizer handles apostrophes differently.
- Tantivy and Lucene both use BM25 and should return almost identical scores.

### infino-0.1

infino is benchmarked on its **optimized paths only**. Commands without a
first-class implementation return `UNSUPPORTED` rather than falling back to
a slower workaround — so every reported number reflects infino's actual engine.

| Command | Status |
|---|---|
| `TOP_10`, `TOP_100`, `TOP_1000` (union / intersection) | ✅ benchmarked |
| `COUNT`, `TOP_*_COUNT` | ✅ benchmarked — native count path (posting-list traversal, no scoring) |
| Mixed must/should (`+a b`) | ✅ benchmarked — native lucene `BooleanQuery` clause semantics (`+must`, bare should, `-must-not`) |
| Negation (`-term`) | ✅ benchmarked — native must-not exclusion |
| Phrase queries (`"a b"`) | ✅ benchmarked — exact adjacency over positional postings |
| `TOP_*_FILTER_%` | ❌ UNSUPPORTED — results are score-ordered only |

Tokenization: `AsciiLowerTokenizer` (split on non-alphanumeric, ASCII-lowercase, no stemming) — equivalent to Lucene's `StandardTokenizer` on this corpus. BM25 with Lucene defaults (`k1 = 1.2`, `b = 0.75`).

The index is built as multiple on-disk segments and then fully loaded into
memory before benchmarking begins, so the query path is synchronous with no
per-query I/O or async overhead.


# Reproducing

These instructions will get you a copy of the project up and running on your local machine.

### Prerequisites

The lucene benchmarks requires Java, the most recent version is recommended.
The tantivy benchmarks and benchmark driver code requires Cargo. This can be installed using [rustup](https://www.rustup.rs/).

### Installing

Clone this repo.

```
git clone git@github.com:tantivy-search/search-benchmark-game.git
```

## Running

Checkout the [Makefile](Makefile) for all available commands. You can adjust the `ENGINES` parameter for a different set of engines.

Run `make corpus` to download and unzip the corpus used in the benchmark.
```
make corpus
```

Run `make index` to create the indices for the engines.

```
make index
```

Run `make compile` to compile the query execution layer.
Run `make bench` to build the different project and run the benches.
This command may take more than 30mn.

```
make bench
```

The results are outputted in a `results.json` file.

You can then check your results out by running:

```
make serve
```

And open the following in your browser: [http://localhost:8080/](http://localhost:8080/)


# Adding another search engine

See `CONTRIBUTE.md`.
