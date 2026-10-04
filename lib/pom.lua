--- Reading a POM into the three things resolution needs: its properties, the
--- versions it manages, and the dependencies it declares.
---
--- A POM is never one file. Its parent chain supplies properties and managed
--- versions, and an imported BOM supplies more, so "read a POM" means fetching
--- several and folding them in the right order. Measured on one real project:
--- twenty jars cost sixty three POM fetches.

local xml = daukle.require("lib/xml")

local pom = {}

local CENTRAL = "https://repo1.maven.org/maven2"

function pom.url(repository, group, artifact, version, extension)
  return repository .. "/" .. group:gsub("%.", "/") .. "/" .. artifact .. "/" .. version
         .. "/" .. artifact .. "-" .. version .. "." .. extension
end

pom.CENTRAL = CENTRAL

local function read_dependency(node)
  local exclusions = {}
  local block = xml.child(node, "exclusions")
  if block ~= nil then
    local listed = xml.children(block, "exclusion")
    for index = 1, #listed do
      exclusions[#exclusions + 1] = {
        group = xml.text(listed[index], "groupId"),
        artifact = xml.text(listed[index], "artifactId"),
      }
    end
  end
  return {
    group = xml.text(node, "groupId"),
    artifact = xml.text(node, "artifactId"),
    version = xml.text(node, "version"),
    scope = xml.text(node, "scope") or "compile",
    kind = xml.text(node, "type") or "jar",
    classifier = xml.text(node, "classifier"),
    optional = xml.text(node, "optional") == "true",
    exclusions = exclusions,
  }
end

--- Expands ${...} against a property table. Bounded rather than recursive:
--- a POM may define a property in terms of itself and a resolver that trusted
--- the data would not return.
local function interpolate(value, properties)
  if value == nil then return nil end
  for _ = 1, 8 do
    local name = value:match("%${([^}]+)}")
    if name == nil then return value end
    local replacement = properties[name]
    if replacement == nil then return value end
    value = value:gsub("%${" .. name:gsub("(%W)", "%%%1") .. "}", (replacement:gsub("%%", "%%%%")), 1)
  end
  return value
end

pom.interpolate = interpolate

local function key_of(group, artifact)
  return (group or "?") .. ":" .. (artifact or "?")
end

pom.key_of = key_of

--- Fetches one POM's text, through the cache so a second run of a resolve
--- costs no request. The cache key is the coordinate, which is immutable on
--- Central: a released version is never republished.
---
--- @implNote a POM that cannot be fetched RAISES and fails the task. That is
--- not a choice: the sandbox exposes no pcall, so a plugin cannot catch a
--- failed daukle.fetch and carry on. It is also the right answer, because a
--- closure missing one POM is a closure missing whatever that POM declared,
--- and the alternative is a shorter classpath with no diagnostic.
local function fetch_text(session, group, artifact, version)
  local coordinate = group .. ":" .. artifact .. ":" .. version
  local cached = session.texts[coordinate]
  if cached ~= nil then return cached end

  local url = pom.url(session.repository, group, artifact, version, "pom")
  local text = daukle.cache("maven-pom", version, group .. "_" .. artifact,
                            function() return daukle.fetch(url) end)
  session.fetches = session.fetches + 1
  session.texts[coordinate] = text
  return text
end

local function unresolved(text)
  return text ~= nil and text:find("%${") ~= nil
end

local function collect(session, group, artifact, version, into, depth)
  if group == nil or artifact == nil or version == nil then return end
  --[[ A ${...} that survived interpolation names a property no POM in the
       chain defined. Fetching it asks Central for a literal "${x}" and gets a
       404, which with no pcall would end the whole resolve over one unused
       managed entry. ]]
  if unresolved(group) or unresolved(artifact) or unresolved(version) then
    into.unexpanded[#into.unexpanded + 1] = group .. ":" .. artifact .. ":" .. version
    return
  end
  if depth > 16 then
    error("a POM parent chain under " .. key_of(group, artifact) .. " is deeper than 16", 0)
  end
  local text = fetch_text(session, group, artifact, version)
  if text == nil then return end
  local root = xml.parse(text)
  if root == nil then return end

  -- The parent is folded in FIRST so the child's own values overwrite it,
  -- which is the direction Maven inherits in.
  local parent = xml.child(root, "parent")
  if parent ~= nil then
    into.parents = into.parents + 1
    collect(session, xml.text(parent, "groupId"), xml.text(parent, "artifactId"),
            xml.text(parent, "version"), into, depth + 1)
  end

  local properties = xml.child(root, "properties")
  if properties ~= nil then
    for index = 1, #properties.children do
      local child = properties.children[index]
      into.properties[child.tag] = child.text ~= nil and child.text:match("^%s*(.-)%s*$") or ""
    end
  end
  into.properties["project.version"] = version
  into.properties["project.groupId"] = group
  into.properties["pom.version"] = version

  local management = xml.child(root, "dependencyManagement")
  if management ~= nil then
    local listed = xml.children(xml.child(management, "dependencies"), "dependency")
    for index = 1, #listed do
      local entry = read_dependency(listed[index])
      if entry.scope == "import" and entry.kind == "pom" then
        into.imports = into.imports + 1
        --[[ A BOM's managed versions interpolate against the BOM's OWN
             properties, not the importer's. jackson-bom manages
             jackson-databind as ${jackson.version.databind}, a property it
             defines and its importer does not, so folding the raw strings in
             and expanding later leaves a literal ${...} in a url. ]]
        local imported = pom.empty()
        collect(session, interpolate(entry.group, into.properties),
                interpolate(entry.artifact, into.properties),
                interpolate(entry.version, into.properties), imported, depth + 1)
        pom.settle(imported)
        for managed_key, managed in pairs(imported.managed) do
          if into.managed[managed_key] == nil then into.managed[managed_key] = managed end
        end
      else
        into.managed[key_of(entry.group, entry.artifact)] = entry
      end
    end
  end

  local own = xml.child(root, "dependencies")
  if own ~= nil then
    local listed = xml.children(own, "dependency")
    for index = 1, #listed do
      into.declared[#into.declared + 1] = read_dependency(listed[index])
    end
  end
end

function pom.empty()
  return { properties = {}, managed = {}, declared = {}, parents = 0, imports = 0,
           unexpanded = {} }
end

--- Managed versions may name a property a LATER parent defined, so they are
--- expanded once the whole chain is folded in rather than as each is read.
function pom.settle(model)
  for _, managed in pairs(model.managed) do
    managed.version = interpolate(managed.version, model.properties)
  end
end

function pom.session(repository)
  return { repository = repository or CENTRAL, texts = {}, models = {}, fetches = 0 }
end

--- The folded model for one coordinate, memoised for the session.
function pom.load(session, group, artifact, version)
  local coordinate = group .. ":" .. artifact .. ":" .. version
  local cached = session.models[coordinate]
  if cached ~= nil then return cached end

  local model = pom.empty()
  collect(session, group, artifact, version, model, 0)
  pom.settle(model)
  session.models[coordinate] = model
  return model
end

return pom
