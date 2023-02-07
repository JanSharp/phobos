
# Building from Source

When doing anything in the source tree, always have your working directory be the root of the project.

Clone the repo and init and or update all submodules. something like this should work:
```bash
git submodule init
git submodule update
```

If you're using vscode/vscodium you can just run the build tasks from the command pallet.

Run one of these, whichever is the most applicable:
```bash
launch_scripts/phobos_dev linux src src/main.lua -n debug -- -p linux
launch_scripts/phobos_dev osx src src/main.lua -n debug -- -p osx
launch_scripts/phobos_dev windows src src/main.lua -n debug -- -p windows
```

To build the factorio mod, run (again most applicable):
```bash
launch_scripts/phobos_dev linux src src/main.lua -n debug_factorio
launch_scripts/phobos_dev osx src src/main.lua -n debug_factorio
launch_scripts/phobos_dev windows src src/main.lua -n debug_factorio
```

To build release versions replace `debug` with `release` in any of the above.

On windows you should be able to use both MS DOS or some shell like git bash. In theory.

The `phobos_dev` script expects 3 args:
- your platform, so `linux`, `osx` or `windows`
- the relative path to the phobos files to be run. So `out/debug`, `out/release` or `src` (as long as `src` is still using `.lua` files)
- the relative path to the lua file to run. In this case `src/main.lua`, but could be any Lua file, regardless of file extension.

The launch scripts have a good amount of comments to assist in understanding and troubleshooting.
