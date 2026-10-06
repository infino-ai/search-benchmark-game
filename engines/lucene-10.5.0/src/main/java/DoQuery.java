import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.apache.lucene.analysis.CharArraySet;
import org.apache.lucene.analysis.standard.StandardAnalyzer;
import org.apache.lucene.index.DirectoryReader;
import org.apache.lucene.index.IndexReader;
import org.apache.lucene.queryparser.classic.ParseException;
import org.apache.lucene.queryparser.classic.QueryParser;
import org.apache.lucene.search.IndexSearcher;
import org.apache.lucene.search.Query;
import org.apache.lucene.search.Sort;
import org.apache.lucene.search.SortField;
import org.apache.lucene.search.TopFieldCollectorManager;
import org.apache.lucene.search.TopScoreDocCollectorManager;
import org.apache.lucene.search.similarities.BM25Similarity;
import org.apache.lucene.store.FSDirectory;

public class DoQuery {
    /** Threads for one query, from BENCH_QUERY_THREADS. Default 1: no executor. */
    private static int queryThreads() {
        final String raw = System.getenv("BENCH_QUERY_THREADS");
        if (raw == null || raw.isEmpty()) {
            return 1;
        }
        try {
            return Math.max(1, Integer.parseInt(raw.trim()));
        } catch (NumberFormatException e) {
            return 1;
        }
    }

    public static void main(String[] args) throws IOException, ParseException {
        final Path indexDir = Paths.get(args[0]);
        try (IndexReader reader = DirectoryReader.open(FSDirectory.open(indexDir));
                BufferedReader bufferedReader = new BufferedReader(new InputStreamReader(System.in))) {
            // BENCH_QUERY_THREADS>1 gives the searcher an executor, so one query
            // is answered across the index's segments in parallel. Unset or 1 —
            // which is the nightly — the searcher has no executor and works on
            // the calling thread, exactly as before.
            //
            // A scale run wants the parallel form: a machine answering queries
            // over a billion documents uses the cores it has, and measuring one
            // core of a 44-core host describes nothing anyone would deploy.
            final int queryThreads = queryThreads();
            final ExecutorService executor =
                    queryThreads > 1 ? Executors.newFixedThreadPool(queryThreads, r -> {
                        Thread t = new Thread(r);
                        t.setDaemon(true);
                        return t;
                    }) : null;
            final IndexSearcher searcher =
                    executor == null ? new IndexSearcher(reader) : new IndexSearcher(reader, executor);
            System.err.println("lucene: query threads = " + (executor == null ? 1 : queryThreads)
                    + ", segments = " + reader.leaves().size());
            searcher.setQueryCache(null);
            searcher.setSimilarity(new BM25Similarity(0.9f, 0.4f));
            final QueryParser queryParser = new QueryParser("text", new StandardAnalyzer(CharArraySet.EMPTY_SET));
            String line;
            while ((line = bufferedReader.readLine()) != null) {
                final String[] fields = line.trim().split("\t");
                assert fields.length == 2;
                final String command = fields[0];
                final String query_str = fields[1];
                Query query = queryParser.parse(query_str);
                final long count;
                switch (command) {
                case "COUNT":
                case "UNOPTIMIZED_COUNT":
                    count = searcher.count(query);
                    break;
                case "TOP_10":
                {
                    searcher.search(query, new TopScoreDocCollectorManager(10, null, 10, false));
                    count = 1;
                }
                break;
                case "TOP_100":
                {
                    searcher.search(query, new TopScoreDocCollectorManager(100, null, 100, false));
                    count = 1;
                }
                break;
                case "TOP_1000":
                {
                    searcher.search(query, new TopScoreDocCollectorManager(1000, null, 1000, false));
                    count = 1;
                }
                break;
                case "TOP_10_COUNT":
                {
                    count = searcher.search(query, new TopScoreDocCollectorManager(10, null, Integer.MAX_VALUE, false)).totalHits.value();
                }
                break;
                case "TOP_100_COUNT":
                {
                   count = searcher.search(query, new TopScoreDocCollectorManager(100, null, Integer.MAX_VALUE, false)).totalHits.value();
                }
                break;
                case "TOP_1000_COUNT":
                {
                   count = searcher.search(query, new TopScoreDocCollectorManager(1000, null, Integer.MAX_VALUE, false)).totalHits.value();
                }
                break;
                case "TOP_10_FF":
                {
                    Sort sort = new Sort(new SortField("sort_field", SortField.Type.LONG, true));
                    searcher.search(query, new TopFieldCollectorManager(sort, 10, null, 10, false));
                    count = 1;
                }
                break;
                case "TOP_100_FF":
                {
                    Sort sort = new Sort(new SortField("sort_field", SortField.Type.LONG, true));
                    searcher.search(query, new TopFieldCollectorManager(sort, 100, null, 100, false));
                    count = 1;
                }
                break;
                case "TOP_1000_FF":
                {
                    Sort sort = new Sort(new SortField("sort_field", SortField.Type.LONG, true));
                    searcher.search(query, new TopFieldCollectorManager(sort, 1000, null, 1000, false));
                    count = 1;
                }
                break;
                default:
                    System.out.println("UNSUPPORTED");
                    count = 0;
                    break;
                }
                System.out.println(count);
            }
        }
    }
}
