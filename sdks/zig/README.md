# gtty SDK for Zig

Early: only gtty's own chips use this so far. See the
[developer guide](https://github.com/Tesselix/gtty/blob/main/docs/extensions.md).

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
