#pragma once
#include <stdint.h>

// A plausible first poll does not mean the asynchronous resume/seek has fully
// settled: VLC may briefly publish the old polling clock after that first poll.
// Let plausible positions advance, but retain the bounded guard for its full
// settling window. An explicit new seek clears the anchor in the caller.
static inline void VPPFilterResumeClock(int64_t now, int64_t *anchorDate,
    int64_t anchorTime, double anchorPosition, int64_t *time, double *position) {
    if (*anchorDate <= 0) return;
    int64_t age = now > *anchorDate ? now - *anchorDate : 0;
    if (age >= 2000000) { *anchorDate = 0; return; }
    if (*time < anchorTime - 250000 || *time > anchorTime + age + 500000) {
        *time = anchorTime; *position = anchorPosition;
    }
}
