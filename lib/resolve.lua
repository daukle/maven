local pom = daukle.require("lib/pom")
local graph = daukle.require("lib/graph")
local platforms = daukle.require("lib/platforms")

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
  local constraints = platforms.constraints(session, resolution.platforms)
  local roots = platforms.versioned(resolution.roots, constraints)
  local compiled, rounds = graph.resolve(session, roots, strategy, constraints)
  local unversioned = session.unversioned
  if resolution.testRoots == nil then return compiled, nil, rounds, unversioned end

  local compile_versions = versions_of(compiled)
  local tested = graph.resolve(session, platforms.versioned(resolution.testRoots, constraints),
                               strategy, constraints)
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

--- Raises one message naming every verb the caller left out of `verbs`.
local function require_verbs(verbs, names)
  local missing = {}
  for index = 1, #names do
    if type(verbs) ~= "table" or verbs[names[index]] == nil then
      missing[#missing + 1] = names[index]
    end
  end
  if #missing == 0 then return end
  error("maven:lib/resolve needs { " .. table.concat(names, ", ") .. " } from its caller;"
        .. " missing: " .. table.concat(missing, ", ") .. ". The caller must declare them in"
        .. " its uses and pass them, as { cache = daukle.cache, fetch = daukle.fetch,"
        .. " pin = daukle.pin }", 0)
end

--- One session per repository, so two resolutions against the same one share
--- every POM they both reach.
local function sessions_of(verbs)
  require_verbs(verbs, { "cache", "fetch" })
  local sessions = {}
  return function(repository)
    local session = sessions[repository]
    if session == nil then
      session = pom.session(repository, verbs)
      sessions[repository] = session
    end
    return session
  end
end

--- The model is memoised for the session by pom.load, so this costs no fetch:
--- resolution has already loaded every module in the closure.
local function publishes_a_jar(session, module)
  return pom.load(session, module.group, module.artifact, module.version).packaging ~= "pom"
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

--[[ The one unpinned fetch in the system, and the reason maven:resolve needs
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
      local pinned = session.verbs.pin{ url = url, as = module.artifact .. " " .. module.version }
      entries[#entries + 1] = {
        artifact = module.artifact, version = module.version,
        url = url, sha256 = pinned.sha256,
      }
    end
  end
  return entries
end

--- @implNote the verbs come from the caller because core hands a module required across a
--- plugin boundary an environment with none. Pinning works only in a --resolve run, and the
--- caller's own "uses" still governs which verbs it has to pass.
--- @param verbs table `{ cache = daukle.cache, fetch = daukle.fetch, pin = daukle.pin }`
--- @param resolutions list of tables carrying exactly the fields read here:
--- `target` (toolchain key, string), `repository` (url string), `strategy` ("highest" or
--- "nearest"; anything else resolves as "highest"), `roots` (list of { group, artifact, version }),
--- `path` (list of key names the pins are appended to), and optionally `testRoots` with
--- `testPath`, both required when either is given, and optionally `platforms`,
--- `{ raise = roots, force = roots }`, whose roots may then omit a version. No other field,
--- `primary` included, is read.
--- @return table the groups output.render takes
local function pinned_groups(resolutions, verbs)
  require_verbs(verbs, { "cache", "fetch", "pin" })
  local session_for = sessions_of(verbs)
  local order, add = grouped_by_target()
  for index = 1, #resolutions do
    local resolution = resolutions[index]
    local session = session_for(resolution.repository)
    local resolved, tested = closures(resolution, session)
    add(resolution.target, { path = resolution.path, entries = pinned_entries(session, resolved) })
    if tested ~= nil then
      add(resolution.target, { path = resolution.testPath, note = TEST_NOTE,
                               entries = pinned_entries(session, tested) })
    end
  end
  return order
end

return {
  closures = closures,
  sessions_of = sessions_of,
  pinned_groups = pinned_groups,
}
