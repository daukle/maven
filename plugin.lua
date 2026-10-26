--- daukle/maven: turning coordinates into the pinned blocks a toolchain takes.
---
--- This plugin resolves and pins; it compiles nothing and runs nothing. daukle/java
--- does not require it, because a required module runs under the DEPENDENT's
--- "uses": a java that required it would have to declare the unpinned fetch
--- itself, advertising that the Java toolchain may fetch unpinned on any run.
--- The generated file is the interface for java. A plugin whose job IS
--- resolving, such as daukle/gradle, requires lib/resolve and declares "pin"
--- and "fetch" itself. D-77, D-170.

daukle.plugin{ api = 1, uses = { "fetch", "cache", "pin", "write" },
               exports = { "lib/xml", "lib/pom", "lib/graph", "lib/resolve", "lib/output" } }

local coordinates = daukle.require("lib/coordinates")
local output = daukle.require("lib/output")
local resolve = daukle.require("lib/resolve")

daukle.toolchain{
  name = "maven",
  generate = function(context)
    coordinates.resolutions_of(coordinates.config_of(context))
    return {}
  end,
}

daukle.task{
  name = "maven:resolve",
  run = function(context)
    local resolutions = coordinates.resolutions_of(coordinates.config_of(context))
    local groups = resolve.pinned_groups(resolutions)

    --[[ committed, because a clone has to build without resolving again: an
         ordinary build may not fetch anything unpinned, so the pins have to be
         in the project's history. It lands in daukle/maven/ rather than
         build/daukle/maven/, which daukle clean deletes. ]]
    local path = daukle.write{ path = output.OUTPUT, text = output.render(groups),
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
    local resolutions = coordinates.resolutions_of(coordinates.config_of(context))
    local session_for = resolve.sessions_of()
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
      local resolved, tested, rounds, unversioned = resolve.closures(resolution, session)
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
