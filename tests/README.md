
# Conventions

## Data Centric Test Generation

<!-- cSpell:ignore ipairs -->

When writing tests which should test different values but are otherwise effectively identical, it is very highly recommended to use the following approach:

- Create a table - a dataset - containing all values that should be tested
- Iterate this table using ipairs
- For each iteration call `add_test` (sometimes even multiple times)

If the dataset is only used once, don't put it in a local.

If the dataset is an array of tables, use the variable name `data` if possible: `for _, data in ipairs{...}`.

If the dataset is an array of tables, the tables should use named keys, it should not be an array.

The most common example:

```lua
for _, data in ipairs{
  {label = "1 value", str = "foo", count = 1},
  {label = "2 values", str = "foo, bar", count = 2},
  {label = "3 values", str = "foo, bar, baz", count = 3},
}
do
  add_test("test with "..data.label, function()
    -- perform test
  end)
end
```
