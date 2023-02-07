
# Building from Source

Clone the repo and init and or update all submodules. something like this should work:
```bash
git submodule init
git submodule update
```

There are `scripts/build_src.lua` and `scripts/build_factorio_mod.lua` which have to be run through `entry_point.lua` (see that file itself for details).

If you're using vscode just run the build tasks from the command pallet.

Then to actually run src or those built "binaries" check the `.vscode/launch.json` file.
