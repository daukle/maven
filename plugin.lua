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
local coordinates = daukle.require("lib/coordinates")

local OUTPUT = "classpath.lua"

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
    coordinates.resolutions_of(coordinates.config_of(context))
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
    local resolutions = coordinates.resolutions_of(coordinates.config_of(context))
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
    local resolutions = coordinates.resolutions_of(coordinates.config_of(context))
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
