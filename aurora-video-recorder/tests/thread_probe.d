// Scratch probe: can this program start a druntime thread at all?
import core.thread : Thread, dur;
import core.stdc.stdio : printf;

__gshared int ran;

void main()
{
    printf("before thread\n");
    auto t = new Thread({ ran = 1; });
    t.isDaemon = true;
    t.start();
    t.join();
    printf("after thread ran=%d\n", ran);
}
