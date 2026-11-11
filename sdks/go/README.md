# gtty SDK for Go

Extensions for [gtty](../../README.md) in Go 1.21+, standard library only:
`import gtty "github.com/Tesselix/gtty/sdks/go"`. `examples/hosts` (with
its `manifest.json`) is a complete extension; `AGENTS.md` is the guide,
written for AI assistants and people alike. The design is in
[docs/extensions.md](../../docs/extensions.md), the wire format in
[docs/protocol.md](../../docs/protocol.md).

```sh
go build -o /tmp/hosts ./examples/hosts
python3 ../conformance/fake_gtty.py -- /tmp/hosts   # the check
```
