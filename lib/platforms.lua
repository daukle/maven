--- A resolution's platforms, turned into one constraint per module they manage:
--- what Gradle's `platform()` and `enforcedPlatform()` and Maven's imported BOM
--- do to a closure, measured against Gradle 9.6.0 and 7.6.4 (D-185).

local graph = daukle.require("lib/graph")
local pom = daukle.require("lib/pom")

local platforms = {}

local JAR_SUFFIX = ":jar:"

--- Every jar a BOM manages, as { [group:artifact] = version }.
--- @implNote only the plain jar entries: a typed or classified entry manages an
--- artifact the closure never pins, and its version is not the module's.
local function managed_jars(session, bom)
  local model = pom.load(session, bom.group, bom.artifact, bom.version)
  local found = {}
  for managed_key, entry in pairs(model.managed) do
    local key = managed_key:sub(1, -(#JAR_SUFFIX + 1))
    if managed_key:sub(-#JAR_SUFFIX) == JAR_SUFFIX and entry.version ~= nil
       and entry.version:find("%${") == nil then
      found[key] = entry.version
    end
  end
  return found
end

local function label(bom)
  return bom.group .. ":" .. bom.artifact .. ":" .. bom.version
end

--- @return { [group:artifact] = { raise?, force?, forced_by? } }
--- @implNote two platforms raising one module keep the higher, as two Gradle
--- constraints do; two enforced ones that disagree are refused, because Gradle
--- fails that resolution and no order between them is the right one.
function platforms.constraints(session, declared)
  local constraints = {}
  if declared == nil then return constraints end
  for _, bom in ipairs(declared.raise) do
    for key, version in pairs(managed_jars(session, bom)) do
      local constraint = constraints[key] or {}
      if constraint.raise == nil or graph.is_higher(version, constraint.raise) then
        constraint.raise = version
      end
      constraints[key] = constraint
    end
  end
  for _, bom in ipairs(declared.force) do
    for key, version in pairs(managed_jars(session, bom)) do
      local constraint = constraints[key] or {}
      if constraint.force ~= nil and constraint.force ~= version then
        error("enforcedPlatforms disagree about " .. key .. ": " .. constraint.forced_by .. " forces "
              .. constraint.force .. " and " .. label(bom) .. " forces " .. version
              .. ", and two strict versions have no winner", 0)
      end
      constraint.force = version
      constraint.forced_by = constraint.forced_by or label(bom)
      constraints[key] = constraint
    end
  end
  return constraints
end

--- The roots with every versionless coordinate given its platform's version.
function platforms.versioned(roots, constraints)
  if roots == nil then return nil end
  local versioned = {}
  for index, root in ipairs(roots) do
    if root.version ~= nil then
      versioned[index] = root
    else
      local constraint = constraints[pom.key_of(root.group, root.artifact)]
      local version = constraint ~= nil and (constraint.force or constraint.raise) or nil
      if version == nil then
        error(root.at .. ' "' .. root.group .. ":" .. root.artifact .. '" names no version, and'
              .. " no platform the resolution declares manages it", 0)
      end
      versioned[index] = { group = root.group, artifact = root.artifact, version = version }
    end
  end
  return versioned
end

return platforms
