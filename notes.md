
for the Phobos factorio mod add commands for running Phobos.\
`/pho`, `/s-pho`, `/phobos`, `/silent-phobos`, `/measured-phobos` or so

with types there can be several optimizations related to comparisons
this below were some ideas but there is a lot more to be done and this idea is incomplete:
`foo == false` to `not foo` optimization if foo is known to never be `nil`
`foo == true` to `foo` with "convert to bool flag" optimization

-- TODO: note about permissions in linux?

-- TODO: better describe working dir weirdness/running Phobos

-- TODO: add a short list of most useful things Phobos can be used for

-- TODO: option to include single files in compilation

-- TODO: option to copy files from source to output during compilation
