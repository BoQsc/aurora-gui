module tests.wifitime;

import auroradesktop.wlan : queryWifi, kickWifiScan;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.algorithm : maxElement, minElement;
import std.stdio : writefln;

void main()
{
    long worst;
    foreach (i; 0 .. 8)
    {
        auto sw = StopWatch(AutoStart.yes);
        auto s = queryWifi();
        sw.stop();
        if (sw.peek.total!"usecs" > worst) worst = sw.peek.total!"usecs";
        writefln("queryWifi #%d: %d usec, networks=%d", i,
            sw.peek.total!"usecs", s.networks.length);
    }
    kickWifiScan();
    writefln("worst single query = %d usec", worst);
}
