module tests.rendezvous_smoke;

import aurorarustdesk.rendezvous : RendezvousPeer, RendezvousServer,
    lookupPeer, registerHost;
import std.exception : enforce;
import std.stdio : writeln;

int main()
{
    auto server = new RendezvousServer;
    const idPort = server.start(0, 0);
    scope (exit) server.stop();
    enforce(idPort != 0, "The ID server did not bind a port.");
    enforce(server.relayPort() != 0, "The relay did not bind a port.");

    auto registration = registerHost("127.0.0.1", idPort, "314159265",
        21_118, false);
    scope (exit) registration.socket.close();

    RendezvousPeer peer;
    enforce(lookupPeer("127.0.0.1", idPort, "314159265", peer),
        "A registered ID was not resolved.");
    enforce(peer.address.length > 0, "Resolved peer had no address.");
    enforce(peer.directPort == 21_118, "Resolved peer had the wrong port.");
    enforce(!peer.relay, "Direct registration reported as relayed.");

    RendezvousPeer missing;
    enforce(!lookupPeer("127.0.0.1", idPort, "271828182", missing),
        "An unknown ID resolved unexpectedly.");

    auto relayed = registerHost("127.0.0.1", idPort, "161803398", 0, true);
    scope (exit) relayed.socket.close();
    enforce(relayed.relayPort != 0,
        "A relay registration did not receive the relay port.");
    RendezvousPeer relayPeer;
    enforce(lookupPeer("127.0.0.1", idPort, "161803398", relayPeer),
        "A relay-registered ID was not resolved.");
    enforce(relayPeer.relay, "Relay registration reported as direct.");
    enforce(relayPeer.relayPort == relayed.relayPort,
        "Relay port did not match the registration.");

    writeln("Aurora RustDesk rendezvous smoke passed: register, resolve, unknown ID, relay registration");
    return 0;
}
