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
| `java:compile` against the generated classpath | **39 class files, equal to Gradle's 39, on the same JDK** |
| downloads during that compile | **0** |

**"On the same JDK" is load bearing and was added on 2026-10-05 after measuring it.** Gradle 8.13
on Corretto 17 gives 39, `daukle/java` with `version = "17"` gives 39, and `daukle/java` on its
own default JDK gives **38**: javac 21 does not emit the synthetic `$SwitchMap` holder that javac
17 emits for an enum `switch`. Neither compilation is wrong and `release = 8` changes nothing,
because the variable is the compiler rather than the target. The honest claim is that the two
tools agree when told to use the same JDK.

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
testCoordinates = ["org.assertj:assertj-core:3.25.3"]
```

```lua
-- daukle.lua, the one line a human writes to use the result
daukle.include("daukle/maven/classpath.lua")
```

**That line goes in AFTER the first resolve, not before.** `daukle.include` raises on a file that
is not there, and the first resolve is the run that creates it, so a project carrying the line on
a fresh checkout with no `daukle/maven/` cannot even parse its manifest to run the resolve. On
every later run, and in every clone, the file is committed and the line is what makes it load.
This file said `build/daukle/...` until 2026-10-05, which is a path the resolve has never written.

```sh
daukle maven:list                 # resolve only, no downloads: build/daukle/maven/resolved.txt
daukle maven:resolve --resolve    # resolve, fetch, hash: daukle/maven/classpath.lua
```

**Nothing is pasted anywhere, and that is the point.** The generated file is Lua rather than
TOML so it can be `daukle.include`d, which keeps the resolved pins in a file of their own:
`daukle.toml` holds what the human wrote, `classpath.lua` holds what the resolver computed, and
nobody is ever asked to edit the second. It APPENDS to the classpath, so a hand-written entry in
`daukle.toml` survives beside the resolved ones.

**Proved end to end**: `intisy/libs/java-utils` compiles to its 39 classes with an eleven line
`daukle.toml` carrying no pins at all and a `daukle.lua` carrying one `include`.

**It is written to `daukle/maven/`, which is COMMITTED**, not to `build/`, which is not. The two
directories have opposite lifetimes: `build/daukle/` is what a tool produces on the way to an
artifact and `daukle clean` deletes it, while `daukle/` is what a resolve produced and a clone has
to carry. A clone with no pins could not build at all, because an ordinary build may not fetch
anything unpinned, and it could not even parse its manifest, since `daukle.include` raises on a
file that is not there.

`daukle.write{ committed = true }` is gated behind `--resolve` for the same reason `daukle.pin`
is: an ordinary build must not rewrite a file the project has committed.

`--resolve` is not optional. Without it `daukle.pin` raises and names the flag, because the
unpinned fetch is the one acquisition in daukle that does not verify what it got.

## Keys

| key | meaning |
| --- | --- |
| `coordinates` | a list of `group:artifact:version`. Required unless a `resolve` entry supplies a closure instead |
| `testCoordinates` | optional, the test-only ones. A second closure and a `testClasspath` block |
| `strategy` | `"highest"` (default, Gradle's rule) or `"nearest"` (Maven's) |
| `repository` | defaults to Maven Central |
| `for` | which toolchain the generated blocks name, default `"java"` |
| `resolve` | optional, a list of **independent** closures. See below |

## More than one closure, and why `resolve` is not how `testCoordinates` is spelled

A project needs more than one closure as soon as it needs more than one REPOSITORY. The measured
case is Gradle: the plugins a build applies live on the Plugin Portal and the dependencies it
compiles against live on Central, and the two are genuinely different sets. Measured 2026-10-06:
Central answers **404** for `io.github.intisy.github-gradle`'s plugin marker where the Portal
serves it, so one `repository` could not have served both.

Each `[[toolchains.maven.resolve]]` entry is one independent closure:

```toml
[toolchains.maven]
for = "gradle"
coordinates = ["org.slf4j:slf4j-api:1.7.36"]

[[toolchains.maven.resolve]]
repository = "https://plugins.gradle.org/m2"
coordinates = ["io.github.intisy.github-gradle:io.github.intisy.github-gradle.gradle.plugin:1.8.2.1"]
into = "pluginClasspath"
```

| key | meaning |
| --- | --- |
| `coordinates` | required |
| `into` | required, the toolchain key the pins are appended to. **No default** |
| `repository` | defaults to the block's |
| `strategy` | defaults to the block's |
| `for` | defaults to the block's |

**`into` has no default on purpose.** A closure that lands on a key nothing reads resolves,
downloads and changes nothing, which is the most expensive kind of silence.

**Two resolutions that append to one key of one toolchain are refused by name.** Both lists would
be read in whatever order they were written and a module they disagree about would resolve to
whichever came first. It is `refuse_shadowed`'s failure one level up, so it is refused the same
way rather than merged.

**`testCoordinates` is NOT a `resolve` entry and cannot be written as one.** Its roots are the
compile coordinates plus its own, and the pair is refused when the two disagree, so it is tied to
the primary closure. A `resolve` entry is independent of everything else in the block: the plugin
classpath shares no module with the classpath the project compiles against. That is why the
primary closure stayed where it was rather than becoming the list's first element.

**The Plugin Portal mirrors Central**, measured the same day: `slf4j-api` and `junit-bom` are both
served by `plugins.gradle.org/m2`. So a plugin's own closure resolves from one repository even
when it reaches ordinary libraries, and this plugin needs no per-closure repository LIST.

**One repository means one session**, so two resolutions against the same repository share every
POM they both reach rather than fetching it twice.

**A project using `resolve` must declare `daukle/maven@^1.1`.** This plugin does not reject unknown
keys, so **`1.0.1` ignores the whole list in silence** and writes a classpath missing every
resolution but the first: measured 2026-10-06 against both published releases, the same project
giving two closures on `1.1.0` and one on `1.0.1`, with no diagnostic. Nothing a later release can
do makes an earlier one loud, so the version constraint is the guard.

**`daukle.include` of a file that does not exist yet is a hard error**, measured 2026-10-06. A
project therefore cannot carry the include before its first `maven:resolve`: run the task, then
add the line. A `<name>.lua` beside a `<name>.toml` is **not** read either, only `daukle.lua`
beside `daukle.toml`.

## The test closure

`testCoordinates` produces a **second, independent resolve** whose roots are the compile
coordinates **plus** the test ones, because a test compiles and runs against the project's own
dependencies as well as its test-only ones. It is not the compile closure with extras bolted on:
Gradle resolves `testRuntimeClasspath` as its own configuration, so a test dependency may raise a
version the compile side never sees.

The generated `testClasspath` block carries **only what the compile closure lacks**, because
`daukle/java` reaches a test through `classpath` followed by `testClasspath` and a module written
to both would be acquired and placed twice.

**A module the two closures resolve DIFFERENTLY is refused by name.** The compile entry comes
first, so it would win, and the tests would run against a version neither closure chose with
nothing reporting it. The message names every clashing module and both versions. Raise the version
in `coordinates`, or drop the test coordinate that pulls the other one.

### Measured against `intisy/libs/java-utils`

| | daukle | Gradle |
| --- | --- | --- |
| compile closure | 20 | 20 `runtimeClasspath` |
| test closure | **30** | 29 `testRuntimeClasspath` |
| `java:test` | **4 containers, 6 tests, 6 successful** | `tests="6" failures="0"` |

Two `testCoordinates` lines in place of nine hand-written pinned blocks.

**The one module of difference is `org.apiguardian:apiguardian-api:1.1.2`, and it is the first
real instance of the Gradle-module-metadata limit this file already names.**
`junit-platform-commons`' POM declares it at `compile` scope; its `.module` puts it in
`apiElements` and **not** in `runtimeElements`, a split a POM has no way to express. So Gradle's
test RUNTIME classpath omits it while Gradle's test COMPILE classpath carries it, and daukle's
single test closure equals the latter and is a one-jar superset of the former. An annotation jar
on the test classpath changes no result; a module that mattered would.

### What proves the test closure is load bearing, and what cannot

**The console launcher bundles JUnit 4, jupiter and hamcrest**, so a project whose tests use any of
them runs green with an **empty** `testClasspath`. Both were tried as negative controls here and
both passed with the resolved block deleted, which proves nothing about resolution.

The honest probe is a test-only library the launcher does not carry. With
`testCoordinates = ["org.assertj:assertj-core:3.25.3"]`, the resolve produces `assertj-core` and
its `byte-buddy`, the test passes, and **deleting the `assertj-core` block fails `java:test-compile`
with `cannot find symbol: method assertThat`**. That is the control that means something.

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
| make `publishes_a_jar` return true for everything | `junit-bom-5.10.1.jar returned status 404`, and the whole task fails |
| make `refuse_repeated_keys` return immediately | `refuses-two-resolutions-that-append-to-one-key` gets a success where it wanted a failure |
| have a resolution ignore its own `repository` | the second closure resolves from Central and its generated urls change |
| land every block on the first target | the two-target file collapses into one scope |

**A fourth mutation is why the suite has a SECOND STEP.** Ignore `into` so every closure lands on
`classpath`, then regenerate the text expectation from that run: the diff passes, because the
expectation now encodes the bug. Only the second step fails, and only because its clauses are
EXACT COUNTS. The first version of those clauses asked for "at least one `pluginClasspath`" and
passed on the broken run, because `config print` echoes the manifest back and the manifest names
`into = "pluginClasspath"` itself. **The clause was matching the input.**

Restoring either gives 20 of 20 again. **The negative control is at the other end**: deleting the
`slf4j-api` block from the generated classpath and recompiling gives `package org.slf4j does not
exist` and zero class files, so the resolved list is load bearing rather than decorative.

## What this does not do

- **A lock file.** See above; it is the ask.
- **Version ranges and snapshots**, both refused by name with the reason, because both are decided
  by what a registry holds at the moment it is read and daukle pins.
- **Classifiers and non-jar types**, dropped. None appears in the closure measured. **`pom` is the
  exception and is modelled**, because it is not a type to drop: a pom-packaged module publishes no
  jar at all, so it stays in the closure, where what it declares is real, and contributes nothing
  to the classpath. That is what a BOM is and what a Gradle plugin marker is. **Until 2026-10-06
  this plugin pinned a jar for every module in a closure**, so `org.junit:junit-bom:5.10.1`
  declared as a coordinate 404'd and failed the whole resolve, measured against the released
  `1.0.0`. `war` and `aar` are still unmodelled and would be pinned as jars.
- **Gradle module metadata.** Gradle prefers `.module` files over POMs and can select different
  artifacts. It changed nothing for these twenty, which is measured and not assumed, and **the
  test closure is where it first showed up**: see `apiguardian-api` above. The prediction that this
  would be the first source of disagreement held.
- **Two test classpaths.** Gradle has a test compile one and a test runtime one; this has one, and
  it equals Gradle's compile one. The difference is annotation jars.

## Two things the sandbox decided

**There is no `pcall`**, so a plugin cannot catch a failed `daukle.fetch`. A POM that will not
fetch therefore fails the whole task, which is the right answer anyway: a closure missing one POM
is missing whatever that POM declared, and the alternative is a short classpath with no
diagnostic. It does mean a coordinate still holding an unexpanded `${...}` has to be detected
rather than attempted, since asking Central for a literal `${x}` is a 404 that would end the run.

**There is no `print`**, so a task cannot report. The generated file is the report, and the
per-artifact acquisition lines `daukle.pin` already writes are what reaches the terminal.
