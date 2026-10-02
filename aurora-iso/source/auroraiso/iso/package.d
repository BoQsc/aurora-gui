/**
 * Public surface of the independent ISO 9660 implementation.
 *
 * `import auroraiso.iso;` gives access to the reader, writer, extraction
 * helpers, and the on-disk structures. The implementation depends only on the
 * D standard library, never on external tools or native ISO libraries.
 */
module auroraiso.iso;

public import auroraiso.iso.endian;
public import auroraiso.iso.structures;
public import auroraiso.iso.reader;
public import auroraiso.iso.writer;
public import auroraiso.iso.extract;
