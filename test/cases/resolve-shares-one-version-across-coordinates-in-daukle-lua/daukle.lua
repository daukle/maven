local versions = { asm = "9.8" }
local function asm(artifact) return "org.ow2.asm:" .. artifact .. ":" .. versions.asm end
daukle.config.toolchains.maven.coordinates = { asm("asm-commons"), asm("asm-util") }
