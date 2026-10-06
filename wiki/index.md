# daukle/maven

The resolver. It turns `group:artifact:version` coordinates into the pinned `url` and `sha256`
blocks a toolchain takes, by walking Maven POMs itself. **It compiles nothing and runs nothing.**

It is the first thing in daukle that resolves: every other acquisition in the system arrives
already pinned by whoever wrote the manifest, and this one starts from a coordinate and ends with a
digest it computed.

## Declaring it

```toml
[plugins]
maven = "daukle/maven@^1"

[toolchains.maven]
coordinates     = ["org.slf4j:slf4j-api:1.7.36"]
testCoordinates = ["org.junit.jupiter:junit-jupiter:5.10.1"]
```

```sh
daukle maven:list                 # resolve only, no downloads
daukle maven:resolve --resolve    # resolve, fetch, hash
```

Then add one line to `daukle.lua`, **after the first resolve**, because `daukle.include` raises on
a file that is not there and the first resolve is the run that creates it:

```lua
daukle.include("daukle/maven/classpath.lua")
```

## Keys

| key | meaning |
| --- | --- |
| `coordinates` | a list of `group:artifact:version`, required unless `resolve` supplies a closure |
| `testCoordinates` | optional, the test-only ones |
| `strategy` | `"highest"` (Gradle's rule, the default) or `"nearest"` (Maven's) |
| `repository` | defaults to Maven Central |
| `for` | which toolchain the generated blocks name, default `"java"` |
| `resolve` | optional, a list of independent closures, each with its own repository and key |

## A second repository, and a second key

One repository is enough until a project needs two. A Gradle build applies plugins from the Plugin
Portal and compiles against Central, and Central answers 404 for a plugin marker. Each
`[[toolchains.maven.resolve]]` entry is an independent closure with its own `repository` and its
own `into`, which names the toolchain key its pins are appended to:

```toml
[toolchains.maven]
for = "gradle"
coordinates = ["org.slf4j:slf4j-api:1.7.36"]

[[toolchains.maven.resolve]]
repository = "https://plugins.gradle.org/m2"
coordinates = ["io.github.intisy.github-gradle:io.github.intisy.github-gradle.gradle.plugin:1.8.2.1"]
into = "pluginClasspath"
```

`into` has no default: a closure that lands on a key nothing reads downloads everything and
changes nothing. Two resolutions appending to one key of one toolchain are refused by name.

## `strategy` is not a preference

Gradle settles a version conflict by taking the **highest** version and Maven the **nearest**. On a
real library the two disagree about **six of twenty** modules, and they differ in set membership
too. A project migrating onto the wrong rule compiles, passes and ships against dependencies its
author never chose.

It is a key rather than a guess: a daukle project has no `pom.xml` and no `build.gradle` left to
infer the old tool from.

## Generated data never touches the file you wrote

`maven:resolve` writes **Lua**, not TOML. A TOML fragment would have to be pasted into
`daukle.toml`, mixing generated rows into the one file you maintain by hand. The Lua fragment is
included instead, it is committed, and it **appends**, so a classpath entry you wrote by hand
survives beside the resolved ones.

## The test closure

`testCoordinates` produces a second, **independent** resolve rooted on the compile coordinates plus
the test ones. The generated `testClasspath` block carries only what the compile closure lacks.

**A module the two closures resolve differently is refused by name.** A toolchain reaches a test
through `classpath` and then `testClasspath`, so the compile entry would win and the tests would
run against a version neither closure chose, with nothing reporting it.

## What it does not do

Version ranges and snapshots are refused by name: both are decided by whatever a registry holds at
the moment it is read, and daukle pins. Classifiers and non-jar types are dropped.

**Gradle module metadata is not read.** Gradle prefers a `.module` file over a POM and can select
different artifacts from it. On the test side that is `org.apiguardian:apiguardian-api`, which a
POM declares at `compile` scope while the `.module` lists it under `apiElements` only, so this
resolver's test closure matches Gradle's test **compile** classpath and is one jar larger than its
test runtime one.
