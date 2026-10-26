daukle.plugin{ api = 1, uses = { "write" },
               requires = { maven = { url = "https://invalid.example/plugin.lua", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } }

local resolve = daukle.require("maven:lib/resolve")
local output = daukle.require("maven:lib/output")

daukle.toolchain{ name = "probe", generate = function() return {} end }

daukle.task{
  name = "probe:announce",
  run = function()
    return daukle.write{ path = "resolved.txt",
                         text = type(resolve.pinned_groups) .. " " .. type(output.render) .. "\n" }
  end,
}
