# Authoring notes

`plugin.lua` plus `lib/` is the whole plugin. It is published as a release asset and acquired by a
`[plugins]` table entry naming `daukle/maven@<range>`.

It declares `uses = { "fetch", "cache", "pin", "write" }`. **`pin` is the one that matters**: it is
the only unpinned acquisition in daukle and it is refused outside a `--resolve` run.

## What it does, measured

Against `intisy/libs/java-utils`, the project both `D-48` measurements used:

| | result |
| --- | --- |
| declared coordinates | 8 |
| modules resolved | **20, identical to Gradle's `runtimeClasspath`, version for version** |
| sweeps to a fixed point | 3 |
| POM fetches | 63 |
| resolve with digests | 3.8 seconds, 21.5 MB |
| `java:compile` against the generated classpath | **39 class files, equal to Gradle's 39** |
| downloads during that compile | **0** |

**The whole chain runs with no Gradle anywhere**: eight coordinates in, a compiled library out.
The second measurement's standing finding, that the twenty pinned blocks had to come from a cache
Gradle populated, no longer holds.

**Zero downloads in the compile is `D-82`'s cache key working.** `daukle.pin` writes each artifact
under `<artifacts>/<digest>/<name>`, which is exactly where the `daukle.artifact` behind a
classpath entry looks, so resolving and then building fetches each jar once rather than twice.

## How to run it

```toml
[plugins]
maven = "daukle/maven@^1"

[toolchains.maven]
coordinates = [
  "org.slf4j:slf4j-api:1.7.36",
  "com.github.codemonstur:embedded-redis:1.4.3",
]
```

```sh
daukle maven:list                 # resolve only, no downloads: build/daukle/maven/resolved.txt
daukle maven:resolve --resolve    # resolve, fetch, hash: build/daukle/maven/classpath.toml
```

Paste `classpath.toml` into the manifest. **That paste is the part that is not finished**, and
section 6.3 of the spec is the ask that would remove it: a lock file has to be committed to be
worth anything and no plugin may write at the project root. Until then this is the spec's
section 8 fallback, which works and is a worse design.

`--resolve` is not optional. Without it `daukle.pin` raises and names the flag, because the
unpinned fetch is the one acquisition in daukle that does not verify what it got.

## Keys

| key | meaning |
| --- | --- |
| `coordinates` | required, a list of `group:artifact:version` |
| `strategy` | `"highest"` (default, Gradle's rule) or `"nearest"` (Maven's) |
| `repository` | defaults to Maven Central |
| `for` | which toolchain the generated blocks name, default `"java"` |

**`strategy` is not a preference, it is which tool you are replacing.** On `java-utils` the two
rules disagree about **six of the twenty** modules, proved by running both:

| module | `highest` | `nearest` |
| --- | --- | --- |
| `org.kohsuke:github-api` | 1.324 | 1.99 |
| `org.apache.commons:commons-lang3` | 3.14.0 | 3.9 |
| `commons-io:commons-io` | 2.8.0 | 2.6 |
| `com.fasterxml.jackson.core:jackson-databind` | 2.17.1 | 2.10.0 |
| `com.fasterxml.jackson.core:jackson-core` | 2.17.1 | 2.10.0 |
| `com.fasterxml.jackson.core:jackson-annotations` | 2.17.1 | 2.10.0 |

A project migrating off Gradle onto the wrong rule compiles, passes and ships against six
dependencies its author never chose.

## What is proved by mutation rather than asserted

Both of these produce a closure of the right SIZE and the wrong CONTENT, which is why neither
would be caught by "does it resolve".

| mutation | result |
| --- | --- |
| expand every sighting rather than the winner (`effective = item.version`) | 20 modules, exit 0, **`commons-codec` 1.13 where Gradle gives 1.11** |
| stop after one sweep rather than at a fixed point | the same wrong answer |

Restoring either gives 20 of 20 again. **The negative control is at the other end**: deleting the
`slf4j-api` block from the generated classpath and recompiling gives `package org.slf4j does not
exist` and zero class files, so the resolved list is load bearing rather than decorative.

## What this does not do

- **A lock file.** See above; it is the ask.
- **Version ranges and snapshots**, both refused by name with the reason, because both are decided
  by what a registry holds at the moment it is read and daukle pins.
- **Classifiers and non-jar types**, dropped. None appears in the closure measured.
- **Gradle module metadata.** Gradle prefers `.module` files over POMs and can select different
  artifacts. It changed nothing for these twenty, which is measured and not assumed, and it is the
  likeliest source of the first disagreement on some other project.
- **Test scopes.** `testClasspath` needs a second resolve with `test` in the transitive set; the
  closure for `testRuntimeClasspath` is 29 artifacts against the compile side's 20.

## Two things the sandbox decided

**There is no `pcall`**, so a plugin cannot catch a failed `daukle.fetch`. A POM that will not
fetch therefore fails the whole task, which is the right answer anyway: a closure missing one POM
is missing whatever that POM declared, and the alternative is a short classpath with no
diagnostic. It does mean a coordinate still holding an unexpanded `${...}` has to be detected
rather than attempted, since asking Central for a literal `${x}` is a 404 that would end the run.

**There is no `print`**, so a task cannot report. The generated file is the report, and the
per-artifact acquisition lines `daukle.pin` already writes are what reaches the terminal.
