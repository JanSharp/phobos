
-- reference:
-- https://www.w3schools.com/Html/html_xhtml.asp
-- https://www.sitepoint.com/xhtml-web-design-beginners-2/
-- https://stackoverflow.com/questions/97522/what-are-all-the-valid-self-closing-elements-in-xhtml-as-implemented-by-the-maj
-- https://validator.w3.org/#validate-by-upload
-- https://www.w3schools.com/html/html_favicon.asp
-- http://www.webdevout.net/articles/beware-of-xhtml#content_type
-- holy crap I finally found the kind of docs I want:
-- https://developer.mozilla.org/en-US/docs/Web/Guide/HTML/Content_categories#flow_content
-- these only apply to html, not xhtml
-- https://html.spec.whatwg.org/multipage/syntax.html#void-elements

local function serialize(contents, is_xhtml)
  local out = {}
  local c = 0
  local function add(part)
    c = c + 1
    out[c] = part
  end

  local escaped_set = "[^%w \t\n\r_0-9%-/%.]"
  local function escape(str)
    return str:gsub(escaped_set, function(char)
      return string.format("&#%d;", string.byte(char))
    end)
  end

  local add_contents

  local function add_element(elem)
    add("<")
    add(elem.name)
    if elem.attributes then
      for _, attribute in ipairs(elem.attributes) do
        add(" ")
        add(attribute.name)
        add("=\"")
        add(escape(attribute.value))
        add("\"")
      end
    end
    local has_contents = elem.contents and elem.contents[1]
    if not has_contents then
      add("/>")
      return
    end
    add(">")
    add_contents(elem.contents)
    add("</")
    add(elem.name)
    add(">")
  end

  ---@diagnostic disable-next-line:redefined-local
  function add_contents(contents)
    for _, content in ipairs(contents) do
      if type(content) == "string" then
        add(escape(content))
      elseif content.raw then
        add(content.raw)
      else
        add_element(content)
      end
    end
  end

  if is_xhtml then
    add('<?xml version="1.0" encoding="UTF-8"?>\z
      <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">'
    )
  end

  add_contents(contents)

  return table.concat(out)
end

---Just an alias so you don't have to put that magic `true` as the second arg for `serialize`
local function serialize_xhtml(contents)
  return serialize(contents, true)
end

local function new_element(name, attributes, contents)
  return {
    name = name,
    attributes = attributes,
    contents = contents,
  }
end

local function new_attribute(name, value)
  return {name = name, value = value}
end

local function raw(str)
  return {raw = str}
end

return {
  serialize = serialize,
  serialize_xhtml = serialize_xhtml,
  new_element = new_element,
  new_attribute = new_attribute,
  elem = new_element,
  attr = new_attribute,
  raw = raw,
}
