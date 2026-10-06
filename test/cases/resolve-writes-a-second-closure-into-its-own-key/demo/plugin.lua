--- A toolchain that does nothing, so the case can prove where maven's pins
--- LAND. Running a task refuses a toolchain no plugin provides, so a target
--- has to be real even when what it does is nothing.
daukle.plugin{ api = 1 }

daukle.toolchain{
  name = "demo",
  generate = function() return {} end,
}
