--- A small XML reader, enough for a Maven POM and deliberately no more.
---
--- It is hand written rather than pattern matched because a POM's shape is
--- nested: <dependencyManagement><dependencies><dependency> and
--- <dependencies><dependency> differ only by their ancestor, and a pattern that
--- finds <dependency> anywhere cannot tell a managed version from a declared
--- one. That distinction decides versions, so getting it wrong is silent.
---
--- @implNote parsing by hand also makes the namespace trap structurally
--- impossible rather than merely handled. A qualified reader asks for
--- "{http://maven.apache.org/POM/4.0.0}dependencies" and finds NOTHING in a POM
--- that declares no xmlns, returning an empty dependency list with no error:
--- embedded-redis-1.4.3.pom is exactly that file. Here a tag is the literal
--- text, so a declared namespace changes nothing and a prefix is dropped.

local xml = {}

local ENTITIES = {
  lt = "<", gt = ">", amp = "&", quot = "\"", apos = "'",
}

local function decode_entities(text)
  if not text:find("&", 1, true) then return text end
  return (text:gsub("&(#?%w+);", function(name)
    local named = ENTITIES[name]
    if named ~= nil then return named end
    local code = name:match("^#(%d+)$")
    if code ~= nil then return string.char(tonumber(code) % 256) end
    local hex = name:match("^#[xX](%x+)$")
    if hex ~= nil then return string.char(tonumber(hex, 16) % 256) end
    return "&" .. name .. ";"
  end))
end

-- A prefix names a namespace and never distinguishes two elements in a POM, so
-- <pom:version> and <version> are one tag here.
local function local_name(name)
  local colon = name:find(":", 1, true)
  return colon ~= nil and name:sub(colon + 1) or name
end

local function skip_to(text, position, closing)
  local stop = text:find(closing, position, true)
  if stop == nil then return #text + 1 end
  return stop + #closing
end

--- Parses a document into { tag, children, text }. Attributes are discarded:
--- nothing a POM resolver reads lives in one.
function xml.parse(text)
  local root = nil
  local stack = {}
  local position = 1
  local length = #text

  while position <= length do
    local open = text:find("<", position, true)
    if open == nil then break end

    if open > position then
      local chunk = text:sub(position, open - 1)
      local top = stack[#stack]
      if top ~= nil and chunk:find("%S") then
        top.text = (top.text or "") .. decode_entities(chunk)
      end
    end

    local following = text:sub(open + 1, open + 3)
    if following:sub(1, 3) == "!--" then
      position = skip_to(text, open, "-->")
    elseif following:sub(1, 1) == "?" then
      position = skip_to(text, open, "?>")
    elseif text:sub(open + 1, open + 8) == "![CDATA[" then
      local stop = text:find("]]>", open, true) or (length + 1)
      local top = stack[#stack]
      if top ~= nil then
        top.text = (top.text or "") .. text:sub(open + 9, stop - 1)
      end
      position = stop + 3
    elseif following:sub(1, 1) == "!" then
      position = skip_to(text, open, ">")
    else
      local close = text:find(">", open, true)
      if close == nil then break end
      local body = text:sub(open + 1, close - 1)
      position = close + 1

      if body:sub(1, 1) == "/" then
        local name = local_name(body:sub(2):match("^%s*([^%s/]+)") or "")
        -- A stray close tag is ignored rather than fatal: a POM that a real
        -- resolver accepts must not be refused over a tag this reader does
        -- not model.
        for index = #stack, 1, -1 do
          if stack[index].tag == name then
            for _ = index, #stack do table.remove(stack) end
            break
          end
        end
      else
        local selfclosing = body:sub(-1) == "/"
        if selfclosing then body = body:sub(1, -2) end
        local name = local_name(body:match("^%s*([^%s/]+)") or "")
        if name ~= "" then
          local node = { tag = name, children = {} }
          local top = stack[#stack]
          if top ~= nil then
            top.children[#top.children + 1] = node
          elseif root == nil then
            root = node
          end
          if not selfclosing then stack[#stack + 1] = node end
        end
      end
    end
  end

  return root
end

--- The first direct child with this tag, or nil. Direct, never descendant:
--- see the note at the top about why the distinction decides versions.
function xml.child(node, tag)
  if node == nil then return nil end
  for index = 1, #node.children do
    if node.children[index].tag == tag then return node.children[index] end
  end
  return nil
end

function xml.children(node, tag)
  local found = {}
  if node == nil then return found end
  for index = 1, #node.children do
    if node.children[index].tag == tag then found[#found + 1] = node.children[index] end
  end
  return found
end

--- The trimmed text of a direct child, or nil when the child is absent or
--- empty. Empty and absent are one answer on purpose: <version></version>
--- names no version.
function xml.text(node, tag)
  local child = xml.child(node, tag)
  if child == nil or child.text == nil then return nil end
  local trimmed = child.text:match("^%s*(.-)%s*$")
  if trimmed == "" then return nil end
  return trimmed
end

return xml
