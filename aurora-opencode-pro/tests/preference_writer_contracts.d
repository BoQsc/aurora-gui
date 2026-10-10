module preference_writer_contracts;

import auroraopencode.preferencewriter;
import auroraopencode.core : Settings, ProviderApiKeys, ProjectState, Project;
import core.sync.mutex : Mutex;
import core.sync.condition : Condition;
import core.time : MonoTime, seconds;
import std.stdio : writeln;

int main()
{
    auto mutex = new Mutex();
    auto changed = new Condition(mutex);
    bool entered, release;
    Settings[] writes;
    auto writer = new PreferenceWriter!Settings((Settings value) {
        synchronized (mutex)
        {
            writes ~= value;
            if (writes.length == 1)
            {
                entered = true;
                changed.notifyAll();
                while (!release) changed.wait();
            }
        }
    });
    scope (exit) writer.close();
    Settings settings;
    settings.model = "first";
    writer.save(settings);
    synchronized (mutex)
        while (!entered) assert(changed.wait(5.seconds), "Writer failed to start");
    // Keep the disk sink parked until submissions finish. A synchronous save
    // deadlocks this fixture; one-job-per-click fails the exact write count.
    auto start = MonoTime.currTime;
    foreach (_; 0 .. 10_000) writer.save(settings);
    settings.model = "latest";
    settings.providerKeys = [ProviderApiKeys.init];
    settings.providerKeys[0].extraApiKeys = ["original"];
    writer.save(settings);
    settings.providerKeys[0].extraApiKeys[0] = "mutated";
    settings.providerKeys[0].apiKey = "mutated";
    assert(MonoTime.currTime - start < 5.seconds, "Submissions waited for the sink");
    synchronized (mutex) { release = true; changed.notifyAll(); }
    writer.flush();
    assert(writes.length == 2);
    assert(writes[1].model == "latest");
    assert(writes[1].providerKeys[0].extraApiKeys[0] == "original");
    assert(writes[1].providerKeys[0].apiKey == "");

    ProjectState projects;
    projects.projects = [Project("p", "original", "path")];
    auto snapshot = preferenceSnapshot(projects);
    projects.projects[0].name = "mutated";
    assert(snapshot.projects[0].name == "original");

    int attempts;
    auto recovering = new PreferenceWriter!Settings((Settings value) {
        if (++attempts == 1) throw new Exception("simulated disk failure");
    });
    recovering.save(settings);
    recovering.flush();
    recovering.save(settings);
    recovering.flush();
    recovering.close();
    assert(attempts == 2, "A failed save must not kill the worker");
    writeln("PASS preference writer: stalled sink, bounded queue, detached state, failure recovery");
    return 0;
}
