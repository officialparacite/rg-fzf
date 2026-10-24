# rg-fzf

Interactive code search in the terminal. Type a pattern, and [ripgrep](https://github.com/BurntSushi/ripgrep) searches your files live while [fzf](https://github.com/junegunn/fzf) shows the results with a highlighted preview. Press Ctrl-E to jump straight to the match in your editor.

## Features

- Live search as you type, case-insensitive
- Regex search, with a PCRE2 toggle (`Alt-P`) for lookarounds and backreferences
- Preview of each match in context, with syntax highlighting via [bat](https://github.com/sharkdp/bat)
- Filename mode to narrow the current results down to matching files
- Toggles for invert match and hidden files
- Pipe in the files to search (`fd`, `find`, `git ls-files`, or another rg-fzf)
- One result per file, to see just which files match
- Multi-select lines and print their files, the lines themselves, or JSON
- Opens the match in `$EDITOR` at the right line

## Requirements

| Tool | Notes | macOS | Debian/Ubuntu |
|------|-------|-------|---------------|
| ripgrep | Needs PCRE2 support for `Alt-P` (Homebrew builds include it) | `brew install ripgrep` | `apt install ripgrep` |
| fzf | 0.45 or newer | `brew install fzf` | `apt install fzf` |
| bat | Syntax highlighting in the preview | `brew install bat` | `apt install bat` |
| jq | JSON output (`Alt-Enter`); included with macOS 15+ | `brew install jq` | `apt install jq` |

All four are required; rg-fzf checks for them at startup and tells you which one is missing.

Check your versions before installing:

```bash
fzf --version   # needs 0.45 or newer
rg --version    # look for +pcre2 in the features line, for Alt-P
```

Linux package managers often ship an older fzf. If `fzf --version` shows less than 0.45, install a newer one from the [fzf releases page](https://github.com/junegunn/fzf/releases) or with `git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf && ~/.fzf/install`. With an older fzf, rg-fzf starts but its keybindings fail.

## Installation

```bash
git clone <repo-url> rg-fzf
chmod +x rg-fzf/rg-fzf.sh
cp rg-fzf/rg-fzf.sh ~/.local/bin/rg-fzf   # any directory on your PATH
```

Make sure `$EDITOR` is exported in your shell config, e.g. `export EDITOR=nvim` in `~/.zshrc`. If it isn't set, `vim` is used.

## Usage

```bash
rg-fzf [options] [paths...]
command | rg-fzf [options]
```

| Option | Description |
|--------|-------------|
| `-0, --null` | `Enter` prints file names separated by NUL instead of newlines, for names containing newlines |
| `-h, --help` | Show help |

With no paths, the current directory is searched. If something is piped in (or a file redirected with `<`), that is the list of files to search instead:

- One name per line, or NUL-separated (`find -print0`, `fd -0`). rg-fzf tells which by itself: a list containing a NUL is NUL-separated, since filenames can't contain one.
- Directories in the list are searched inside. Duplicates are dropped, and names that don't exist are skipped with a warning.
- An empty list is an error, and so is giving both a list and paths.

### Examples

```bash
rg-fzf                         # search the current directory
rg-fzf src/ app.ts             # search these paths
rg --files -t js | rg-fzf      # only .js files (see rg --type-list)
fd -e py | rg-fzf              # only .py files, using fd
git ls-files | rg-fzf          # only files tracked by git
find . -mtime -1 -type f | rg-fzf   # only files changed in the last day
```

### Chaining

`Enter` prints the files of the lines you selected, so the output of one rg-fzf can feed another, or any command that takes file names:

```bash
rg-fzf | rg-fzf          # pick files with one search, then search just those
rg-fzf | xargs nvim      # open the files you pick
rg-fzf -0 | xargs -0 rm  # NUL-separated, safe for any filename
```

In `rg-fzf | rg-fzf`, the second one starts only after you finish with the first.

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl-E` | Open the selected match in `$EDITOR` at that line |
| `Ctrl-F` | Switch between content search and filename mode |
| `Alt-V` | Toggle invert match (show lines that don't match) |
| `Alt-H` | Toggle searching hidden files inside directories (off by default). Files named directly, or in a piped list, are always searched. |
| `Alt-P` | Toggle PCRE2, for lookarounds and backreferences (off by default) |
| `Alt-U` | Toggle one result per file: each file once, at its first match (off by default) |
| `Tab` / `Shift-Tab` | Toggle selection of a line and move to the next / previous line |
| `Ctrl-A` / `Ctrl-Z` | Select all / deselect all |
| `Enter` | Print the files of the selected lines (or the current line), each once, and exit |
| `Ctrl-O` | Print the selected lines as `file:line:column:text` and exit |
| `Alt-Enter` | Same as `Ctrl-O`, but as JSON with the query and matched text |
| `Ctrl-P` | Toggle the preview window |
| `Ctrl-D` / `Ctrl-U` | Scroll the preview down / up |
| `Alt-W` | Toggle wrapping of long lines in the preview, so you see each line in full (off by default) |
| `Alt-N` | Toggle the preview between bat's normal look (file name, grid, line numbers) and plain highlighted text (on by default) |
| `Alt-/` or `F1` | Open the list of keybindings, read-only, in `$EDITOR`; close it to return |
| `Esc` | Exit |

The prompt shows how your text is matched: `Content (regex)`, `Content (pcre2)` while PCRE2 is on, or `Filename (fuzzy)`. Active toggles appear after it: `[H]` for hidden files, `[V]` for invert match, `[U]` for one result per file, and `[P]` in filename mode while PCRE2 is on.

## How it works

- **Empty search box:** shows a list of files rather than every line of every file, which keeps startup fast in large directories.
- **Content mode:** each keystroke re-runs ripgrep with your pattern. By default ripgrep uses its fast regex engine, which doesn't support lookarounds (`(?=...)`, `(?<=...)`) or backreferences (`\1`); a pattern using them shows no results. Press `Alt-P` to switch to PCRE2 for those. PCRE2 is slower on large searches, and patterns with heavy backtracking such as `(a+)+$` can make ripgrep skip files.
- **One result per file (`Alt-U`):** ripgrep stops at the first match in each file, so the list shows each file once. The preview and `Ctrl-E` go to that first match. `Ctrl-O` and `Alt-Enter` print what you see: one line per file. With invert match on, it's each file's first non-matching line.
- **Filename mode (`Ctrl-F`):** fuzzy-filters the current results by filename. When you switch back to content mode, the same filename filter stays applied, so you keep exactly the files you narrowed down to. Entering filename mode again reloads every match for your search, with your previous filename text filled in, so you can change which files you picked.

`Enter` prints file names, sorted, one per line. `Ctrl-O` prints lines of the form `file:line:column:text`. `Alt-Enter` prints the same selection as JSON, with the search pattern and the text each line matched:

```json
{
  "query": "init\\w+",
  "results": [
    { "file": "src/app.js", "line": 12, "column": 5, "text": "const initialLevel = data.initialLevel;", "matches": ["initialLevel", "initialLevel"] }
  ]
}
```

`matches` lists every match on the line, in the case it appears in the file. The line and matches come from ripgrep re-searching the selected files, so `text` is the complete line even when it's longer than 500 characters. With invert match on, results have no `column` or `matches`. From the empty-search file list, results are just `{ "file": ... }`. Backslashes before quotes (`\"`) are standard JSON escaping; any JSON parser, or `jq -r '.results[].text'`, gives back the original text.

Internally the fields are separated by an invisible NUL character (filenames can't contain one), so filenames with `:` or digits in them are handled correctly by the preview, `Ctrl-E`, filename mode and JSON output.

## Limitations

- Patterns can't match across lines.
- Lines longer than 500 characters are shortened in the results list and in `Ctrl-O` output. They are still searched in full, and the preview, editor and JSON output show the whole line.
- Searching is always case-insensitive.
- Filenames containing a newline show up split across two rows, and those rows won't preview or open correctly. Such names are very rare.
- Bytes that aren't valid UTF-8 (e.g. in Latin-1 files) appear as `�` in the list and in `Ctrl-O` and JSON output. The preview and editor show the file as it is.
- `Ctrl-E` runs `$EDITOR FILE +LINE`. That works for vim, nvim, nano, emacs and similar editors; editors that use a different syntax (e.g. VS Code's `--goto`) will open the file but not jump to the line.

## License

MIT. See [LICENSE](LICENSE).
