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

--- A declaration without a scope takes its managed one, as Maven does: `log4j-core 2.17.1` lists
--- `mockito-core` bare and its parent manages it as `test`, so a `compile` default pulled test
--- frameworks into a tool's closure.
local function scope_of(entry, managed)
  return entry.scope or (managed ~= nil and managed.scope) or "compile"
end

--- Gradle's own special qualifiers, matched case-insensitively: `dev` below every other word,
--- the rest above every other word in this order.
local QUALIFIER_RANK = { dev = -1, rc = 1, snapshot = 2, final = 3, ga = 4, release = 5, sp = 6 }

--- The parts Gradle splits a version into: at `.`, `-`, `_` and `+`, and again wherever digits
--- meet letters, so `1a1` is `1.a.1`.
local function parts_of(version)
  local parts = {}
  for piece in version:gmatch("[^%.%-_+]+") do
    local position = 1
    while position <= #piece do
      local first, last = piece:find(piece:sub(position, position):find("%d") and "^%d+" or "^%D+",
                                      position)
      parts[#parts + 1] = piece:sub(first, last)
      position = last + 1
    end
  end
  return parts
end

local function is_numeric(part)
  return part:find("^%d+$") ~= nil
end

--- Compares digit strings exactly, so a timestamp part longer than a double holds still orders.
local function compare_numbers(left, right)
  left, right = left:gsub("^0+", ""), right:gsub("^0+", "")
  if #left ~= #right then return #left < #right and -1 or 1 end
  if left == right then return 0 end
  return left < right and -1 or 1
end

local function compare_words(left, right)
  local left_rank, right_rank = QUALIFIER_RANK[left:lower()] or 0, QUALIFIER_RANK[right:lower()] or 0
  if left_rank ~= right_rank then return left_rank < right_rank and -1 or 1 end
  if left_rank ~= 0 or left == right then return 0 end
  return left < right and -1 or 1
end

local function compare_parts(left, right)
  local left_numeric, right_numeric = is_numeric(left), is_numeric(right)
  if left_numeric and right_numeric then return compare_numbers(left, right) end
  if left_numeric ~= right_numeric then return left_numeric and 1 or -1 end
  return compare_words(left, right)
end

--- True when left is the higher version, by Gradle's version ordering (user guide 9.9.1,
--- "Understanding version ordering"): a numeric part beats a word, so `1.0-alpha` is below `1.0`
--- and an extra numeric part raises a version while an extra word lowers it.
--- @implNote Maven's order differs in places (`1.0` equals `1` there), and it is used under
--- `nearest` only to compare two platforms raising one module.
function graph.is_higher(left, right)
  local a, b = parts_of(left), parts_of(right)
  for index = 1, math.min(#a, #b) do
    local order = compare_parts(a[index], b[index])
    if order ~= 0 then return order > 0 end
  end
  if #a == #b then return false end
  local longer, extra = #a > #b, (#a > #b and a or b)[math.min(#a, #b) + 1]
  return longer == is_numeric(extra)
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
        local managed = model.managed[pom.managed_key(group, artifact, entry.kind, entry.classifier)]
        local wanted = not entry.optional and TRANSITIVE[scope_of(entry, managed)]
                       and entry.kind == "jar" and entry.classifier == nil
        if wanted and not excluded_by(item.exclusions, group, artifact) then
          local version = pom.interpolate(entry.version, model.properties)
          if version == nil and managed ~= nil then version = managed.version end
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

--- The version a platform constraint leaves a settled module at.
--- @implNote under `highest` a platform only raises and an enforced one forces,
--- the direct declaration included (D-185's M2 and M3). Under `nearest` both are
--- Maven's dependency management, which overrides what the graph found below
--- the roots and leaves a root's own version alone.
local function constrained(entry, constraint, strategy)
  if strategy == "nearest" then
    local managed = constraint.force or constraint.raise
    if entry.depth > 1 then return managed end
    return entry.version
  end
  if constraint.force ~= nil then return constraint.force end
  if graph.is_higher(constraint.raise, entry.version) then return constraint.raise end
  return entry.version
end

--- @implNote a conflict is refused for the first settled module in sorted
--- order, so the refusal names the same module on every run.
local function constrain(settled, constraints, strategy)
  local conflicts = {}
  for key, entry in pairs(settled) do
    local constraint = constraints[key]
    if constraint ~= nil and constraint.conflict ~= nil then conflicts[#conflicts + 1] = key end
    if constraint ~= nil then entry.version = constrained(entry, constraint, strategy) end
  end
  if #conflicts > 0 then
    table.sort(conflicts)
    error(constraints[conflicts[1]].conflict, 0)
  end
end

--- Sweeps until the chosen version of every module stops changing. Three
--- rounds on the one real project measured; a resolver that does a single
--- pass is not a fast one, it is a wrong one.
--- @param constraints what `platforms.constraints` returns, or nil
function graph.resolve(session, declared, strategy, constraints)
  session.unversioned = {}
  local chosen = {}
  local order = {}
  local rounds = 0

  while true do
    rounds = rounds + 1
    local settled, swept = sweep(session, declared, chosen, strategy)
    if constraints ~= nil then constrain(settled, constraints, strategy) end
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
