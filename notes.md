
for the phobos factorio mod add commands for running phobos.\
`/pho`, `/s-pho`, `/phobos`, `/silent-phobos`, `/measured-phobos` or so

If debug symbols was to support/allow for combined line information it would very most likely be 3 digits (least significant) for the column and the rest for the line, only stored in the regular line debug symbols. Phobos debug symbols would most likely just have a flag indicating wether or not these combined line numbers are used and the array of column numbers would be empty (but still exist because that's easier to consume).

Phobos debug symbols should not contain duplicate data which is already in regular debug symbols.

If the phobos debug symbol signature version number exceeds 1 byte, just extend the size of the signature for the version number. Specifically as soon as the byte is `ff` it has to already extend to the next byte which would just be `00` at that point in order to not break trying to load newer versions in that edge case.

`not not not` "folding" optimization

with types there can be several optimizations related to comparisons
this below were some ideas but there is a lot more to be done and this idea is incomplete:
`foo == false` to `not foo` optimization if foo is known to never be `nil`
`foo == true` to `foo` with "convert to bool flag" optimization
