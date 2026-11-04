clean:
	@echo "--- Cleaning Lucene 10.5.0 (BP variant) ---"
	@rm -fr idx
	@rm -fr build

serve:
	@java -XX:+UseParallelGC --add-modules jdk.incubator.vector --enable-native-access=ALL-UNNAMED -cp "build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:build/dependencies/*" DoQuery idx

index: idx

build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:
	@$(MAKE) --no-print-directory compile

compile:
	@echo "--- Building Lucene 10.5.0 (BP variant)"
	@./gradlew clean build copyDependencies

# The index depends on the jar, not on `compile`: `compile` always runs a
# clean gradle build, and with it as a prerequisite every `make index` rebuilt
# the engine first, inside the timed index build. The jar is built once, by
# `make compile` or here when it is missing, and reused afterwards.
idx: build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar
	@echo "--- Indexing Lucene 10.5.0 (BP variant) ---"
	@java -server --add-modules jdk.incubator.vector --enable-native-access=ALL-UNNAMED -cp "build/libs/search-index-benchmark-game-lucene-1.0-SNAPSHOT.jar:build/dependencies/*" BuildIndex idx < $(CORPUS)
