# gtty SDK for JavaScript

Extensions for [gtty](../../README.md) on Node.js 18+, no packages: copy
`gtty.js` (and `gtty.d.ts` for editors and TypeScript) next to your
extension. `examples/hosts.js` (with `examples/manifest.json`) is a
complete extension; `AGENTS.md` is the guide, written for AI assistants
and people alike. The design is in [docs/extensions.md](../../docs/extensions.md),
the wire format in [docs/protocol.md](../../docs/protocol.md).

```sh
python3 ../conformance/fake_gtty.py -- node examples/hosts.js   # the check
```
