//
// The timers the tests of this package give the code they call, as a thread gives its own to each function: one list for the test
// thread, which only that thread uses. A test that sets a timer clears it, or lets it run, before the test ends.
//

const ziggy = @import("ziggy");

const TimerList = ziggy.timers.TimerList;
const Timers = ziggy.timers.Timers;

//
// The test thread's timers.
//
threadlocal var timer_list: TimerList = TimerList.init();

//
// The test thread's timers, for the code a test calls.
//
pub fn timers() Timers {
    return timer_list.interface();
}
