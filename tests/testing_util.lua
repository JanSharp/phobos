
local test_source = "=(test)"

local serpent_opts_for_ast = {
  keyignore = {
    first = true,
    last = true,
    next = true,
    prev = true,
    scope = true,
    list = true,
    parent_scope = true,
  },
  comment = true,
}

return {
  test_source = test_source,
  serpent_opts_for_ast = serpent_opts_for_ast,
}
