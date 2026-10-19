# Migrating from the vendor Unicode modules

The mutable Aurora-D tree still exposes the same algorithms as:

```d
import aurora.text.unicode.properties;
import aurora.text.unicode.grapheme;
import aurora.text.unicode.bidi;
import aurora.text.unicode.linebreak;
```

The frozen standard exposes them as:

```d
import aurora.standard.text.unicode.properties;
import aurora.standard.text.unicode.grapheme;
import aurora.standard.text.unicode.bidi;
import aurora.standard.text.unicode.linebreak;
```

The algorithms, tables, boundary conventions, and Unicode version are the same.
Only the namespace and package ownership change.

## Migration steps

1. Add `standard/aurora-standard` as a DUB path dependency or add
   `standard/aurora-standard/source` to the build include path.
2. Replace the four Unicode imports with the `aurora.standard.*` imports.
3. Update type references that came from those modules. `BidiResult`,
   `ParagraphDirection`, `GraphemeBreak`, `BidiClass`, `LineBreakClass`,
   `Script`, and the other property types now belong to the standard package.
4. Compile the consumer test or the application. Any unresolved symbol is a
   missed migration.
5. Run the application's text tests. The expected behavior is unchanged.
6. Remove the vendor Unicode imports from that consumer. Do not mix the vendor
   and standard namespaces in one module: their types are distinct even when
   the values are identical.

## What not to do

- Do not copy the implementation back into an application.
- Do not keep both namespaces in one module to avoid changing a type.
- Do not edit files under `standard/aurora-standard` to suit one consumer.
  Propose a versioned standard change instead.
- Do not treat the vendor Unicode modules as the standard after migration.
  They remain part of the mutable framework until they are removed or made
  forwarders.

## Future framework direction

The mutable Aurora-D framework can eventually depend on `aurora-standard` and
re-export or forward the old imports during a deprecation window. That keeps
one implementation of the Unicode algorithms while applications migrate at
their own pace.

## Rollback

Reverting the import changes returns the consumer to the vendor modules. No
data or project files are rewritten by this migration, so rollback is limited to
the import and dependency changes.
