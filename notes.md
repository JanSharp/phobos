
for the Phobos factorio mod add commands for running Phobos.\
`/pho`, `/s-pho`, `/phobos`, `/silent-phobos`, `/measured-phobos` or so

with types there can be several optimizations related to comparisons
this below were some ideas but there is a lot more to be done and this idea is incomplete:
`foo == false` to `not foo` optimization if foo is known to never be `nil`
`foo == true` to `foo` with "convert to bool flag" optimization

-- TODO: osx is actually macOS nowadays. Incorporate that into the readme somehow

-- TODO: make thumbnail and icons. Or rather, ask for help

-- TODO: write initial changelog

-- TODO: proof read readme and maybe add library note

-- TODO: change all requires in the factorio mod to include the `__phobos__.` prefix and make sure every file is required with the same string. This requires some kind of injection system during compilation
