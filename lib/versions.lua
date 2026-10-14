--- One version shared by name across coordinates, `[toolchains.maven.versions]`.
---
--- @implNote substituted inside `parse_coordinate`, before its other checks,
--- so a referenced version meets every check a literal one does and the
--- closure is byte-identical to the literal spelling's (2026-10-14 shared
--- versions design, sections 3 and 5).

local versions = {}

local NAME = "^[%a_][%w_%-%.]*$"

local function kind_of(value)
  if type(value) == "table" and #value > 0 then return "list" end
  return type(value)
end

function versions.read(config)
  local shared = config.versions
  if shared == nil then return {} end
  if type(shared) ~= "table" or #shared > 0 then
    error('"versions" must be a table keyed by name, as [toolchains.maven.versions], not a '
          .. kind_of(shared), 0)
  end
  for name, value in pairs(shared) do
    if type(value) ~= "string" or value == "" then
      error('"versions.' .. tostring(name) .. '" must be a non-empty version string, not a '
            .. type(value), 0)
    end
  end
  return shared
end

--- The coordinate with a whole-field `${name}` version replaced, or unchanged.
--- @param at the coordinate's position, as `coordinates[2]`
function versions.substitute(text, shared, at)
  if text:find("${", 1, true) == nil then return text end
  local head, name = text:match("^([^:]+:[^:]+:)%${([^}]*)}$")
  if head == nil or head:find("${", 1, true) ~= nil then
    error(at .. ' "' .. text .. '" uses "${" other than as the whole version: a reference is'
          .. ' the whole version field, as in "group:artifact:${name}"', 0)
  end
  if name:match(NAME) == nil then
    error(at .. ' "' .. text .. '" references "' .. name .. '", which is not a version name:'
          .. ' start with a letter or "_" and use letters, digits, "_", "-" and "."', 0)
  end
  local value = shared[name]
  if value == nil then
    error(at .. ' "' .. text .. '" references "' .. name .. '", which'
          .. ' [toolchains.maven.versions] does not declare', 0)
  end
  return head .. value
end

return versions
