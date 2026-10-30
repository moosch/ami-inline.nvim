# Demo

`inline.tape` is a [VHS](https://github.com/charmbracelet/vhs) script — the source
for `inline.gif` shown in the main README. GitHub doesn't render `.tape`; render it
to a `.gif` and commit the `.gif`.

## Render

```sh
# from this repo's root, with ami core checked out as a sibling:
vhs demos/inline.tape

# or point at your server / pick models:
AMI_ENDPOINT=http://192.168.68.100:1234/v1 AMI_FIM_MODEL=qwen3-coder vhs demos/inline.tape

git add demos/inline.gif && git commit -m "docs: update demo gif"
```

`demos/init.lua` loads **ami core** (found next to this repo as `../ami.nvim` or
`../ai-harness`, or via `$AMI_CORE`) plus this extension. Requires `vhs`
(`brew install vhs`) and a running LM Studio with a FIM-capable model.

Tune the `Sleep` after `Ctrl+G` to cover your model's completion latency (the first
completion can be slow while LM Studio loads the model).
