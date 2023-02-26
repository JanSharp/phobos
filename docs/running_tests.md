
## Running Tests

It's actually literally the same thing as [Running from Source](running_from_source.md), including vscode/vscodium launch profiles, but using `tests/main.lua` instead of `src/main.lua`. Tests are using the same arg parser as phobos itself, so you can get help using `-h` just like for `src/main.lua`.

`out/debug/phobos` can't be used to run tests, since that's always running the phobos main file as the entry point. So you have to use the `phobos_dev` script.
