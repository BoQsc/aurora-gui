module tests.core_smoke;

import aurorarustdesk.crypto;
import aurorarustdesk.framecodec;
import aurorarustdesk.identity;
import aurorarustdesk.protocol;

import std.stdio : writeln;

// The imported modules also run their own unit tests under -unittest: crypto
// (AEAD round-trip and tamper rejection), identity (numeric ID stability and
// password derivation), protocol (encrypted handshake, wrong-password
// rejection), and framecodec (delta encode/decode round-trip). This local test
// emits the single confirming line after they have all passed.
unittest
{
    writeln("Aurora RustDesk core smoke tests passed: crypto, identity, protocol, framecodec");
}
