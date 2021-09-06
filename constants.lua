
return {
  ---how many fields SETLIST sets at once. I don't believe it is a hard limit, but considering
  ---the start index gets shifted by c * fields_per_flush it makes sense to stick to this limit
  fields_per_flush = 50,

  ---phobos debug symbol signature\
  ---last byte is a format version number
  ---which just starts at 0 and counts up
  phobos_signature = "\x1bPho\x10\x42\xff\x00",
}
