--- Turning declared coordinates into the closure that actually gets built.
---
--- The one thing worth knowing before reading this: conflict resolution is NOT
--- a pass over a finished graph. It decides WHICH graph exists. When a module
--- is declared at two versions, only the winner's dependencies are real, so a
--- walk that expands both and then picks mixes a loser's children into the
--- answer. Measured against Gradle on a real project, walk-then-pick produced
--- four wrong versions out of twenty, every one of them plausible.

local pom = daukle.require("lib/pom")

local graph = {}

-- Maven's compile column: a compile dependency brings its compile and runtime
-- dependencies and nothing else. test and provided are not transitive, which
-- is what keeps a closure from dragging in every library's test framework.
local TRANSITIVE = { compile = true, runtime = true }

local function split_version(version)
  local parts = {}
  for piece in version:gmatch("[^%.%-_]+") do
    local number = tonumber(piece)
    parts[#parts + 1] = { number ~= nil and 0 or 1, number or piece }
  end
  return parts
end

--- True when left is the higher version. Numeric pieces compare as numbers and
--- sort below textual ones, so 1.324 beats 1.99 and a release beats its own
--- "1.0-alpha". Textual pieces fall back to string order.
function graph.is_higher(left, right)
  local a = split_version(left)
  local b = split_version(right)
  local limit = #a > #b and #a or #b
  for index = 1, limit do
    local one = a[index]
    local two = b[index]
    if one == nil then return false end
    if two == nil then return true end
    if one[1] ~= two[1] then return one[1] < two[1] end
    if one[2] ~= two[2] then return one[2] > two[2] end
  end
  return false
end

local function excluded_by(exclusions, group, artifact)
  for index = 1, #exclusions do
    local rule = exclusions[index]
    local group_matches = rule.group == nil or rule.group == "*" or rule.group == group
    local artifact_matches = rule.artifact == nil or rule.artifact == "*"
                             or rule.artifact == artifact
    if group_matches and artifact_matches then return true end
  end
  return false
end

local function with(exclusions, extra)
  if #extra == 0 then return exclusions end
  local combined = {}
  for index = 1, #exclusions do combined[index] = exclusions[index] end
  for index = 1, #extra do combined[#combined + 1] = extra[index] end
  return combined
end

local function better(strategy, candidate, incumbent)
  if strategy == "nearest" then return candidate.depth < incumbent.depth end
  return graph.is_higher(candidate.version, incumbent.version)
end

--- One breadth-first pass, expanding each module at whatever version the
--- previous pass settled on.
local function sweep(session, declared, chosen, strategy)
  local settled = {}
  local order = {}
  local queue = {}
  local head = 1

  for index = 1, #declared do
    queue[#queue + 1] = {
      group = declared[index].group, artifact = declared[index].artifact,
      version = declared[index].version, depth = 1, exclusions = {},
    }
  end

  local visited = {}
  while head <= #queue do
    local item = queue[head]
    head = head + 1
    local key = pom.key_of(item.group, item.artifact)

    local incumbent = settled[key]
    if incumbent == nil then
      settled[key] = { version = item.version, depth = item.depth }
      order[#order + 1] = key
    elseif better(strategy, item, incumbent) then
      -- The depth of the first sighting is kept: nearest-wins compares where a
      -- module was FOUND, and highest-wins does not read depth at all.
      settled[key] = { version = item.version,
                       depth = item.depth < incumbent.depth and item.depth or incumbent.depth }
    end

    -- The previous pass's winner decides which subtree is walked now. Without
    -- this line the loser's children enter the graph and the answer is wrong
    -- in a way that still looks like a closure.
    local effective = chosen[key] or item.version
    local visit = key .. "@" .. effective .. "#" .. tostring(#item.exclusions)
    if not visited[visit] then
      visited[visit] = true
      local model = pom.load(session, item.group, item.artifact, effective)
      for index = 1, #model.declared do
        local entry = model.declared[index]
        local group = pom.interpolate(entry.group, model.properties)
        local artifact = pom.interpolate(entry.artifact, model.properties)
        local wanted = not entry.optional and TRANSITIVE[entry.scope] and entry.kind == "jar"
                       and entry.classifier == nil
        if wanted and not excluded_by(item.exclusions, group, artifact) then
          local version = pom.interpolate(entry.version, model.properties)
          if version == nil then
            local managed = model.managed[pom.key_of(group, artifact)]
            if managed ~= nil then version = managed.version end
          end
          if version ~= nil and version:find("%${") == nil then
            queue[#queue + 1] = {
              group = group, artifact = artifact, version = version,
              depth = item.depth + 1,
              exclusions = with(item.exclusions, entry.exclusions),
            }
          else
            session.unversioned[#session.unversioned + 1] =
              pom.key_of(group, artifact) .. " under " .. key .. "@" .. effective
          end
        end
      end
    end
  end

  return settled, order
end

--- Sweeps until the chosen version of every module stops changing. Three
--- rounds on the one real project measured; a resolver that does a single
--- pass is not a fast one, it is a wrong one.
function graph.resolve(session, declared, strategy)
  session.unversioned = {}
  local chosen = {}
  local order = {}
  local rounds = 0

  while true do
    rounds = rounds + 1
    local settled, swept = sweep(session, declared, chosen, strategy)
    order = swept

    local stable = true
    for key, entry in pairs(settled) do
      if chosen[key] ~= entry.version then stable = false end
    end
    for key in pairs(chosen) do
      if settled[key] == nil then stable = false end
    end

    local next_chosen = {}
    for key, entry in pairs(settled) do next_chosen[key] = entry.version end
    chosen = next_chosen

    if stable then break end
    if rounds >= 12 then
      error("resolution did not settle after " .. rounds .. " rounds", 0)
    end
  end

  local resolved = {}
  for index = 1, #order do
    local key = order[index]
    local colon = key:find(":", 1, true)
    resolved[#resolved + 1] = {
      group = key:sub(1, colon - 1),
      artifact = key:sub(colon + 1),
      version = chosen[key],
    }
  end
  return resolved, rounds
end

return graph
