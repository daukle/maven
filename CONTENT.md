## What this plugin is

A `daukle.toolchain` named `maven`: it turns `group:artifact:version` coordinates into the pinned
`url` and `sha256` blocks a toolchain takes, by walking Maven POMs itself. It compiles nothing and
runs nothing.

**It is the first thing in daukle that resolves.** Every other acquisition in the system is already
pinned by whoever wrote the manifest; this one starts from a coordinate and ends with a digest it
computed.

## What it is worth, measured

Against `intisy/libs/java-utils`, a real library:

| | |
| --- | --- |
| declared coordinates | 8 |
| modules resolved | **20, identical to Gradle's `runtimeClasspath`, version for version** |
| POM fetches | 63 |
| `java:compile` against the result | **39 class files, equal to Gradle's 39** |
| downloads during that compile | **0** |

Eight coordinates in, a compiled library out, **with no Gradle anywhere in the chain**.

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
Gradle module metadata is not read: Gradle prefers `.module` files over POMs and can select
different artifacts from them, which changed nothing for the twenty measured and is the likeliest
source of the first disagreement somewhere else.
