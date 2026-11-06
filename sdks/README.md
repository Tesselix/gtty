# gtty SDKs

One folder per language, each packed into its own release file by
`scripts/package-sdks.sh`:

| Folder | Release file |
|---|---|
| `zig/` | `gtty-sdk-zig-<version>.tar.gz` |

Once Zig works, JavaScript, Python 3, C and Rust follow.

Most extensions will be written with AI assistants, so every SDK ships an
`AGENTS.md` that stands alone and lists only what exists, and a complete
example its tests compile.

gtty's standard chips (`src/chips/`) use the Zig SDK. See the
[developer guide](../docs/extensions.md).
