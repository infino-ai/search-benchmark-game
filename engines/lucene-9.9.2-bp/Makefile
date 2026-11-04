clean:
	@rm -fr idx

serve:
	@java -XX:+UseParallelGC -cp "${shell pwd}/../lucene-9.9.2/build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:${shell pwd}/../lucene-9.9.2/build/dependencies/*" DoQuery idx

index: idx

compile:
	cd ${shell pwd}/../lucene-9.9.2 && make compile

${shell pwd}/../lucene-9.9.2/build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:
	@$(MAKE) --no-print-directory compile

# The index depends on the jar, not on `compile`: `compile` always runs a
# clean gradle build, and with it as a prerequisite every `make index` rebuilt
# the engine first, inside the timed index build. The jar is built once, by
# `make compile` or here when it is missing, and reused afterwards.
idx: ${shell pwd}/../lucene-9.9.2/build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar
	cd ${shell pwd}/../lucene-9.9.2 && make index
	@echo "--- Reordering index with Lucene 9.9.2 ---"
	@java -server -cp "${shell pwd}/../lucene-9.9.2/build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:${shell pwd}/../lucene-9.9.2/build/dependencies/*" ReorderIndex ${shell pwd}/../lucene-9.9.2/idx idx
