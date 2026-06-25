CORPUS := $(shell pwd)/corpus.json
export

WIKI_SRC = "https://www.dropbox.com/s/wwnfnu441w1ec9p/wiki-articles.json.bz2"

COMMANDS ?= TOP_10 TOP_100 TOP_1000 TOP_100_COUNT COUNT

ENGINES ?= infino-0.1 tantivy-0.26 lucene-10.4.0
QUERIES ?= queries.txt
PORT ?= 8080
WARMUP_TIME ?= 60
NUM_ITER ?= 10

# turbopuffer's published snapshot we merge against (their `turbopuffer` column).
# fetch-tpuf refreshes this before bench runs; the static file is the fallback.
TPUF_RESULTS ?= data/turbopuffer-latest.json

help:
	@grep '^[^#[:space:]].*:' Makefile

all: index

corpus:
	@echo "--- Downloading $(WIKI_SRC) ---"
	@curl -# -L "$(WIKI_SRC)" | bunzip2 -c | python3 corpus_transform.py > $(CORPUS)

clean:
	@echo "--- Cleaning directories ---"
	@rm -fr results
	@for engine in $(ENGINES); do cd ${shell pwd}/engines/$$engine && make clean ; done

index:
	@echo "--- Indexing corpus ---"
	@for engine in $(ENGINES); do cd ${shell pwd}/engines/$$engine && make index ; done

fetch-tpuf:
	@python3 scripts/fetch_tpuf_latest.py

# Default benchmark = turbopuffer comparison: run infino/tantivy/lucene on
# turbopuffer's exact query set + the commands all three support, then merge
# turbopuffer's published column into results.json.
bench: QUERIES := queries-tpuf.txt
bench: COMMANDS := TOP_10 TOP_100 TOP_1000 COUNT
bench: fetch-tpuf
	@echo "--- Benchmarking (turbopuffer comparison: $(ENGINES)) ---"
	@rm -fr results && mkdir results
	@python3 src/client.py $(QUERIES) $(ENGINES)
	@echo "--- Merging turbopuffer published column ($(TPUF_RESULTS)) ---"
	@python3 scripts/merge_turbopuffer.py results.json $(TPUF_RESULTS) results.json

# Full standard benchmark = the 962-query set with the full command list.
# Outputs results-full.json so it doesn't collide with the tpuf results.json.
bench-full: QUERIES := queries-full.txt
bench-full: COMMANDS := TOP_10 TOP_100 TOP_1000 TOP_100_COUNT COUNT
bench-full:
	@echo "--- Benchmarking (full 962-query standard: $(ENGINES)) ---"
	@rm -fr results && mkdir results
	@python3 src/client.py $(QUERIES) $(ENGINES)
	@mv results.json results-full.json

compile:
	@echo "--- Compiling binaries ---"
	@for engine in $(ENGINES); do cd ${shell pwd}/engines/$$engine && make compile || exit 1; done

serve:
	@echo "--- Serving results ---"
	@cp results.json web/build/results.json
	@cd web/build && python3 -m http.server $(PORT)
