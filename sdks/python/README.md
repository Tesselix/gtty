# gtty SDK for Python

Extensions for [gtty](../../README.md) in Python 3.8+, standard library
only: copy `gtty.py` next to your extension. `examples/hosts.py` (with
`examples/manifest.json`) is a complete extension; `AGENTS.md` is the
guide, written for AI assistants and people alike. The design is in
[docs/extensions.md](../../docs/extensions.md), the wire format in
[docs/protocol.md](../../docs/protocol.md).

```sh
python3 ../conformance/fake_gtty.py -- python3 examples/hosts.py   # the check
```

To try it in gtty, make a package folder with `gtty.py`, `hosts.py` and
`manifest.json`, then:

```sh
gtty ext install ./that-folder
```
