# rg-fzf

Interactive code search in the terminal. Type a pattern, and [ripgrep](https://github.com/BurntSushi/ripgrep) searches your files live while [fzf](https://github.com/junegunn/fzf) shows the results with a highlighted preview. Press Ctrl-E to jump straight to the match in your editor.

## Features

- Live search as you type, case-insensitive
- Regex support, including lookarounds and backreferences (PCRE2) when a pattern needs them
- Preview of each match in context, with syntax highlighting via [bat](https://github.com/sharkdp/bat)
- Filename mode to narrow the current results down to matching files
- Toggles for invert match and hidden files
- Multi-select lines and print them on exit, as plain text or JSON
- File-type filtering with `-t`
- Opens the match in `$EDITOR` at the right line

## Requirements

| Tool | Notes | macOS | Debian/Ubuntu |
|------|-------|-------|---------------|
| ripgrep | Needs PCRE2 support for lookaround/backreference patterns (Homebrew builds include it) | `brew install ripgrep` | `apt install ripgrep` |
| fzf | 0.45 or newer | `brew install fzf` | `apt install fzf` |
| bat | Optional; preview falls back to plain text without it | `brew install bat` | `apt install bat` |
| jq | Only for JSON output (`Alt-Enter`); included with macOS 15+ | `brew install jq` | `apt install jq` |

Check PCRE2 support with `rg --version` (look for `+pcre2`).

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
```

| Option | Description |
|--------|-------------|
| `-t, --type TYPE` | Only search files of this type (`js`, `py`, `rust`, ...). Repeatable. See `rg --type-list`. |
| `-h, --help` | Show help |

With no paths, the current directory is searched.

### Examples

```bash
rg-fzf                      # search the current directory
rg-fzf src/ tests/          # search specific directories
rg-fzf -t js -t ts src/     # only .js and .ts files in src/
rg-fzf app.ts utils.ts      # search specific files
```

## Keybindings

| Key | Action |
|-----|--------|
| `Ctrl-E` | Open the selected match in `$EDITOR` at that line |
| `Ctrl-F` | Switch between content search and filename mode |
| `Alt-V` | Toggle invert match (show lines that don't match) |
| `Alt-H` | Toggle searching hidden files (off by default) |
| `Tab` / `Shift-Tab` | Toggle selection of a line and move to the next / previous line |
| `Ctrl-A` / `Ctrl-Z` | Select all / deselect all |
| `Enter` | Print the selected lines (or the current line) and exit |
| `Alt-Enter` | Same, but print them as JSON with the query and matched text (needs `jq`) |
| `Ctrl-P` | Toggle the preview window |
| `Ctrl-D` / `Ctrl-U` | Scroll the preview down / up |
| `Esc` | Exit |

The prompt shows active toggles: `[H]` for hidden files, `[V]` for invert match.

## How it works

- **Empty search box:** shows a list of files rather than every line of every file, which keeps startup fast in large directories.
- **Content mode:** each keystroke re-runs ripgrep with your pattern. ripgrep uses its fast default regex engine and switches to PCRE2 only when the pattern requires it.
- **Filename mode (`Ctrl-F`):** fuzzy-filters the current results by filename. When you switch back to content mode, the same filename filter stays applied, so you keep exactly the files you narrowed down to. Entering filename mode again reloads every match for your search, with your previous filename text filled in, so you can change which files you picked.

Printed lines (`Enter`) have the form `file:line:column:text`. `Alt-Enter` prints the same selection as JSON, with the search pattern and the text each line matched:

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
- Lines longer than 500 characters are shortened in the results list and in `Enter` output. They are still searched in full, and the preview, editor and JSON output show the whole line.
- Searching is always case-insensitive.
- Filenames containing a newline show up split across two rows, and those rows won't preview or open correctly. Such names are very rare.
- Bytes that aren't valid UTF-8 (e.g. in Latin-1 files) appear as `�` in the list and in `Enter` and JSON output. The preview and editor show the file as it is.
- `Ctrl-E` runs `$EDITOR FILE +LINE`. That works for vim, nvim, nano, emacs and similar editors; editors that use a different syntax (e.g. VS Code's `--goto`) will open the file but not jump to the line.

## License

MIT. See [LICENSE](LICENSE).
