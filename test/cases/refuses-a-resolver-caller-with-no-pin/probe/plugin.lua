daukle.plugin{ api = 1, uses = { "fetch", "cache", "pin" },
               requires = { maven = { url = "https://invalid.example/plugin.lua", sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } }

local resolve = daukle.require("maven:lib/resolve")

daukle.toolchain{ name = "probe", generate = function() return {} end }

daukle.task{
  name = "probe:resolve",
  run = function()
    return resolve.pinned_groups({}, { cache = daukle.cache, fetch = daukle.fetch })
  end,
}
