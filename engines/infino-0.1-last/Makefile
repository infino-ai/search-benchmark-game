# infino-0.1-last: a SECOND measurement of the exact same branch build and
# index as engines/infino-0.1, but placed LAST in the engine list so a fork
# page can show the branch benched both first and last.
#
# Why: src/client.py measures engines sequentially in a fixed order, one full
# warmup+run block each. The first-measured engine and the last-measured one
# see different within-run machine state (cache/JIT/thermal/memory left by the
# other engines, notably the lucene JVM between commands), so a branch pinned to
# one position is compared against the baseline under a position bias that can
# read as a spurious regression on unchanged code. Benching the branch at both
# ends brackets that bias, so the fork page shows how much of any branch-vs-main
# delta is real vs. measurement position.
#
# This engine owns no build or index of its own: it reuses the sibling
# engines/infino-0.1 binary and index (same branch source, same corpus), so it
# adds a second measurement pass but no extra compile or index cost. compile /
# index / clean are therefore intentional no-ops; the top-level Makefile still
# iterates them over every engine, so they must exist and succeed.

compile:

index:

clean:

serve:
	@../infino-0.1/target/release/do_query ../infino-0.1/idx
