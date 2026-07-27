# Runtime provenance and reproducibility

The launcher and the game prefix are deliberately separate:

- `output/wine-release` is build input and is copied into the application bundle.
- `~/Library/Application Support/<appIdentifier>/wine-prefix` is user data.
- Runtime preparation and verification scripts refuse to read from or write to
  the user prefix. Rebuilding or replacing the application must not remove it.

## v0.1.1 binary baseline

`baselines/v0.1.1.sha256` records every regular file in the known-working
v0.1.1 runtime. `scripts/runtime/verify-runtime.sh` regenerates the full tree
fingerprint and requires an exact match, including the file list. Release builds
run this check before compiling or signing. The two project-owned shims,
`cxcompatdb.so` and `wineserverfix.so`, are intentionally excluded because they
are rebuilt from the checked-in C sources and validated separately by CI.

To assemble the build input from a previously verified directory:

```bash
bash scripts/runtime/prepare-runtime.sh /path/to/wine-release
```

To verify it without changing anything:

```bash
bash scripts/runtime/verify-runtime.sh output/wine-release
```

## Source locks

`components.lock.json` is the machine-readable version inventory. DXMT, DXVK
and MoltenVK are pinned to full Git commits. DXMT v0.80 is rebuilt with
`patches/dxmt/0001-safe-resource-common-gettype.patch`; the launcher only enables
the legacy in-memory transition patch for the exact v0.1.1 DXMT binary hash.

DXMT can be rebuilt from an existing local checkout:

```bash
NATIVE_LLVM_PATH=/absolute/path/to/llvm \
WINE_BUILD_PATH=/absolute/path/to/wine-build \
bash scripts/runtime/build-dxmt.sh /absolute/path/to/dxmt /absolute/output
```

## Known reproducibility gap

The current repository identifies the Wine 11.0 source as CodeWeavers
CrossOver 26.1.0, but the original build's configure flags, dependency build
recipes and source-archive SHA-256 were not committed. Therefore this phase
provides a byte-for-byte reproducible runtime *assembly* from the verified
v0.1.1 baseline, but does not claim that Wine itself can yet be rebuilt from
source to identical bytes. `components.lock.json` marks this gap explicitly.
The release workflow must not silently substitute a different runtime.
