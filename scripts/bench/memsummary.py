"""Benchmark-only: summarize memlog.sh output into one greppable line."""
import csv
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
if not rows:
    print("MEMORY_SUMMARY samples=0")
    sys.exit(0)


def col(name, cast=float):
    out = []
    for r in rows:
        try:
            out.append(cast(r[name]))
        except (ValueError, TypeError):
            pass
    return out


rss, swap, free, pct = col("host_rss_mb"), col("swap_used_mb"), col("free_mb"), col("free_pct")
line = (f"MEMORY_SUMMARY samples={len(rows)} peak_host_rss_mb={max(rss) if rss else 'na'} "
        f"peak_swap_used_mb={max(swap) if swap else 'na'} min_free_mb={min(free) if free else 'na'} "
        f"min_free_pct={min(pct) if pct else 'na'}")
print(line)
