
return {
  ---how many fields SETLIST sets at once. I don't believe it is a hard limit, but considering
  ---the start index gets shifted by c * fields_per_flush it makes sense to stick to this limit
  fields_per_flush = 50,
}
