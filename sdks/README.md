# gtty SDKs

One folder per language. Each is packed into its own release file by
`scripts/package-sdks.sh`, with the LICENSE, a VERSION file and the shared
check `conformance/fake_gtty.py`.

| Folder | Language | Release file |
|---|---|---|
| `zig/` | Zig 0.16 (also gtty's own chips) | `gtty-sdk-zig-<version>.tar.gz` |
| `python/` | Python 3.8+ | `gtty-sdk-python-<version>.tar.gz` |
| `javascript/` | Node.js 18+ (TypeScript types) | `gtty-sdk-javascript-<version>.tar.gz` |
| `go/` | Go 1.21+ | `gtty-sdk-go-<version>.tar.gz` |

An extension is its own program: gtty starts it as a child process and
they talk over a socket ([docs/protocol.md](../docs/protocol.md)). Every
SDK has the same functions, and the same example extension (hosts), which
`conformance/fake_gtty.py`, a stand-in for gtty, runs through one
conversation (CI does, for all four). Started from an IDE's debugger
instead, an extension connects to the running gtty and takes the place of
its installed copy (each `AGENTS.md`, "Debug"). A new language needs only the
protocol, standard libraries, and its hosts example passing that check.

Most extensions will be written with AI assistants, so every SDK ships an
`AGENTS.md` that stands alone and lists only what exists, and a complete
example the check covers.

gtty's standard chips (`src/chips/`) use the Zig SDK inside gtty's own
process. See the [developer guide](../docs/extensions.md).
