# Performance baseline

flatxml's own numbers, kept so a change that makes it slower is noticed. The comparison with other
parsers is in the README ("How it compares"); this page compares flatxml with itself.

## How to measure

```sh
tools/baseline.sh --against <rev>          # this tree and <rev>, measured together
tools/baseline.sh                          # this tree alone
```

It builds with `-prod`, writes its documents with `cmd/genxml` into `--workdir` (default
`/tmp/flatxml_baseline`, reused between runs) and prints, for each measurement, the best and the
median of `--runs` runs (default 8, and even with `--against`, so each build runs first in half
the rounds; the median of an even count is the mean of the middle two) and the largest peak memory of the whole process:

| measurement | what is timed |
|---|---|
| `parse` | a 500 MB document (12.6M elements, 12.3M attributes), parsed from bytes already in memory (`tools/compare/flatxml_harness`) |
| `ns` | namespace resolution on the same document, as `flatxml stats` reports it |
| `validate8`, `validate500` | `flatxml validate testdata/inventory.xsd` on 8 MB and 500 MB documents: the whole process (read, parse, namespaces, validation) |
| `merge` | `flatxml merge` of 10 files (5 × 8 MB and 5 × 1 MB documents with the same ids, so every merged node has several contributions; 1.2M elements, 227k merged nodes) by keyed rules |

With `--against` it also checks that the merged view is written byte for byte the same by both
builds (where the older one can write it).

**Compare two builds measured together, never with a number on this page.** Absolute times
move with the compiler, the V version and whatever else the machine is doing. Run it on a machine
that is otherwise idle: with other jobs running (other agents, builds, tests), the same binary's
500 MB parse alternates between about 0.95 s and 1.25 s from one run to the next. That is why the
two builds take turns in the opposite order each round, so neither gets every slow run, and why the
best time is printed beside the median. A difference smaller than about 5% in the best time is
noise on this machine.

## The machine

All numbers below:

- Lenovo laptop, Intel Core Ultra 9 285H (16 cores), 32 GB RAM
- **WSL2** under Windows: Ubuntu 24.04.4 LTS, kernel 6.6.123.2-microsoft-standard-WSL2+,
  documents on the WSL ext4 disk and warm in the page cache
- GCC 13.3.0, V 0.5.2 (ea5156d, V3, `V_MACOS_V3_NO_FALLBACK=1`), built with `-prod`
- other agents were running on the machine at the same time (load average about 2), so these
  numbers are noisier than an idle machine's

## Baseline, 2026-10-16

`main` at 9a69529 against two earlier commits, 8 runs each, in milliseconds: best / median (peak
memory, MB).

| | ffc9510 (2026-10-15, the README's numbers) | 5197d73 (before the merge work) | 9a69529 (now) |
|---|---|---|---|
| parse 500 MB | 967 / 994 (1316) | 978 / 1040 (1316) | 927–946 / 969–1035 (1316) |
| ns 500 MB | 75 / 79 (1179) | 90 / 104 (1233) | 86–93 / 93–100 (1155–1227) |
| validate 8 MB | 30 / 40 (30) | 40 / 40 (30) | 40 / 40–50 (30) |
| validate 500 MB | 1980 / 2035 (1282) | 1980 / 2100 (1236) | 1990–2010 / 2080–2130 (1236–1251) |
| merge 10 files | 228 / 243 (230) | 252 / 260 (232) | 196–198 / 204 (224–232) |

Each older commit was measured in its own run beside `main`, which is why `main` has a range: its
two runs. The validations are whole-process wall times, which `/usr/bin/time` gives in steps of
10 ms, so at 8 MB 30, 40 and 50 are one result rounded.

What the table says:

- **Parsing and validating** are unchanged since the README's numbers: the parser source is the
  same, and the differences are within the noise above.
- **Merge** is about 20% faster than at 5197d73, from the merge work of
  2026-10-16 (sorting without closures, scratch buffers kept by the view). The merged output is the
  same. ffc9510 is faster than 5197d73 because the merge did less then (expanded names, ignored
  attributes, the comparisons between contributions came after it), so the fair before-and-after
  is against 5197d73.
- **Namespace resolution** costs about 15 ms more on 500 MB than at ffc9510 (about 2% of the
  parse): the expanded-name identities for elements and
  attributes (602045d and the local-namespace commits before it). A known cost, not a regression to
  chase.

Not covered: `xsd.Checker` (#32) validating many documents against one schema. Its gain grows with
the number of types the schema has, and `testdata/inventory.xsd` has few: 300 documents of 1 MB
validated about 2% faster with one checker than one validation each. The gain shows on a large
schema such as AUTOSAR's, which is not in this repository.

## When to update this page

Rerun `tools/baseline.sh --against <the last baseline's commit>` after performance work, and
before a release. Add a new baseline section when the numbers move for a reason, and say the
reason; replace the machine section when the machine changes.
