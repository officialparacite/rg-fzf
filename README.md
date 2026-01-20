# rg-fzf

A powerful interactive search tool combining [ripgrep](https://github.com/BurntSushi/ripgrep) and [fzf](https://github.com/junegunn/fzf) with PCRE2 regex support, live preview, and mode switching.

## Features

- **PCRE2 Regex** - Full Perl-compatible regex support (lookaheads, lookbehinds, etc.)
- **Live Preview** - See matches highlighted in context with bat
- **Mode Switching** - Toggle between content search and filename filtering
- **Case Sensitivity** - Cycle between smart-case, ignore-case, and case-sensitive
- **Invert Match** - Find lines that don't match the pattern
- **File Type Filtering** - Restrict search to specific file types
- **Search & Replace** - Interactive find and replace across files
- **Hidden Files** - Searches hidden files by default

## Dependencies

### Required

| Tool | Installation |
|------|--------------|
| [ripgrep](https://github.com/BurntSushi/ripgrep) (with PCRE2) | `cargo install ripgrep --features pcre2` |
| [fzf](https://github.com/junegunn/fzf) | `apt install fzf` |
| [bat](https://github.com/sharkdp/bat) | `apt install bat` |


## Installation

```bash
# Clone the repository
git clone https://github.com/officialparacite/rg-fzf.git

# Make executable
chmod +x rg-fzf/rg-fzf.sh

# Optional: Add to PATH
cp rg-fzf/rg-fzf.sh ~/.local/bin/rg-fzf
```

## Usage

```bash
rg-fzf [options] [paths...]
```

### Options

| Option | Description |
|--------|-------------|
| `-t, --type TYPE` | Filter by file type (js, py, ts, etc.). Can be used multiple times. |
| `-h, --help` | Show help |

### Keybindings

| Key | Action |
|-----|--------|
| `Ctrl-F` | Toggle between content search and filename filter mode |
| `Ctrl-I` | Cycle case sensitivity: smart → ignore → sensitive |
| `Ctrl-V` | Toggle invert match (find non-matching lines) |
| `Ctrl-P` | Toggle preview window |
| `Ctrl-D` | Scroll preview down |
| `Ctrl-U` | Scroll preview up |
| `Enter` | Open selected file in editor at matching line |
| `Esc` | Exit |

## Examples

### Basic Search

```bash
# Search in current directory
rg-fzf

# Search in specific directory
rg-fzf src/

# Search in multiple directories
rg-fzf src/ tests/ docs/

# Search specific files
rg-fzf src/app.ts src/utils.ts
```

### File Type Filtering

```bash
# Search only JavaScript files
rg-fzf -t js

# Search JavaScript and TypeScript files
rg-fzf -t js -t ts

# Search Python files in src/
rg-fzf -t py src/
```

## File Type Reference

Common file types for `-t` flag:

| Type | Extensions |
|------|------------|
| `js` | `.js`, `.mjs`, `.cjs` |
| `ts` | `.ts`, `.tsx` |
| `py` | `.py` |
| `rust` | `.rs` |
| `go` | `.go` |
| `c` | `.c`, `.h` |
| `cpp` | `.cpp`, `.hpp`, `.cc` |
| `java` | `.java` |
| `json` | `.json` |
| `yaml` | `.yaml`, `.yml` |
| `md` | `.md`, `.markdown` |
| `html` | `.html`, `.htm` |
| `css` | `.css` |

See all types: `rg --type-list`

## Limitations

- **Filename filter uses glob, not fuzzy**: When you switch back to content mode, the filename filter becomes a glob pattern (`*pattern*`), not fuzzy search. Type substrings that actually appear in filenames.
- **No multiline search**: `\n` in patterns won't match across lines (ripgrep limitation with fzf integration).

## License

MIT

## Acknowledgments

- [ripgrep](https://github.com/BurntSushi/ripgrep) by Andrew Gallant
- [fzf](https://github.com/junegunn/fzf) by Junegunn Choi
- [bat](https://github.com/sharkdp/bat) by David Peter
