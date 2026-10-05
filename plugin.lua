--- daukle/maven: turning coordinates into the pinned blocks a toolchain takes.
---
--- This plugin resolves and pins; it compiles nothing and runs nothing. It is
--- deliberately NOT a library that daukle/java requires, because a required
--- module runs under the DEPENDENT's "uses": a java that required it would
--- have to declare the unpinned fetch itself, advertising that the Java
--- toolchain may fetch unpinned on any run. The generated file is the
--- interface instead. D-77.

daukle.plugin{ api = 1, uses = { "fetch", "cache", "pin", "write" },
               exports = { "lib/xml", "lib/pom", "lib/graph" } }

local pom = daukle.require("lib/pom")
local graph = daukle.require("lib/graph")

local OUTPUT = "classpath.lua"

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

local function strategy_of(config)
  local strategy = config.strategy or DEFAULT_STRATEGY
  if strategy ~= "highest" and strategy ~= "nearest" then
    error('"strategy" must be "highest", which is how Gradle resolves a version conflict, or'
          .. ' "nearest", which is how Maven does; not "' .. tostring(strategy) .. '"', 0)
  end
  return strategy
end

local function repository_of(config)
  local repository = config.repository or pom.CENTRAL
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

local function declared_of(config)
  local listed = config.coordinates
  if listed == nil then
    error('a maven toolchain needs "coordinates": there is nothing to resolve without at least'
          .. ' one "group:artifact:version"', 0)
  end
  if type(listed) ~= "table" then
    error('"coordinates" must be a list of "group:artifact:version" strings, not a '
          .. type(listed), 0)
  end
  local declared = {}
  for index = 1, #listed do
    declared[index] = parse_coordinate(listed[index], index, "coordinates")
  end
  if #declared == 0 then
    error('"coordinates" is empty: there is nothing to resolve', 0)
  end
  return declared
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

local function key_of(module)
  return module.group .. ":" .. module.artifact
end

local function versions_of(resolved)
  local versions = {}
  for index = 1, #resolved do versions[key_of(resolved[index])] = resolved[index].version end
  return versions
end

--[[ daukle/java runs a test against its "classpath" followed by its
     "testClasspath", so the compile entry for a module comes first and wins.
     A module the two closures resolve differently would therefore run the
     tests against the version the COMPILE closure picked, which is neither
     what the test closure chose nor anything the author wrote, and nothing
     would report it. Refused by name, the way a range and a snapshot are. ]]
local function refuse_shadowed(compile_versions, test_resolved)
  local clashes = {}
  for index = 1, #test_resolved do
    local module = test_resolved[index]
    local compile_version = compile_versions[key_of(module)]
    if compile_version ~= nil and compile_version ~= module.version then
      clashes[#clashes + 1] = key_of(module) .. " at " .. compile_version
                              .. " for the compile closure and " .. module.version
                              .. " for the test one"
    end
  end
  if #clashes == 0 then return end
  error("the two closures disagree about " .. #clashes .. " module"
        .. (#clashes == 1 and "" or "s") .. ": " .. table.concat(clashes, "; ")
        .. '. A test runs against "classpath" and then "testClasspath", so the compile version'
        .. " would win and the tests would run against a version neither closure chose. Raise"
        .. ' the version in "coordinates", or drop the test coordinate that pulls the other one',
        0)
end

--- Both closures, with the test one carrying only what the compile one lacks.
--- The second return is nil when the project declares no test coordinates.
local function closures(config, session)
  local strategy = strategy_of(config)
  local declared = declared_of(config)
  -- Every refusal this plugin makes about a coordinate is made before the
  -- first POM is fetched, so bad input costs no network at all.
  local test_roots = test_declared_of(config, declared)

  local compiled, rounds = graph.resolve(session, declared, strategy)
  local unversioned = session.unversioned
  if test_roots == nil then return compiled, nil, rounds, unversioned end

  local compile_versions = versions_of(compiled)
  local tested = graph.resolve(session, test_roots, strategy)
  refuse_shadowed(compile_versions, tested)

  local extra = {}
  for index = 1, #tested do
    if compile_versions[key_of(tested[index])] == nil then extra[#extra + 1] = tested[index] end
  end
  for index = 1, #session.unversioned do
    unversioned[#unversioned + 1] = session.unversioned[index]
  end
  return compiled, extra, rounds, unversioned
end

daukle.toolchain{
  name = "maven",
  generate = function(context)
    local config = config_of(context)
    test_declared_of(config, declared_of(config))
    strategy_of(config)
    repository_of(config)
    return {}
  end,
}

local function quote(text)
  return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

--[[ Lua rather than TOML, and the difference is not cosmetic. A TOML fragment
     has to be PASTED into daukle.toml, which mixes generated rows into the one
     file the user writes by hand. A Lua fragment is daukle.include'd from
     daukle.lua, so the generated pins stay in a file of their own that nobody
     is ever asked to edit, and the user's manifest keeps only what the user
     wrote. It APPENDS rather than assigns, so a hand-written classpath entry
     in daukle.toml survives beside the resolved ones. ]]
local function append_block(lines, name, entries)
  lines[#lines + 1] = "local " .. name .. " = toolchain." .. name .. " or {}"
  lines[#lines + 1] = ""
  for index = 1, #entries do
    local entry = entries[index]
    lines[#lines + 1] = name .. "[#" .. name .. " + 1] = {"
    lines[#lines + 1] = "  url = " .. quote(entry.url) .. ","
    lines[#lines + 1] = "  sha256 = " .. quote(entry.sha256) .. ","
    lines[#lines + 1] = "  as = " .. quote(entry.artifact .. " " .. entry.version) .. ","
    lines[#lines + 1] = "}"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "toolchain." .. name .. " = " .. name
  lines[#lines + 1] = ""
end

local function render(entries, test_entries, key)
  local lines = {
    "-- Generated by maven:resolve. Do not edit: daukle.toml is yours, this is not.",
    "-- Every url and sha256 here was fetched and hashed, because Maven Central",
    "-- publishes no .sha256 for these artifacts.",
    "--",
    "-- Include it from daukle.lua:",
    "--   daukle.include(\"daukle/maven/" .. OUTPUT .. "\")",
    "",
    "local toolchain = daukle.config.toolchains and daukle.config.toolchains." .. key,
    "if toolchain == nil then",
    "  error('daukle.config.toolchains." .. key .. " does not exist: maven resolved for \"'",
    "        .. '" .. key .. "\" but the manifest declares no such toolchain', 0)",
    "end",
    "",
  }
  append_block(lines, "classpath", entries)
  --[[ Only what the compile closure lacks, because daukle/java reaches a test
       through "classpath" followed by "testClasspath" and a module written to
       both would be acquired and placed twice. The versions are known equal
       wherever the two closures overlap, because refuse_shadowed has already
       failed the run otherwise. ]]
  if test_entries ~= nil then
    lines[#lines + 1] = "-- The TEST-ONLY half. daukle/java puts classpath before testClasspath,"
    lines[#lines + 1] = "-- so a module the compile closure already carries is not repeated here."
    append_block(lines, "testClasspath", test_entries)
  end
  return table.concat(lines, "\n")
end

daukle.task{
  name = "maven:resolve",
  run = function(context)
    local config = config_of(context)
    local session = pom.session(repository_of(config))
    local resolved, tested = closures(config, session)

    --[[ The one unpinned fetch in the system, and the reason this task needs
         --resolve. What comes back is the digest core computed while writing
         the file, which is exactly the pin daukle.artifact wants. ]]
    local function pinned_entries(modules)
      if modules == nil then return nil end
      local entries = {}
      for index = 1, #modules do
        local module = modules[index]
        local url = pom.url(session.repository, module.group, module.artifact, module.version,
                            "jar")
        local pinned = daukle.pin{ url = url, as = module.artifact .. " " .. module.version }
        entries[index] = {
          artifact = module.artifact, version = module.version,
          url = url, sha256 = pinned.sha256,
        }
      end
      return entries
    end

    local entries = pinned_entries(resolved)
    local test_entries = pinned_entries(tested)

    local into = config["for"] or "java"
    --[[ committed, because a clone has to build without resolving again: an
         ordinary build may not fetch anything unpinned, so the pins have to be
         in the project's history. It lands in daukle/maven/ rather than
         build/daukle/maven/, which daukle clean deletes. ]]
    local path = daukle.write{ path = OUTPUT, text = render(entries, test_entries, into),
                               committed = true }
    --[[ A plugin has no way to print, so the file IS the report. Raising here
         would fail the task, so the count reaches the user through the
         acquisition report daukle.pin already writes: one line per artifact,
         each naming its url and the digest this run computed. ]]
    return path
  end,
}

--- Resolution alone, with no fetching and no digests, so the closure can be
--- compared against what the old tool produced before anything is downloaded.
--- 21.5 MB separates this task from maven:resolve on the project measured.
daukle.task{
  name = "maven:list",
  run = function(context)
    local config = config_of(context)
    local session = pom.session(repository_of(config))
    local resolved, tested, rounds, unversioned = closures(config, session)

    local lines = {
      "# " .. #resolved .. " modules, " .. rounds .. " rounds, " .. session.fetches
      .. " POM fetches",
      "",
    }
    for index = 1, #resolved do
      local module = resolved[index]
      lines[#lines + 1] = module.group .. ":" .. module.artifact .. ":" .. module.version
    end
    --[[ The test-only modules carry a prefix rather than a heading, because a
         heading is a comment and the suite compares the file with the comments
         stripped and the lines sorted, so a module's half would not survive. ]]
    if tested ~= nil then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "# " .. #tested .. " more for the test closure"
      for index = 1, #tested do
        local module = tested[index]
        lines[#lines + 1] = "test " .. module.group .. ":" .. module.artifact .. ":"
                            .. module.version
      end
    end
    if #unversioned > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "# dependencies reached with no version, and therefore skipped:"
      for index = 1, #unversioned do
        lines[#lines + 1] = "#   " .. unversioned[index]
      end
    end
    return daukle.write{ path = "resolved.txt", text = table.concat(lines, "\n") .. "\n" }
  end,
}
