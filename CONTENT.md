## What this plugin is

A `daukle.toolchain` named `maven`: it turns `group:artifact:version` coordinates into the pinned
`url` and `sha256` blocks a toolchain takes, by walking Maven POMs itself. It compiles nothing and
runs nothing.

**It is the first thing in daukle that resolves.** Every other acquisition in the system is already
pinned by whoever wrote the manifest; this one starts from a coordinate and ends with a digest it
computed.

## Generated data never touches the file you wrote

`maven:resolve` writes **Lua**, not TOML, and the difference is the whole ergonomics of the thing.
A TOML fragment has to be pasted into `daukle.toml`, mixing generated rows into the one file you
maintain by hand. A Lua fragment is included:

```lua
-- daukle.lua
daukle.include("daukle/maven/classpath.lua")
```

The generated file is committed and lives in `daukle/`, beside the `build/` that `daukle clean`
deletes. The two have opposite lifetimes: build output is rebuilt from nothing, and resolved pins
are what lets a clone build offline without resolving again.

`daukle.toml` keeps what you wrote. The pins live in a file marked "do not edit" and nothing ever
asks you to touch it. The generated fragment appends rather than assigns, so a classpath entry you
declared by hand survives beside the twenty the resolver found.

## What it is worth, measured

Against `intisy/libs/java-utils`, a real library:

| | |
| --- | --- |
| declared coordinates | 8 |
| modules resolved | **20, identical to Gradle's `runtimeClasspath`, version for version** |
| POM fetches | 63 |
| `java:compile` against the result | **39 class files, equal to Gradle's 39** |
| downloads during that compile | **0** |
| declared test coordinates | 2 |
| test closure | **30 modules**, against Gradle's 29 on `testRuntimeClasspath` |
| `java:test` against the result | **4 containers, 6 tests, 6 successful**, equal to Gradle's |

Eight coordinates in, a compiled library out, **with no Gradle anywhere in the chain**. Two more
in, a green test run out.

## Test dependencies

`testCoordinates` is the test-only half, and it resolves a **second, independent closure** rather
than bolting extras onto the first. Its roots are the compile coordinates plus the test ones,
because a test builds against the project's own dependencies too.

```toml
[toolchains.maven]
coordinates     = ["org.slf4j:slf4j-api:1.7.36"]
testCoordinates = ["org.assertj:assertj-core:3.25.3"]
```

The generated file gains a `testClasspath` block holding **only what the compile closure does not
already carry**, because a toolchain reaches a test through `classpath` and then `testClasspath`
and a module in both would be placed twice.

**A module the two closures resolve to different versions is refused by name**, with both versions
in the message. The compile entry comes first and would silently win, so the tests would run
against a version neither closure chose. Raise it in `coordinates`, or drop the test coordinate
that pulls the other one.

## Why `strategy` exists and is not a preference

Gradle settles a version conflict by taking the **highest** version. Maven takes the **nearest**.
They are not close: on `java-utils` the two rules disagree about **six of the twenty** modules, and
they differ in set membership too, because `github-api:1.99` declares a `commons-codec` that
`1.324` dropped.

The default is `"highest"`, because a project arriving here is leaving Gradle, and a resolver that
silently re-versions a third of a closure has not replaced the tool it claims to. `"nearest"` is
there for a project leaving Maven. **It is a key rather than an inference**: a daukle project has no
`pom.xml` and no `build.gradle` left to infer the old tool from, so a guess would be right until it
was silently wrong.

## Why resolution is a separate plugin rather than a library

A module reached through `daukle.require` runs under the **dependent's** `uses`. So a `daukle/java`
that required a resolver library would have to declare the unpinned fetch in its own `uses`,
which advertises that the Java toolchain may fetch unpinned on any run. That is the opposite of
what the gate exists to say.

The generated file is the interface instead, and the two plugins never call each other.

## The gate

`daukle.pin` is the one acquisition in daukle that does not verify what it fetched, because the
digest is what it is there to discover. It is refused outside a `--resolve` run and the message
names the flag. **No ordinary build ever fetches something unpinned**, which is the property the
project has had since `D-30` and the one this plugin had to be designed not to break.

## What it does not do

Version ranges and snapshots are **refused by name, with the reason**, because both are decided by
whatever a registry holds at the moment it is read. Classifiers and non-jar types are dropped.

**Gradle module metadata is not read, and the test closure is where that first showed up.** Gradle
prefers a `.module` file over a POM and can select different artifacts from it. It changed nothing
for the twenty compile modules; on the test side it is `org.apiguardian:apiguardian-api`, which
`junit-platform-commons`' POM declares at `compile` scope while its `.module` lists it under
`apiElements` and not `runtimeElements`. A POM cannot express that split, so daukle's test closure
matches Gradle's test COMPILE classpath and is one jar larger than its test runtime one.
