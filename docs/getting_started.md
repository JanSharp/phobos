
This document will describe how to use Phobos to compile and run your Phobos code.

# Setup

Download the zip for your platform from the GitHub Releases, extract all files and run it using this command in your command line or terminal:

```bash
./lua -- main.lua -h
```

**The working directory has to be the directory containing the main.lua file.** Use the `--working-dir` argument if you wish to use relative paths to a given directory. Otherwise they are relative to the `main.lua` file, as that is the actual working directory.

If your OS blocks the executable for security reasons either allow them to run in properties (on windows) or preferences (on osx/macOS), or use your own Lua and LuaFileSystem binaries with the raw Phobos package. I'm not aware of a linux distribution with this issue.

Also note that windows command line commands may look different. I recommend using a shell instead, like git bash (the only one I'm aware of, I'm assuming there are more).

# Compiling

`main.lua` is the entry point for compiling. Use `--help` for information on it's arguments.

The help message should cover which arguments are required and explain what each argument does. This user interface is pretty bad at the moment, I have ideas and a concept for build profiles which will entirely replace the current arguments, should be easier to use and enable me to provide templates.

# Running

Once you have compiled your code you can run the resulting files just like you would run normal Lua files.

With standalone Lua it would look like this:

```bash
path/to/lua -- path/to/your/compiled/file.lua <args passed to your file>
```

In other environments it should be similarly straight forward, however some may disallow loading bytecode files directly. If you get an error suggesting as such (like in [Factorio](factorio_support.md)), use `--use-load` when compiling, which will cause the output files to use the `load` function on a bytecode string instead of being raw bytecode. However if the target environment does not allow loading bytecode with `load` either, then you cannot use Phobos for it, unfortunately.
