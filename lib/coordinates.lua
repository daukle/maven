local pom = daukle.require("lib/pom")

--[[ Gradle resolves a conflict by taking the HIGHEST version and Maven by
     taking the NEAREST, and on the first real project measured they disagree
     about six of twenty modules. The default is Gradle's because a project
     arriving here is leaving Gradle, and "100% replace the original tool"
     is not met by a resolver that silently re-versions a third of a closure.
     It is a key rather than an inference: there is nothing left in a daukle
     project to infer the old tool from. ]]
local DEFAULT_STRATEGY = "highest"

local function config_of(context)
  return context.toolchain ~= nil and context.toolchain.config or context.config
end

local function strategy_of(config, fallback)
  local strategy = config.strategy or fallback or DEFAULT_STRATEGY
  if strategy ~= "highest" and strategy ~= "nearest" then
    error('"strategy" must be "highest", which is how Gradle resolves a version conflict, or'
          .. ' "nearest", which is how Maven does; not "' .. tostring(strategy) .. '"', 0)
  end
  return strategy
end

local function repository_of(config, fallback)
  local repository = config.repository or fallback or pom.CENTRAL
  if type(repository) ~= "string" then
    error('"repository" must be a url string, not a ' .. type(repository), 0)
  end
  return (repository:gsub("/+$", ""))
end

--- Splits "group:artifact:version" and refuses everything this resolver does
--- not model, rather than half supporting it. A range and a snapshot are both
--- moving targets, which is the one thing daukle does not have.
local function parse_coordinate(text, index, key)
  local at = key .. "[" .. index .. "]"
  if type(text) ~= "string" then
    error(at .. " must be a string, not a " .. type(text), 0)
  end
  local group, artifact, version = text:match("^([^:]+):([^:]+):([^:]+)$")
  if group == nil then
    error(at .. ' "' .. text .. '" is not "group:artifact:version"', 0)
  end
  if version:find("^[%[%(]") ~= nil then
    error(at .. ' "' .. text .. '" names a version RANGE. This resolver'
          .. ' pins, and a range is decided by whatever the registry holds at the moment it is'
          .. ' read, so two machines would not agree', 0)
  end
  if version:find("SNAPSHOT", 1, true) ~= nil then
    error(at .. ' "' .. text .. '" names a SNAPSHOT, which is republished'
          .. ' under one name and so cannot be pinned', 0)
  end
  return { group = group, artifact = artifact, version = version }
end

local function parse_coordinates(listed, key)
  if type(listed) ~= "table" then
    error('"' .. key .. '" must be a list of "group:artifact:version" strings, not a '
          .. type(listed), 0)
  end
  local declared = {}
  for index = 1, #listed do
    declared[index] = parse_coordinate(listed[index], index, key)
  end
  if #declared == 0 then
    error('"' .. key .. '" is empty: there is nothing to resolve', 0)
  end
  return declared
end

--- The roots of the primary closure, or nil when the block declares none.
---
--- @implNote nil is only legal when a `resolve` entry supplies a closure
--- instead, which is why the absence is reported by the caller rather than
--- here: a block with neither is the real error and this function cannot see
--- the other half.
local function declared_of(config)
  if config.coordinates == nil then return nil end
  return parse_coordinates(config.coordinates, "coordinates")
end

--- The roots of the TEST closure, or nil when the project declares none.
---
--- @implNote they are the compile coordinates PLUS the test ones, because a
--- test compiles and runs against the project's own dependencies as well as
--- its test-only ones. The result is a second INDEPENDENT resolve rather than
--- the compile closure with extras bolted on: Gradle resolves
--- testRuntimeClasspath as its own configuration, so a test dependency may
--- raise a version the compile side never sees.
local function test_declared_of(config, declared)
  local listed = config.testCoordinates
  if listed == nil then return nil end
  if type(listed) ~= "table" then
    error('"testCoordinates" must be a list of "group:artifact:version" strings, not a '
          .. type(listed), 0)
  end
  if #listed == 0 then
    error('"testCoordinates" is empty: leave the key out rather than declaring no test'
          .. ' dependencies', 0)
  end
  local roots = {}
  for index = 1, #declared do roots[index] = declared[index] end
  for index = 1, #listed do
    roots[#roots + 1] = parse_coordinate(listed[index], index, "testCoordinates")
  end
  return roots
end

local function refuse_a_key_that_is_not_plain(key, at)
  if key:find("^[%a_][%w_]*$") == nil then
    error(at .. ' "' .. key .. '" is not a plain key name. The generated file assigns'
          .. ' toolchain.<key>, so it must be a letter or underscore followed by letters,'
          .. ' digits or underscores', 0)
  end
end

--- A list `into`, the path from the toolchain's own table to the key appended to.
---
--- @implNote a list rather than a dotted string, because a module name may
--- itself hold a ".", and a dotted path would split it into a wrong path with no
--- error. Only the LAST component is the key the pins land on, so only it must
--- be a plain name; the others are rendered quoted and may hold a "/".
local function path_of(into, at)
  if #into == 0 then
    error(at .. " is an empty list: a path names at least the key the pins land on", 0)
  end
  for index = 1, #into do
    local component = into[index]
    if type(component) ~= "string" or component == "" or component:find("%c") ~= nil then
      error(at .. "[" .. index .. "] must be a non-empty string with no control character", 0)
    end
  end
  refuse_a_key_that_is_not_plain(into[#into], at .. "[" .. #into .. "]")
  return into
end

--- The path a resolution's pins are appended to, refused unless the generated
--- file could assign to it. A plain string is a path of one key.
local function into_of(entry, index)
  local at = "resolve[" .. index .. '].into'
  local into = entry.into
  if into == nil then
    error(at .. ' is missing: a resolution has to name the toolchain key its pins are appended'
          .. ' to. There is no default, because a closure that lands on a key nothing reads'
          .. ' builds and resolves and changes nothing', 0)
  end
  if type(into) == "table" then return path_of(into, at) end
  if type(into) ~= "string" then
    error(at .. " must be a string, not a " .. type(into), 0)
  end
  refuse_a_key_that_is_not_plain(into, at)
  return { into }
end

--[[ Two resolutions appending to one key of one toolchain would interleave two
     closures in a list whose ORDER decides which version of a shared module is
     seen first, and nothing downstream could tell them apart. It is the same
     failure refuse_shadowed names for the compile and test pair, one level up,
     so it is refused the same way rather than merged. ]]
local function refuse_repeated_keys(resolutions)
  local seen = {}
  for index = 1, #resolutions do
    local resolution = resolutions[index]
    for _, into in ipairs({ resolution.into, resolution.testInto }) do
      if into ~= nil then
        local at = resolution.target .. "." .. into
        if seen[at] ~= nil then
          error("two resolutions both append to " .. at .. ', so one closure would be read'
                .. ' before the other and a module they disagree about would resolve to'
                .. ' whichever came first. Give one of them its own "into", or merge their'
                .. ' coordinates into a single resolution', 0)
        end
        seen[at] = true
      end
    end
  end
end

--- Every independent resolution this block declares, the primary one first.
---
--- @implNote the primary closure is NOT an entry of `resolve` and cannot be
--- written as one. Its test half takes the compile coordinates as its own
--- roots and is refused when the two disagree, which ties the pair together;
--- a `resolve` entry is independent of everything else here. The buildscript
--- classpath a Gradle plugin is applied from is the measured case: it shares
--- no module with the classpath the project compiles against, and it comes
--- from a different repository.
local function resolutions_of(config)
  local repository = repository_of(config)
  local strategy = strategy_of(config)
  local target = config["for"] or "java"
  local declared = declared_of(config)
  local resolutions = {}

  if declared ~= nil then
    local test_roots = test_declared_of(config, declared)
    resolutions[1] = {
      primary = true,
      repository = repository, strategy = strategy, target = target,
      into = "classpath", testInto = test_roots ~= nil and "testClasspath" or nil,
      path = { "classpath" }, testPath = test_roots ~= nil and { "testClasspath" } or nil,
      roots = declared, testRoots = test_roots,
    }
  elseif config.testCoordinates ~= nil then
    error('"testCoordinates" needs "coordinates": a test closure resolves the compile'
          .. ' coordinates as well as its own, so there is no test half without a compile half',
          0)
  end

  local listed = config.resolve
  if listed ~= nil then
    if type(listed) ~= "table" or #listed == 0 then
      error('"resolve" must be a list of resolutions, each a [[toolchains.maven.resolve]] table'
            .. ' naming its own "coordinates" and the "into" key they are appended to', 0)
    end
    for index = 1, #listed do
      local entry = listed[index]
      if type(entry) ~= "table" then
        error("resolve[" .. index .. "] must be a table, not a " .. type(entry), 0)
      end
      local path = into_of(entry, index)
      resolutions[#resolutions + 1] = {
        repository = repository_of(entry, repository),
        strategy = strategy_of(entry, strategy),
        target = entry["for"] or target,
        into = table.concat(path, "."),
        path = path,
        roots = parse_coordinates(entry.coordinates, "resolve[" .. index .. "].coordinates"),
      }
    end
  end

  if #resolutions == 0 then
    error('a maven toolchain needs "coordinates": there is nothing to resolve without at least'
          .. ' one "group:artifact:version"', 0)
  end
  refuse_repeated_keys(resolutions)
  return resolutions
end

return {
  config_of = config_of,
  resolutions_of = resolutions_of,
}
