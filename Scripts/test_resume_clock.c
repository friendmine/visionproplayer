#include <assert.h>
#include <stdio.h>
#include "../VisionProPlayer/Bridge/VPPResumeClockGuard.h"
int main(void) {
    int64_t start=100000000, anchor=start, time=6021001;
    double position=0.2;
    VPPFilterResumeClock(start,&anchor,6021001,0.2,&time,&position);
    assert(time==6021001 && anchor==start); // first valid value must not disarm
    time=15668858;position=0.52;
    VPPFilterResumeClock(start+100000,&anchor,6021001,0.2,&time,&position);
    assert(time==6021001 && position==0.2 && anchor==start);
    time=6217179;position=0.207;
    VPPFilterResumeClock(start+300000,&anchor,6021001,0.2,&time,&position);
    assert(time==6217179 && position==0.207 && anchor==start); // valid time advances
    time=15668858;position=0.52;
    VPPFilterResumeClock(start+400000,&anchor,6021001,0.2,&time,&position);
    assert(time==6021001 && position==0.2); // late stale value still rejected
    time=-1;
    VPPFilterResumeClock(start+500000,&anchor,6021001,0.2,&time,&position);
    assert(time==6021001);
    time=8010000;position=0.267;
    VPPFilterResumeClock(start+2000000,&anchor,6021001,0.2,&time,&position);
    assert(anchor==0 && time==8010000); // never hold forever
    time=12000000;position=0.4;
    VPPFilterResumeClock(start+2100000,&anchor,6021001,0.2,&time,&position);
    assert(time==12000000 && position==0.4); // cleared guard permits new seek
    puts("PASS: valid-first/stale-next race, valid progress, late stale/invalid polls, expiry and explicit reset");
}
