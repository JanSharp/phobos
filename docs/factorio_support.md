
# Compiling for Factorio

First you need to get Phobos setup and run it, see Setup and Compiling in [Getting Started](getting_started.md).

When compiling for a Factorio mod you currently **must** use `--use-load` because Factorio does not load raw bytecode Lua files.

Additionally it is highly recommended to use `--source-name "@__mod-name__/?"` to match Factorio's source name pattern (`mod-name` being your internal mod name). This will affect stacktraces and debuggers.

## Sample Setup

If the your dev environment is setup such that the root of the `.pho` source files is the same as the `info.json` file then you most likely want to omit `--output` to generate compiled `.lua` files directly next to the source files.\
An example:
```
MyMod
  |- control.pho
  |- info.json
```
Would look like this after compilation:
```
MyMod
  |- control.lua
  |- control.pho
  |- info.json
```

Note that simply because this is a sample it doesn't mean it's the best. I'm assuming it'll work pretty well for small mods, but the bigger they get the more cumbersome this can get. My hope is that if you write bigger mods you'll also have an easier time figuring out how to use a different setup. But again as mentioned in Getting Started, build profiles should make this significantly easier and they'll enable me to provide templates for Factorio.

# Factorio Mod

There is also a Factorio mod on the [Factorio Mod Portal](https://mods.factorio.com/mod/phobos) and in the GitHub Releases.\
It contains all files required to use Phobos **at runtime** (like a library), no command line tools.\
(Though as mentioned in the Library section, this is most likely going to undergo changes in the future)\
Additionally the mod, and only the mod, contains a `control.lua` file to register commands to run Phobos in the in-game console similar to regular Lua commands. Use `/help` in-game.
