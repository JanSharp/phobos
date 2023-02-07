
## Running from Source

First I suggest reading [Building from Source](building_from_source.md) for the initial setup and it introduces you to the launch scripts a bit more.

### VSCode/VSCodium

Again, if you're using vscode/vscodium just press F5. To select the right launch profile either use the side panel or press `CTRL + P`, type `debug`, then a space, and select the launch profile from there.\
The `Phobos` and `Lua` prefixes are currently relevant since phobos itself is still written in `.lua` files. That means the `Lua` prefixed launch profiles will run directly from source while `Phobos` will use phobos itself to compile `src` and then run and debug `out/debug`. This, however, uses the `Build Debug` task, which uses `src` to compile itself, which means if there is a bug then you can't use that to actually debug it. This will change once I require you to have a previous version of Phobos installed to compile Phobos.

### Terminal

Run one of these, whichever is the most applicable:
```bash
# run directly from the source tree
launch_scripts/phobos_dev linux src src/main.lua -h
launch_scripts/phobos_dev osx src src/main.lua -h
launch_scripts/phobos_dev windows src src/main.lua -h

# run generated output
launch_scripts/phobos_dev linux out/debug out/debug/main.lua -h
launch_scripts/phobos_dev osx out/debug out/debug/main.lua -h
launch_scripts/phobos_dev windows out/debug out/debug/main.lua -h
# same with release

# run generated output directly (can only run the main.lua file with this approach)
out/debug/phobos
# or
out/release/phobos
```
