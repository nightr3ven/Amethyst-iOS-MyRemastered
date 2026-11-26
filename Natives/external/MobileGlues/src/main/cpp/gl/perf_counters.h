// perf_counters.h -- cheap per-category GL call counters for Air's PERF logs.
//
// Each instrumented entry point opens an MG_PERF_SCOPE. Only the outermost
// scope on a thread is timed, so nested calls (glDrawRangeElements ->
// glDrawElementsBaseVertex) are not double counted. Air reads and resets the
// totals every few seconds through mg_perf_snapshot() and logs them as
// [PERF-GL]. Set MG_PERF=0 to turn it off.
#pragma once
#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <mach/mach_time.h>

enum MGPerfCat : int { MGP_DRAW = 0, MGP_MULTIDRAW, MGP_BUFFER, MGP_MAP, MGP_COUNT };

inline std::atomic<uint64_t> mg_perf_calls[MGP_COUNT];
inline std::atomic<uint64_t> mg_perf_ticks[MGP_COUNT];
inline std::atomic<uint64_t> mg_perf_subdraws{0};
inline std::atomic<uint64_t> mg_perf_bytes{0};
inline thread_local int mg_perf_depth = 0;

inline bool mg_perf_enabled() {
    static const bool on = [] {
        const char* e = getenv("MG_PERF");
        return !(e && e[0] == '0');
    }();
    return on;
}

struct MGPerfScope {
    int cat;
    uint64_t t0 = 0;
    bool outer;
    explicit MGPerfScope(int c) : cat(c), outer(mg_perf_enabled() && mg_perf_depth++ == 0) {
        if (outer) t0 = mach_absolute_time();
    }
    ~MGPerfScope() {
        if (!mg_perf_enabled()) return;
        --mg_perf_depth;
        if (!outer) return;
        mg_perf_ticks[cat].fetch_add(mach_absolute_time() - t0, std::memory_order_relaxed);
        mg_perf_calls[cat].fetch_add(1, std::memory_order_relaxed);
    }
};

#define MG_PERF_CAT2(a, b) a##b
#define MG_PERF_CAT(a, b) MG_PERF_CAT2(a, b)
#define MG_PERF_SCOPE(cat) MGPerfScope MG_PERF_CAT(_mg_perf_scope_, __LINE__)(cat)
#define MG_PERF_SUBDRAWS(n) do { if (mg_perf_enabled() && mg_perf_depth == 1) mg_perf_subdraws.fetch_add((uint64_t)(n), std::memory_order_relaxed); } while (0)
#define MG_PERF_BYTES(n) do { if (mg_perf_enabled() && mg_perf_depth == 1) mg_perf_bytes.fetch_add((uint64_t)(n), std::memory_order_relaxed); } while (0)
