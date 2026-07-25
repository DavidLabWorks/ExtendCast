# Cross-Platform Workspace Rules

These rules keep the same checkout usable from macOS and Windows, including when
the repository is mounted as a shared drive such as `M:`.

## Source Of Truth

- GitHub `main` is the source of truth.
- Commit and push before switching machines.
- Pull before editing on another machine.
- Do not edit the same file from macOS and Windows at the same time.

## Build Output

- Keep generated build output out of Git.
- Prefer platform-local build directories when possible.
- Avoid running macOS and Windows builds into the same output directory.

Recommended local build locations:

```text
Windows: D:\Build\ExtendCast
macOS: ~/Build/ExtendCast
```

The repository ignores local artifacts such as `artifact-*`, `Desktop/build-*`,
installer `.exe` files, extracted `vdd-*` folders, `platform-tools`, and crash
dumps.

## Line Endings

The repository uses `.gitattributes` to normalize source files to LF. Windows
shell scripts remain CRLF.

Recommended per-checkout Git config:

```bash
git config core.autocrlf false
git config core.eol lf
git config core.safecrlf warn
git config core.filemode false
```

## Daily Flow

Before editing:

```bash
git fetch origin
git pull --rebase
git status
```

After editing:

```bash
git status
git add <source files>
git commit -m "<message>"
git push origin main
```

If both machines need to work in parallel, use separate branches and merge only
after each side is tested.
