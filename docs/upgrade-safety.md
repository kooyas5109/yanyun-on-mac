# Launcher upgrade safety

Launcher updates must preserve an already installed game.

## Stable data contract

The following identifiers and paths are persistent product data:

| Target | `appIdentifier` | User-data root |
| --- | --- | --- |
| Yanyun | `yanyun.simulator` | `~/Library/Application Support/yanyun.simulator` |
| Ywzh | `ywzh.simulator` | `~/Library/Application Support/ywzh.simulator` |

Each target keeps its Wine prefix at `<user-data root>/wine-prefix`. A normal
build, installation or application replacement may update only the application
bundle and its embedded `wine-release`; it must not delete, rename or
automatically recreate that prefix.

The launcher may repair an incomplete prefix in place. It writes
`.prefix_ready`, `.mshtml_typelib_fixed_v3` and `.fever_installed` only after
the corresponding commands and file checks succeed. A stale marker may be
ignored or removed, but the prefix itself is retained.

## The only destructive path

The in-app **Reset simulator environment** action is intentionally destructive.
It requires a separate confirmation and is the only supported path that removes
the Wine prefix and installed game. Build, release, diagnostics and runtime
preparation scripts never call it and never access the user-data root.

## Review checklist

Before releasing a launcher update:

1. Confirm both `appIdentifier` values and `wine-prefix` remain unchanged.
2. Verify runtime compatibility against a copy of an existing prefix.
3. Confirm startup detects the launcher executable, not only a marker file.
4. Confirm process cleanup is limited to the current `WINEPREFIX` and recorded
   descendants.
5. Confirm diagnostics omit registry files, game files and credentials.
6. Run unit tests, native-shim compilation, signature verification and
   notarization.
