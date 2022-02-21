
for the Phobos factorio mod add commands for running Phobos.\
`/pho`, `/s-pho`, `/phobos`, `/silent-phobos`, `/measured-phobos` or so

with types there can be several optimizations related to comparisons
this below were some ideas but there is a lot more to be done and this idea is incomplete:
`foo == false` to `not foo` optimization if foo is known to never be `nil`
`foo == true` to `foo` with "convert to bool flag" optimization

-- TODO: note about permissions in linux?

-- TODO: better describe working dir weirdness/running Phobos

-- TODO: add a short list of most useful things Phobos can be used for

maybe option to include single files in compilation
an idea is to allow a list of sources which may either be files or directories
and each entry in `--source` would require a matching one in `--output` which must match in entry type (file or directory)

maybe option to copy files from source to output during compilation
this is unlikely however because it is more part of a build script than a compiler

redundant op_test optimization


very loosely related to phobos:
what I use for setting up to and compiling all factorio mods for testing and fun:
unix-like systems specific:

shell docs stuff and how to stop running shell sub processes or whatever they're called
https://pubs.opengroup.org/onlinepubs/9699919799/
https://unix.stackexchange.com/questions/48425/how-to-stop-the-loop-bash-script-in-terminal
https://unix.stackexchange.com/questions/19816/where-can-i-find-official-posix-and-unix-documentation

extracting all factorio mods
```shell
target=/mnt/big/phobos_temp/extracted
rm -r "$target"
mkdir "$target"
for file in /mnt/big/data/FactorioModsManager/Mods_1.1/*; do
  name=${file##*/}
  unzip $file "*.lua" -d "$target/${name%.*}"
done
```
