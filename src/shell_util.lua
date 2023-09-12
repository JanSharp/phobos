
local Path = require("lib.path")
local util = require("util")

local cross_platform_explanation = "And to make sure that when Phobos runs on a Unix like system it also \z
  runs on Windows, this is an error regardless of what environment we are in."

local function escape_arg(arg)
  local annoying = arg:match("[\"\n]")
  if annoying == "\"" then
    util.abort("Cannot escape argument '"..arg.."', because it contains a \" (double quote), and \z
      I've honestly given up on trying to figure out how to reliably - or at all, even - escape a \z
      double quote on Windows. "..cross_platform_explanation.."\n\z
      Oh and if you want to know why I decided against supporting double quotes in arguments, here:\n\z
      (Warning: I have not checked if all these sites are safe, visit at your own risk.)\n\z
      https://ss64.com/nt/syntax-esc.html\n\z
      https://www.gnu.org/software/gawk/manual/html_node/DOS-Quoting.html\n\z
      https://stackoverflow.com/questions/6828751/batch-character-escaping\n\z
      https://stackoverflow.com/questions/7760545/escape-double-quotes-in-parameter\n\z
      http://www.windowsinspired.com/understanding-the-command-line-string-and-arguments-received-by-a-windows-program/\n\z
      https://stackoverflow.com/questions/4094699/how-does-the-windows-command-interpreter-cmd-exe-parse-scripts/4095133#4095133\n\z
      \n\z
      And for completeness, here's how to do it in Unix shell:\n\z
      https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_02_03"
    )
  elseif annoying == "\n" then
    util.abort("Cannot escape argument '"..arg.."', because it contains a \\n (newline), and \z
      after trying to deal with double quote escaping on Windows, I subsequently decided not to \z
      care about newlines either. I believe something like \"foo bar\"^<\\n>\"baz hi\" (where <\\n> \z
      is an actual newline character) might work, but I don't know. "..cross_platform_explanation.."\n\z
      \n\z
      And for completeness, here's how to do it in Unix shell:\n\z
      https://pubs.opengroup.org/onlinepubs/9699919799/utilities/V3_chap02.html#tag_18_02_03"
    )
  end
  return Path.is_windows()
    and '"'..arg..'"' -- since we simply don't handle `"` and `\n` this is super easy
    or '"'..arg:gsub("[$`\"\\\n]", "\\%0")..'"' -- this could escape everything, though it's not fully tested
end

return {
  escape_arg = escape_arg,
}
