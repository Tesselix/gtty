module github.com/Tesselix/gtty/extension-examples/commands/go

go 1.21

require github.com/Tesselix/gtty/sdks/go v0.0.0

// The SDK in this repository. Outside it: the SDK's release archive
// unpacked next to this folder, or drop this line once the module is
// published with a tag.
replace github.com/Tesselix/gtty/sdks/go => ../../../sdks/go
