# Modules

A directory (including its all children) is a _module_ if it contains a file named `module.ens`.

Below is the list of configurations of `module.ens`.

## Table of Contents

- [target](#target)
- [dependency](#dependency)
- [archive](#archive)
- [build](#build)
- [source](#source)
- [prefix](#prefix)
- [foreign](#foreign)
- [preset](#preset)
- [antecedent](#antecedent)
- [inline-limit](#inline-limit)

## `target`

The field `target` defines the entry points of a module. It should look like the following:

```ens
{
  // ..
  target {
    TARGET-1 {
      main "path/to/source/file-1.nt"
    },
    // ..
    TARGET-N {
      main "path/to/source/file-n.nt"
    },
  },
  // ..
}
```

Suppose that your module has the following `target` in `module.ens`:

```ens
{
  // ..
  target {
    foo {
      main "foo.nt",
    },
    bar {
      main "item/whatever.nt"
    },
  },
  // ..
}
```

In this case, your module has two targets: `foo` and `bar`. The entry point of `foo` is the `main` function in `(source-dir)/foo.nt`. The entry point of `bar` is the `main` function in `(source-dir)/item/whatever.nt`.

The names in `target` can be specified when running `neut build`. For example, given the above definition of `target`, you can run `neut build foo`.

The names of targets are also used as the names of executables. For example, if you run `neut build foo --install ./bin/`, an executable named `foo` will be created under the directory `./bin/`.

The field `target` is optional. The default value of `target` is `{}`.

### `compile-option`

You can add `compile-option` to a target as follows:

```ens
{
  target {
    foo {
      main "foo.nt",
      // ↓ here
      compile-option [
        "-g",
        "-O0",
        "-fsanitize=address",
        "$SOME_ENV_VAR",
        "$(some-command arg)",
      ],
    },
  },
}
```

The compiler passes the options specified here to `clang` when compiling LLVM IRs into object files.

In `compile-option`, you can use environment variables and shell interpolations.

The field `compile-option` is optional. The default value of `compile-option` is `[]`.

### `link-option`

You can add `link-option` to a target as follows:

```ens
{
  target {
    foo {
      main "foo.nt",
      // ↓ here
      link-option [
        "-g",
        "-O0",
        "$SOME_ENV_VAR",
        "$(some-command)",
      ],
    },
  },
}
```

The compiler passes the options specified here to `clang` when linking object files.

In `link-option`, you can use environment variables and shell interpolations.

The field `link-option` is optional. The default value of `link-option` is `[]`.

### `build-option`

You can add `build-option` to a target as follows:

```ens
{
  target {
    foo {
      main "foo.nt",
      // ↓ here
      build-option [
        "$(pkg-config openssl --libs --cflags)",
        "whatever",
      ],
    },
  },
}
```

Adding an element to `build-option` is the same as adding the element to both `compile-option` and `link-option`.

In `build-option`, you can use environment variables and shell interpolations.

The field `build-option` is optional. The default value of `build-option` is `[]`.

## `dependency`

The field `dependency` defines the dependencies of a module. It should look like the following:

```ens
{
  // ..
  dependency {
    foo {
      digest "(base64url-encoded sha256 checksum)",
      mirror [
        "URL-1",
        // ..
        "URL-N",
      ],
      enable-preset <true | false>, // ← optional field
    },
    // ..
    bar { .. },
  },
  // ..
}
```

An example of `dependency`:

```ens
{
  // ..
  dependency {
    core {
      digest "ub3MUXVac9F1rebIhl_Crm2_GJ7PzCAekgp8aYH3-mo",
      mirror [
        "https://github.com/vekatze/neut-core/raw/main/archive/0-38.tar.zst",
      ],
      enable-preset true,
    },
    some-package {
      digest "F_ST8PtL9dLCDWVZ4GpuS7sviUU0_-TUz2s6iw-86KU",
      mirror [
        "https://example.com/foobarbuz/packages/22-3.tar.zst",
      ],
    },
  },
    // ..
}
```

The field `digest` specifies the checksum of the tarball of the dependency. The digest is a Base64URL-encoded SHA256 checksum of the tarball. This digest is the "real" name of this dependency, and used as an identifier.

The field `mirror` specifies a list of URLs from which the compiler can fetch the tarball. When running `neut get`, the compiler will try to get the tarball if necessary, using this list from the beginning to the end.

The optional field `enable-preset` specifies whether to import `preset`s automatically, as in "prelude" in other languages. This field should only be used (and set to be true) with the core library. For more information, see the explanation of `preset` in this section.

The field `dependency` is optional. The default value of `dependency` is `{}`.

## `archive`

The field `archive` defines the path of the directory into which the subcommand `neut archive` store tarballs. It should look like the following:

```ens
{
  // ..
  archive "my-archive",
  // ..
}
```

The field `archive` is optional. The default value of `archive` is `./archive/`.

## `build`

The field `build` defines the path of the directory to store object files, executables, etc. It should look like the following:

```ens
{
  // ..
  build ".build",
  // ..
}
```

The field `build` is optional. The default value of `build` is `./build/`.

## `source`

The field `source` defines the path of the directory to store source files. It should look like the following:

```ens
{
  // ..
  source ".",
  // ..
}
```

The field `source` is optional. The default value of `source` is `./source/`.

## `prefix`

The field `prefix` defines the aliases of source files. It should look like the following:

```ens
{
  // ..
  prefix {
    Foo "this.foo",
    // ..
    Bar "this.item.bar",
  },
  // ..
}
```

Each field in `prefix` specifies an alias of the specified source file. For example, given the definition above, the code

```neut
import {
  this.foo,
  this.item.bar {some-func},
}
```

can be rewritten into the following:

```neut
import {
  Foo,
  Bar {some-func},
}
```

The prefixes specified in a `module.ens` of a module can be used only in the module.

The field `prefix` is optional. The default value of `prefix` is `{}`.

## `foreign`

The field `foreign` defines a way to compile external source files. It should look like the following:

```ens
{
  // ..
  foreign {
    input [
      "source/foo.c",
      "source/bar.c",
    ],
    output [
      "foo.o",
      "bar.o"
    ],
    script [
      "{{clang}} -c -flto=thin -O2 source/foo.c -o {{foreign}}/foo.o",
      "{{clang}} -c -flto=thin -O2 source/bar.c -o {{foreign}}/bar.o",
    ]
  }
}
```

### `input`

The field `input` specifies the list of external source files. The paths are relative to the root of the module.

When running `neut archive`, the compiler adds all the `input` files to the resulting tarballs.

### `output`

The field `output` specifies the resulting files of foreign source files. The paths are relative to a directory named _foreign directory_. You can find a foreign directory in the build directory.

When running `neut build`, the compiler links all the `output` files in the foreign directory (in addition to Neut's "domestic" object files).

### `script`

The field `script` specifies how to compile external source files. When running `neut build`, the compiler executes the specified commands immediately after resolving all the `import`s.

In the field `script`, you can use the following placeholders:

- `{{clang}}`: The `clang` used by the compiler
- `{{foreign}}`: The foreign directory

The compiler skips running the `script` if all the files in `output` are newer than `input`.

When running the `script`, the compiler sets the current working directory to the module's root directory.

### Notes

The field `foreign` is optional. The default value of `foreign` is:

```ens
{
  input [],
  output [],
  script [],
}
```

An example of `foreign` can be found in the [core library](https://github.com/vekatze/neut-core/blob/0570cd5aa17914bef7021b7e88ca1fa421af721e/module.ens#L10).

<div class="info-block">

The compiler links the resulting foreign object files without any name mangling. You're strongly encouraged to prefix names in your foreign sources with your module name and the major version to avoid name collision. You can find an example of prefixed names [here](https://github.com/vekatze/neut-core/blob/0570cd5aa17914bef7021b7e88ca1fa421af721e/source/foreign.c).

</div>

## `preset`

The field `preset` defines the list of names that must be imported implicitly when the module is used as a dependency. It should look like the following:

```ens
{
  // ..
  preset {
    foo ["my-func", "other-func"],
    item.bar ["hoge", "pohe"],
  },
  // ..
}
```

In the example above, the current module is expected to have the following files:

- `(source-dir)/foo.nt` that contains the definitions of `my-func` and `other-func`
- `(source-dir)/item/bar.nt` that contains the definitions of `hoge` and `pohe`

The field `preset` is used in combination with `enable-preset` in `dependency`.

Suppose we released a module that contains the definition of `preset` as in the above. Also, suppose someone is developing a module `MMM` and they added our module to `MMM`'s dependency:

```ens
// module.ens in MMM

{
  // ..
  dependency {
    sample {
      digest "BASE64_URL_ENCODED_SHA256_CHECKSUM",
      mirror ["SOME_URL"],
      enable-preset true,
    },
    // ..
  },
  // ..
}
```

In this case, source files in `MMM` imports our preset names automatically since `enable-preset` is `true`.

As an example, suppose a file in `MMM` contains an `import` like the below:

```neut
import {
  sample.foo {my-func, other-func},
  sample.item.bar {hoge, pohe},
}

define buz() {
  let i = my-func() in
  print-int(i)
}
```

This code is the same as the following since the preset is enabled:

```neut
define buz() {
  let i = my-func() in
  print-int(i)
}
```

The field `preset` is expected to be used as a way to realize "preludes" in other languages.

The field `preset` is optional. The default value of `preset` is `{}`.

## `antecedent`

The field `antecedent` defines the list of older compatible versions. This field should look like the following:

```ens
{
  // ..
  antecedent [
    "Bp8RulJ-XGTL9Eovre0yQupJpeS3lGNk8Q6QQYua7ag",
    // ..
    "zptXghmyD5druBl8kx2Qrei6O6fDsKCA7z2KoHp1aqA",
  ],
  // ..
}
```

This information is used to select the newest compatible version of the module. For more information, see the explanation on `neut archive` in [Commands](./commands.md).

The field `antecedent` is optional. The default value of `antecedent` is `[]`.

<div class="info-block">

You won't write this field by hand because it is inserted automatically into `module.ens` of a tarball when `neut archive` is executed.

</div>

## `inline-limit`

The field `inline-limit` defines the limit on recursion performed during compilation. It should look like the below:

```ens
{
  // ..
  inline-limit 1000000,
  // ..
}
```

During compilation, the compiler performs possibly recursive computation when:

- type-checking, and
- expanding the definitions of inline functions.

The `inline-limit` specifies a limit here. If the limit is exceeded, the compiler reports an error like the following:

```text
/path/to/file.nt:123:45
error: exceeded max recursion depth of 1000 during (..)
```

The field `inline-limit` is optional. The default value of `inline-limit` is `100000`.
