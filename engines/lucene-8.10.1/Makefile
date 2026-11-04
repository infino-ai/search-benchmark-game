clean:
	@echo "--- Cleaning Lucene 8.10.1 ---"
	@rm -fr idx
	@rm -fr build

compile: build

serve:
	@java -XX:+UseParallelGC -cp build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT-all.jar DoQuery idx

index: idx

build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT-all.jar:
	@$(MAKE) --no-print-directory build

build:
	@echo "--- Building Lucene 8.4.0 ---"
	@gradle clean shadowJar

# The index depends on the jar, not on `compile`: `compile` always runs a
# clean gradle build, and with it as a prerequisite every `make index` rebuilt
# the engine first, inside the timed index build. The jar is built once, by
# `make compile` or here when it is missing, and reused afterwards.
idx: build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT-all.jar
	@echo "--- Indexing Lucene 8.4.0 ---"
	java -server -cp build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT-all.jar BuildIndex idx < $(CORPUS)
