# NAME

yaml-syntax - the YAML that yaml-zig reads, and how it writes it back

# DESCRIPTION

yaml-zig reads the syntax of YAML 1.2.2 (https://yaml.org/spec/1.2.2/). This
page is a short guide to it with the library's own rules: how values are typed,
which comments are kept, what changes when a document is written back, and
where the library departs from the specification. The specification is the
authority on YAML itself.

## Encoding and lines

Input is UTF-8, UTF-16 or UTF-32, recognised by a byte order mark or by the
first bytes. Lines end in LF, CR LF or CR. Indentation uses spaces; tabs may
separate but never indent.

## A document

```yaml
# A comment
name: nano
sources:
  - url: https://example.org/nano.tar.xz
    checksum: 86d3d8a3
options: {static: false, nls: true}
patches: [one.patch, two.patch]
```

## Types

A plain (unquoted) scalar is typed by the core schema. Its text is kept as
written. A quoted or block scalar is a string.

| Plain text | Kind |
|---|---|
| empty, `~`, `null`, `Null`, `NULL` | null |
| `true`, `True`, `TRUE`, `false`, `False`, `FALSE` | boolean |
| `12`, `-3`, `+4`, `0x1F`, `0o17` | integer |
| `7.2`, `-1e3`, `.5`, `.inf`, `-.Inf`, `.nan` | float |
| anything else, including `yes`, `no`, `on`, `off` | string |

`yes` and `on` were booleans in YAML 1.1. They are strings here, even in a
document marked `%YAML 1.1`.

## Strings over several lines

```yaml
literal: |
  Line breaks are kept.
  So is the final one.
folded: >-
  These lines become
  one, with no final break.
quoted: "a long string
  folded into one line"
```

`-` after `|` or `>` strips the final line break, `+` keeps all of them. A
digit states the indentation when the first line starts with a space.

## Keys

A key may be any node. Two keys in one mapping must differ. They are the same
when they have the same type and value, however written: `1` and `0x1` are one
key, `1` and `"1"` are two, and the order of keys inside a mapping used as a key
does not matter.

```yaml
simple: 1
[a, b]: a list as a key
? - a block
  - collection
: as a key
```

## Anchors and aliases

`&name` marks a node and `*name` refers to the latest node above with that
name, in the same document.

```yaml
defaults: &defaults
  retries: 3
job: *defaults
```

`<<: *defaults` does **not** merge anything. Merge keys belong to YAML 1.1;
here `<<` is an ordinary key.

## Tags

```yaml
version: !!str 1.20
point: !point [1, 2]
exact: !<tag:example.com,2000:thing> value
```

`!!str`, `!!int`, `!!float`, `!!bool` and `!!null` set a scalar's type. Other
tags are kept and not interpreted; a scalar that has one is a string.

## Directives and several documents

```yaml
%YAML 1.2
%TAG !e! tag:example.com,2000:
---
!e!first one
...
---
second
```

`---` starts a document and `...` ends one. Directives come before `---`, at
the start of the file or after `...`. Several documents need `Stream.parse`
(**yaml-zig**(3)).

# COMMENTS

These are kept, and stay with their item when the document is edited:

| Comment | Kept as |
|---|---|
| Lines above an item, with blank lines between items | the item's `before` |
| After an item on its line | the item's `after` |
| Above `---`, and on the `---` line | `header`, `start_comment` |
| On a root that is a scalar or flow collection | `root_comments` |
| After the last item | `footer` |

Runs of blank lines become one. Blank lines above a document's first item are
dropped. When a comment cannot keep its place it moves. For example, if a value
is on the line below its key and both lines have comments, the first becomes a
line above the item.

**One kind is dropped:** comments inside `[...]` or `{...}`. Only the last of
them survives, after the closing bracket, and only if that line has no comment
of its own. Use block style where comments matter.

# OUTPUT

Output is UTF-8. Reading it back gives the same values, types, key order, tags,
anchors and aliases. It is not a byte-for-byte copy of the input:

| In the input | In the output |
|---|---|
| Folded block `>` | Literal block `\|` with the same value |
| A sequence at its key's column | Indented one step |
| Different indentation widths | One width, learned from the first nested block |
| Spacing around `:` and in flow collections | Normalized |
| `? key` where the key fits on one line | `key: value` |
| In a block mapping, a key longer than about 1000 characters, or a block scalar key | `? key` |
| `...` after a single document | Omitted |
| A tag written with a handle or in full | The form the directives allow |
| A flow collection that gains a block collection or comment | Block style |
| An empty value in a flow collection | May be written `null` |

Writing the output a second time can occasionally change the indentation width
(never a value): the width is learned from the first nested block, which may be
one the writer moves onto its `-` line.

Scalars and keys keep their quotes. Plain scalars keep their text, so `7.20`
stays `7.20`. A string or key added by a program is quoted when plain text
would read as another type or break the syntax.

# DIAGNOSTICS

A parse error gives a line, a byte column and a message, for example:

```
2:2: unexpected content after a plain scalar (bad indentation?)
```

For some errors in the structure of a block collection, the column is that of
the line's first character. For UTF-16 and UTF-32 input, columns count the bytes
of its UTF-8 form.

## Common mistakes

| Input | Problem |
|---|---|
| `key: a: b` | `: ` cannot appear in a plain scalar. Quote the value. |
| `key: [a,\nb]` | The continuation line must be indented past `key`. |
| A tab before a nested key | Tabs cannot indent. |
| The same key twice | Keys must differ. |
| `key: *name` before `&name` | An alias needs its anchor above it. |
| `key: @value`, or a leading backquote | Reserved characters. Quote the value. |

# COMPATIBILITY

At tag `data-2022-01-17` of https://github.com/yaml/yaml-test-suite, 400 of 402
cases pass, and the other 2 are rejected on purpose because they repeat a key.
This does not prove full conformance.

Known departures from YAML 1.2.2:

- **Accepted:** a closing `]` or `}` in the same column as the parent key, a
  common habit that libyaml-based readers also accept; a one-line key longer
  than 1024 characters; and a core tag on text that does not match it
  (`!!int abc`), whose typed lookups then return null.
- **Refused:** a key holding an alias that leads back into the key
  (`&a [*a]: x`), and input beyond the limits in **yaml-zig**(3).

Other YAML libraries may read yaml-zig's output differently. YAML 1.1 readers
type `yes` and `no` as booleans, and some do not accept every YAML 1.2 form,
such as an empty key in a flow mapping (`{: v}`).

# SEE ALSO

**yaml-zig**(3), `ai/SPEC.md`, https://yaml.org/spec/1.2.2/

# VERSION

This page describes yaml-zig 0.3.1.
