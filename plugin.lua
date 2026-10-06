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

--- The key a resolution's pins are appended to, refused unless the generated
--- file could assign to it.
local function into_of(entry, index)
  local at = "resolve[" .. index .. '].into'
  local into = entry.into
  if into == nil then
    error(at .. ' is missing: a resolution has to name the toolchain key its pins are appended'
          .. ' to. There is no default, because a closure that lands on a key nothing reads'
          .. ' builds and resolves and changes nothing', 0)
  end
  if type(into) ~= "string" then
    error(at .. " must be a string, not a " .. type(into), 0)
  end
  if into:find("^[%a_][%w_]*$") == nil then
    error(at .. ' "' .. into .. '" is not a plain key name. The generated file assigns'
          .. ' toolchain.<key>, so it must be a letter or underscore followed by letters,'
          .. ' digits or underscores', 0)
  end
  return into
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
      resolutions[#resolutions + 1] = {
        repository = repository_of(entry, repository),
        strategy = strategy_of(entry, strategy),
        target = entry["for"] or target,
        into = into_of(entry, index),
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

--- One resolution's modules: its own closure, and the test-only half when it
--- carries test roots. The second return is nil when it does not.
local function closures(resolution, session)
  local strategy = resolution.strategy
  local compiled, rounds = graph.resolve(session, resolution.roots, strategy)
  local unversioned = session.unversioned
  if resolution.testRoots == nil then return compiled, nil, rounds, unversioned end

  local compile_versions = versions_of(compiled)
  local tested = graph.resolve(session, resolution.testRoots, strategy)
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

--- One session per repository, so two resolutions against the same one share
--- every POM they both reach.
local function sessions_of()
  local sessions = {}
  return function(repository)
    local session = sessions[repository]
    if session == nil then
      session = pom.session(repository)
      sessions[repository] = session
    end
    return session
  end
end

daukle.toolchain{
  name = "maven",
  generate = function(context)
    resolutions_of(config_of(context))
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
local function append_block(lines, block)
  local name = block.name
  if block.note ~= nil then
    for index = 1, #block.note do lines[#lines + 1] = "  -- " .. block.note[index] end
  end
  lines[#lines + 1] = "  local " .. name .. " = toolchain." .. name .. " or {}"
  lines[#lines + 1] = ""
  for index = 1, #block.entries do
    local entry = block.entries[index]
    lines[#lines + 1] = "  " .. name .. "[#" .. name .. " + 1] = {"
    lines[#lines + 1] = "    url = " .. quote(entry.url) .. ","
    lines[#lines + 1] = "    sha256 = " .. quote(entry.sha256) .. ","
    lines[#lines + 1] = "    as = " .. quote(entry.artifact .. " " .. entry.version) .. ","
    lines[#lines + 1] = "  }"
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  toolchain." .. name .. " = " .. name
  lines[#lines + 1] = ""
end

--[[ One scope per target toolchain, with no special case for there being only
     one. A renderer that modelled exactly one target is the shape D-111 found
     wrong everywhere else in this org, and the cost of the uniform form is one
     indent in a file nobody edits by hand. ]]
local function append_target(lines, group)
  local key = group.target
  lines[#lines + 1] = "do"
  lines[#lines + 1] = "  local toolchain = daukle.config.toolchains and daukle.config.toolchains."
                      .. key
  lines[#lines + 1] = "  if toolchain == nil then"
  lines[#lines + 1] = "    error('daukle.config.toolchains." .. key .. " does not exist: maven"
                      .. " resolved for \"'"
  lines[#lines + 1] = "          .. '" .. key .. "\" but the manifest declares no such"
                      .. " toolchain', 0)"
  lines[#lines + 1] = "  end"
  lines[#lines + 1] = ""
  for index = 1, #group.blocks do append_block(lines, group.blocks[index]) end
  lines[#lines] = "end"
  lines[#lines + 1] = ""
end

--- The model is memoised for the session by pom.load, so this costs no fetch:
--- resolution has already loaded every module in the closure.
local function publishes_a_jar(session, module)
  return pom.load(session, module.group, module.artifact, module.version).packaging ~= "pom"
end

local function render(groups)
  local lines = {
    "-- Generated by maven:resolve. Do not edit: daukle.toml is yours, this is not.",
    "-- Every url and sha256 here was fetched and hashed, because Maven Central",
    "-- publishes no .sha256 for these artifacts.",
    "--",
    "-- Include it from daukle.lua:",
    "--   daukle.include(\"daukle/maven/" .. OUTPUT .. "\")",
    "",
  }
  for index = 1, #groups do append_target(lines, groups[index]) end
  return table.concat(lines, "\n")
end

--[[ Only what the compile closure lacks, because daukle/java reaches a test
     through "classpath" followed by "testClasspath" and a module written to
     both would be acquired and placed twice. The versions are known equal
     wherever the two closures overlap, because refuse_shadowed has already
     failed the run otherwise. ]]
local TEST_NOTE = {
  "The TEST-ONLY half. daukle/java puts classpath before testClasspath,",
  "so a module the compile closure already carries is not repeated here.",
}

--- The targets in declaration order, each carrying the blocks resolved for it.
local function grouped_by_target()
  local groups, order = {}, {}
  return order, function(target, block)
    local group = groups[target]
    if group == nil then
      group = { target = target, blocks = {} }
      groups[target] = group
      order[#order + 1] = group
    end
    group.blocks[#group.blocks + 1] = block
  end
end

daukle.task{
  name = "maven:resolve",
  run = function(context)
    local resolutions = resolutions_of(config_of(context))
    local session_for = sessions_of()

    --[[ The one unpinned fetch in the system, and the reason this task needs
         --resolve. What comes back is the digest core computed while writing
         the file, which is exactly the pin daukle.artifact wants. ]]
    local function pinned_entries(session, modules)
      local entries = {}
      for index = 1, #modules do
        local module = modules[index]
        --[[ A pom-packaged module publishes no jar, so pinning one asks the
             repository for a file that was never there and gets a 404. It
             stays in the CLOSURE, because what it declares is real: that is
             what a BOM is, and what a Gradle plugin marker is, whose single
             dependency is the plugin itself. ]]
        if publishes_a_jar(session, module) then
          local url = pom.url(session.repository, module.group, module.artifact, module.version,
                              "jar")
          local pinned = daukle.pin{ url = url, as = module.artifact .. " " .. module.version }
          entries[#entries + 1] = {
            artifact = module.artifact, version = module.version,
            url = url, sha256 = pinned.sha256,
          }
        end
      end
      return entries
    end

    local groups, add = grouped_by_target()
    for index = 1, #resolutions do
      local resolution = resolutions[index]
      local session = session_for(resolution.repository)
      local resolved, tested = closures(resolution, session)
      add(resolution.target, { name = resolution.into, entries = pinned_entries(session, resolved) })
      if tested ~= nil then
        add(resolution.target, { name = resolution.testInto, note = TEST_NOTE,
                                 entries = pinned_entries(session, tested) })
      end
    end

    --[[ committed, because a clone has to build without resolving again: an
         ordinary build may not fetch anything unpinned, so the pins have to be
         in the project's history. It lands in daukle/maven/ rather than
         build/daukle/maven/, which daukle clean deletes. ]]
    local path = daukle.write{ path = OUTPUT, text = render(groups), committed = true }
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
    local resolutions = resolutions_of(config_of(context))
    local session_for = sessions_of()
    local lines, skipped = {}, {}

    --[[ A module carries the name of the key it is destined for, as a PREFIX
         rather than under a heading: a heading is a comment, and the suite
         compares this file with the comments stripped and the lines sorted, so
         a closure's half would not survive one. The PRIMARY closure is bare,
         because it was bare before there was more than one resolution and a
         generated line that moves is a diff nobody asked for. ]]
    local function append_modules(modules, prefix)
      for index = 1, #modules do
        local module = modules[index]
        lines[#lines + 1] = prefix .. module.group .. ":" .. module.artifact .. ":"
                            .. module.version
      end
    end

    for index = 1, #resolutions do
      local resolution = resolutions[index]
      local session = session_for(resolution.repository)
      local resolved, tested, rounds, unversioned = closures(resolution, session)
      if #lines > 0 then lines[#lines + 1] = "" end
      lines[#lines + 1] = "# " .. #resolved .. " modules for " .. resolution.target .. "."
                          .. resolution.into .. ", " .. rounds .. " rounds, " .. session.fetches
                          .. " POM fetches"
      lines[#lines + 1] = ""
      append_modules(resolved, resolution.primary and "" or resolution.into .. " ")
      if tested ~= nil then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "# " .. #tested .. " more for the test closure"
        append_modules(tested, "test ")
      end
      for position = 1, #unversioned do skipped[#skipped + 1] = unversioned[position] end
    end

    if #skipped > 0 then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "# dependencies reached with no version, and therefore skipped:"
      for index = 1, #skipped do
        lines[#lines + 1] = "#   " .. skipped[index]
      end
    end
    return daukle.write{ path = "resolved.txt", text = table.concat(lines, "\n") .. "\n" }
  end,
}
