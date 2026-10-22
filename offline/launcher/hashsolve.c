/* SHODAN Stat Editor Offline: the hash correction's search for a block header at an offset % 8 == 4, on every core.
   Per salt k (its hash state before the header's word at +12, and the state the word at +20 must lead to): find the
   3 free bytes t of word +12 for which the word at +20 that reaches the needed state keeps its upper 4 bytes (the
   payload's). 1 in 256 salts has an answer; each costs 2^24 tries. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>

#define MUL 0xC6A4A7935BD1E995ULL
#define INV 0x5F7A0EA7E59B19BDULL

typedef struct {
    const uint64_t *before, *need;
    int salts;
    uint64_t fixed12, high20;
    uint32_t from, to;
    volatile LONG *done;
    int found;
    uint64_t w12, w20;
} job;

static DWORD WINAPI search(void *arg)
{
    job *j = (job *)arg;
    j->found = -1;
    for (uint32_t t = j->from; t < j->to; t++) {
        if ((t & 1023) == 0 && *j->done) return 0;
        uint64_t w = j->fixed12 | ((uint64_t)t << 40);
        uint64_t v = w * MUL; v ^= v >> 47; v *= MUL;
        for (int k = 0; k < j->salts; k++) {
            uint64_t m = ((j->before[k] ^ v) * MUL) ^ j->need[k];
            uint64_t u = m * INV; u ^= u >> 47; u *= INV;
            if ((u >> 32) == j->high20) {
                j->found = k; j->w12 = w; j->w20 = u;
                InterlockedExchange(j->done, 1);
                return 0;
            }
        }
    }
    return 0;
}

/* before[k], need[k] (need = the state after the word at +20, times INV); fixed12: the word at +12 without its free
   bytes; high20: the upper half the word at +20 must keep. Returns the salt found (its words in w12, w20), or -1. */
__declspec(dllexport) int shodan_solve_unaligned(const uint64_t *before, const uint64_t *need, int salts,
                                                 uint64_t fixed12, uint64_t high20, uint64_t *w12, uint64_t *w20)
{
    enum { MAX_THREADS = 64 };
    job jobs[MAX_THREADS];
    HANDLE threads[MAX_THREADS];
    volatile LONG done = 0;
    DWORD count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    int n = count < 1 ? 1 : count > MAX_THREADS ? MAX_THREADS : (int)count;
    uint32_t span = (1u << 24) / n + 1;
    int started = 0;
    for (int i = 0; i < n; i++) {
        job *j = &jobs[i];
        j->before = before; j->need = need; j->salts = salts;
        j->fixed12 = fixed12; j->high20 = high20; j->done = &done; j->found = -1;
        j->from = (uint32_t)i * span;
        j->to = j->from + span > (1u << 24) ? (1u << 24) : j->from + span;
        threads[i] = CreateThread(NULL, 0, search, j, 0, NULL);
        if (threads[i] == NULL) { search(j); } else started++;
    }
    for (int i = 0; i < n; i++) {
        if (threads[i] != NULL) { WaitForSingleObject(threads[i], INFINITE); CloseHandle(threads[i]); }
    }
    for (int i = 0; i < n; i++) {
        if (jobs[i].found >= 0) { *w12 = jobs[i].w12; *w20 = jobs[i].w20; return jobs[i].found; }
    }
    return -1;
}
