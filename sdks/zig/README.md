# gtty SDK for Zig

Extensions for gtty in Zig 0.16: each is its own program (`main` calls
`gtty.run(@This())`), and gtty's own chips use the same SDK inside gtty.
See the [developer guide](https://github.com/Tesselix/gtty/blob/main/docs/extensions.md)
and the [protocol](https://github.com/Tesselix/gtty/blob/main/docs/protocol.md).

Writing an extension with an AI assistant? Point it at
[AGENTS.md](AGENTS.md); `examples/hosts.zig` is a complete extension to start
from.

```sh
zig fetch --save=gtty https://github.com/Tesselix/gtty/releases/latest/download/gtty-sdk-zig.tar.gz
```

Then in your `build.zig`:

```zig
const sdk = b.dependency("gtty", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("gtty", sdk.module("gtty"));
```

`zig build` makes `zig-out/bin/hosts` from the example; put it with
`examples/manifest.json` in a folder and `gtty ext install` that folder.
