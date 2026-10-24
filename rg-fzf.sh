#!/bin/bash

show_help() {
    cat << 'EOF'
Usage: rg-fzf [options] [paths...]
       command | rg-fzf [options]

Searches the given paths (default: the current directory), or the files listed on
stdin: one per line, or NUL-separated (find -print0, fd -0).

Options:
  -0, --null          Enter prints file names separated by NUL instead of newlines
  -h, --help          Show help

Keybindings:
  Ctrl-E      Open in $EDITOR at matching line
  Ctrl-F      Toggle content/filename mode
  Alt-V       Toggle invert match
  Alt-H       Toggle hidden files (inside directories; listed files are always searched)
  Alt-P       Toggle PCRE2 (lookarounds, backreferences)
  Alt-U       Toggle one result per file (its first match)
  Tab         Toggle selection and move to the next line
  Shift-Tab   Toggle selection and move to the previous line
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Enter       Print the files of the selected lines (or the current line) and exit
  Ctrl-O      Print the selected lines as file:line:column:text and exit
  Alt-Enter   Same as Ctrl-O, as JSON with the query and matched text
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Alt-W       Toggle line wrapping in the preview
  Alt-N       Toggle line numbers in the preview
  Alt-/  F1   Open these keybindings (read-only) in $EDITOR
  Esc         Exit

Prompt: "Content (regex)" uses ripgrep's default regex engine, "Content (pcre2)" uses
PCRE2 (Alt-P), and "Filename (fuzzy)" fuzzy-matches filenames.
Flags: [H] hidden files on, [V] invert match on, [U] one result per file,
[P] PCRE2 on (shown in filename mode)

Examples:
  rg-fzf                        # Search the current directory
  rg-fzf src/ file.txt          # Search these paths
  rg --files -t js | rg-fzf     # Search only .js files
  git ls-files | rg-fzf         # Search only files tracked by git
  rg-fzf | rg-fzf               # Pick files with one search, then search just those
  rg-fzf | xargs nvim           # Open the files you pick
EOF
}

die() {
    echo "rg-fzf: $*" >&2
    exit 1
}

for cmd in rg fzf bat jq; do
    command -v "$cmd" > /dev/null || die "$cmd is not installed"
done

PATHS=()
NUL_OUT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -0|--null)
            NUL_OUT=1
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            PATHS+=("$@")
            break
            ;;
        -*)
            die "unknown option '$1' (see --help)"
            ;;
        *)
            PATHS+=("$1")
            shift
            ;;
    esac
done

# A pipe or a file on stdin is the list of files to search. (/dev/null, as in cron,
# counts as nothing given.)
PIPED=0
[[ -p /dev/stdin || -f /dev/stdin ]] && PIPED=1
[[ $PIPED == 1 && ${#PATHS[@]} -gt 0 ]] && die "give paths or a file list on stdin, not both"
for p in "${PATHS[@]}"; do
    [[ -e $p ]] || die "no such file or directory: $p"
done

HEADER_CONTENT='C-f:filename | C-e:edit | M-v:invert | M-h:hidden | M-p:pcre2 | M-u:unique | C-o:lines | M-enter:json | M-/:keys'
HEADER_FILENAME='C-f:content | C-e:edit | M-v:invert | M-h:hidden | M-p:pcre2 | M-u:unique | C-o:lines | M-enter:json | M-/:keys'

# Private directory for the helper scripts and state, removed on exit.
# State files: content-q and file-q hold the saved query of each mode;
# invert, hidden, pcre2 and unique exist while that toggle is on; nonum exists while
# preview line numbers are off; input is the NUL-separated file list read from stdin.
# rg-fzf-keybindings.txt is the read-only list Alt-/ opens.
STATE=$(mktemp -d)
SEARCH="$STATE/search.sh"
ACTIONS="$STATE/actions.sh"
INPUT=""
trap 'rm -rf "$STATE"' EXIT

# Read the file list. NUL-separated if it contains a NUL (a filename never does),
# otherwise one name per line. Duplicates are dropped; names that don't exist are
# skipped with a warning.
if [[ $PIPED == 1 ]]; then
    INPUT="$STATE/input"
    cat > "$STATE/raw"
    [[ -s $STATE/raw ]] || die "no files given on stdin"
    sep=$'\n'
    IFS= read -r -d '' _ < "$STATE/raw" && sep=''
    missing=0
    while IFS= read -r -d "$sep" f || [[ -n $f ]]; do
        [[ -z $f ]] && continue
        if [[ -e $f ]]; then printf '%s\0' "$f"; else missing=$((missing + 1)); fi
    done < "$STATE/raw" > "$STATE/existing"
    LC_ALL=C sort -zu "$STATE/existing" > "$INPUT"
    rm -f "$STATE/raw" "$STATE/existing"
    [[ -s $INPUT ]] || die "none of the files given on stdin exist"
    [[ $missing -gt 0 ]] && echo "rg-fzf: skipped $missing name(s) from stdin that don't exist" >&2
fi
KEYS_FILE="$STATE/rg-fzf-keybindings.txt"
show_help | sed -n '/^Keybindings:/,/^Examples:/p' | sed '$d' > "$KEYS_FILE"
chmod 444 "$KEYS_FILE"

# Print "NAME=(values...)" shell-quoted, so values with spaces survive into the helpers
emit_array() {
    local name=$1
    shift
    printf '%s=(' "$name"
    [[ $# -gt 0 ]] && printf '%q ' "$@"
    printf ')\n'
}

# Search helper, used for every reload:
#   search.sh QUERY                   search for QUERY within the saved filename filter
#   search.sh --saved                 same, using the saved content query
#   search.sh --all-files --saved     saved content query without the filename filter
#                                     (filename mode, where fzf does that filtering live)
# An empty query lists files instead of matching every line of every file.
{
    echo '#!/bin/bash'
    printf 'S=%q\n' "$STATE"
    emit_array PATHS "${PATHS[@]}"
    printf 'INPUT=%q\n' "$INPUT"
    cat << 'SCRIPT'
FILE_Q=$(cat "$S/file-q" 2>/dev/null)
[[ $1 == --all-files ]] && { FILE_Q=""; shift; }
if [[ $1 == --saved ]]; then
    Q=$(cat "$S/content-q" 2>/dev/null)
else
    Q=$1
fi

HIDDEN=()
[[ -f $S/hidden ]] && HIDDEN=(--hidden)

# Run a command on what to search: the paths given (none means the current
# directory), or the file list from stdin, passed in batches so any length works
on_targets() {
    if [[ -n $INPUT ]]; then
        xargs -0 -r "$@" -- < "$INPUT"
    else
        "$@" -- "${PATHS[@]}"
    fi
}

# Files to search, NUL-separated. With a filename filter, fzf picks the names that
# match it (the same matcher filename mode uses), and only those files get searched.
list_files() {
    if [[ -n $FILE_Q ]]; then
        on_targets rg --files --null "${HIDDEN[@]}" 2>/dev/null |
            fzf --filter "$FILE_Q" --read0 --print0 --no-sort
    else
        on_targets rg --files --null "${HIDDEN[@]}" 2>/dev/null
    fi
}

# Result lines are FILE, LINE, COLUMN and TEXT joined by NUL + ':'. The NUL is
# invisible, so the line displays as file:line:column:text, but a filename can never
# contain NUL, so splitting on it is exact even for names containing ':' and digits.
# The "listing" state file marks when the list shows files (empty query) rather than matches.
if [[ -z $Q ]]; then
    touch "$S/listing"
    list_files | xargs -0 -r printf '%s\0:1\0:1\0:\n'
    exit
fi
rm -f "$S/listing"

# --engine: ripgrep's default regex engine, or PCRE2 while Alt-P is on
# --max-columns: shorten huge lines in the list (they are still searched in full)
# --max-count 1: only each file's first result, while Alt-U is on
ENGINE=default
[[ -f $S/pcre2 ]] && ENGINE=pcre2
RG=(rg --engine "$ENGINE" --ignore-case --column --line-number --no-heading --color=always
    --with-filename --field-match-separator '\x00:' --max-columns 500 --max-columns-preview
    "${HIDDEN[@]}")
[[ -f $S/invert ]] && RG+=(--invert-match)
[[ -f $S/unique ]] && RG+=(--max-count 1)

if [[ -n $FILE_Q ]]; then
    # xargs -r: run nothing if no file matched (rg with no paths would search everything)
    list_files | xargs -0 -r "${RG[@]}" -e "$Q" -- 2>/dev/null
else
    on_targets "${RG[@]}" -e "$Q" 2>/dev/null
fi
SCRIPT
} > "$SEARCH"

# Keybinding helper: prints the fzf actions for a key, based on the current mode ($FZF_PROMPT)
{
    echo '#!/bin/bash'
    printf 'S=%q\n' "$STATE"
    printf 'SEARCH=%q\n' "$SEARCH"
    printf 'HEADER_CONTENT=%q\n' "$HEADER_CONTENT"
    printf 'HEADER_FILENAME=%q\n' "$HEADER_FILENAME"
    cat << 'SCRIPT'
# Prompt: mode, how the typed text is matched, then active toggles.
# Filename mode is always fuzzy, so PCRE2 being on shows as a [P] flag there.
prompt() {
    local how=regex flags=""
    [[ -f $S/pcre2 ]] && how=pcre2
    [[ -f $S/hidden ]] && flags+="H"
    [[ -f $S/invert ]] && flags+="V"
    [[ -f $S/unique ]] && flags+="U"
    if [[ $1 == Filename ]]; then
        [[ $how == pcre2 ]] && flags+="P"
        how=fuzzy
    fi
    [[ -n $flags ]] && flags=" [$flags]"
    echo "$1 ($how)$flags> "
}

if [[ $FZF_PROMPT == Filename* ]]; then MODE=Filename; else MODE=Content; fi

case $1 in
    toggle-numbers)
        if [[ -f $S/nonum ]]; then rm -f "$S/nonum"; else touch "$S/nonum"; fi
        echo "refresh-preview"
        ;;
    query-changed)
        # Filename mode: fzf filters live. Content mode: re-run the search.
        # {q} is left for fzf to fill in (it quotes it), never expanded here.
        if [[ $MODE == Filename ]]; then
            echo "first"
        else
            echo "reload(sleep 0.1; '$SEARCH' {q})"
        fi
        ;;
    toggle-invert|toggle-hidden|toggle-pcre2|toggle-unique)
        f="$S/${1#toggle-}"
        if [[ -f $f ]]; then rm -f "$f"; else touch "$f"; fi
        if [[ $MODE == Filename ]]; then
            # The query box holds filename text here, so re-run the saved content search
            reload="reload('$SEARCH' --all-files --saved)"
        else
            reload="reload('$SEARCH' {q})"
        fi
        echo "change-prompt($(prompt $MODE))+$reload"
        ;;
    switch-mode)
        if [[ $MODE == Content ]]; then
            touch "$S/filename-mode"
            echo "execute-silent(printf '%s' {q} > '$S/content-q')+change-prompt($(prompt Filename))+change-header($HEADER_FILENAME)+enable-search+reload('$SEARCH' --all-files --saved)+transform-query(cat '$S/file-q' 2>/dev/null)"
        else
            rm -f "$S/filename-mode"
            echo "execute-silent(printf '%s' {q} > '$S/file-q')+change-prompt($(prompt Content))+change-header($HEADER_CONTENT)+disable-search+reload('$SEARCH' --saved)+transform-query(cat '$S/content-q' 2>/dev/null)"
        fi
        ;;
esac
SCRIPT
} > "$ACTIONS"

chmod +x "$SEARCH" "$ACTIONS"

# Preview: bat's usual look (header, grid, line numbers; your bat config applies), or
# with Alt-N, bat's plain style: just the highlighted text. The matched line is
# highlighted either way.
# Written for any shell, since fzf runs it with $SHELL (bash, zsh, sh...).
PREVIEW_CMD="if [ -f $(printf '%q' "$STATE/nonum") ]; then set -- --style=plain; else set --; fi;"
PREVIEW_CMD+=' bat --color=always "$@" --highlight-line {2} -- {1} 2>/dev/null || cat -- {1}'

# File names of the result lines on stdin, NUL-terminated. Read in NUL-terminated
# pieces, a line FILE\0:LINE\0:COLUMN\0:TEXT\n splits into FILE, :LINE, :COLUMN and
# ":TEXT\nNEXTFILE". So a name is the first piece, or what follows the newline in a
# piece (TEXT never contains a newline). Bash keeps any byte, so every name survives.
selected_files() {
    local piece first=1
    while IFS= read -r -d '' piece; do
        if [[ $first == 1 ]]; then
            first=0
            printf '%s\0' "$piece"
        elif [[ $piece == *$'\n'?* ]]; then
            printf '%s\0' "${piece#*$'\n'}"
        fi
    done
}

# fzf prints the query, then the key that closed it (empty for Enter), then the selected
# lines. Enter: the files of those lines, unique and sorted, one per line (NUL-separated
# with -0). Ctrl-O: the lines as file:line:column:text. Alt-Enter: JSON {query, results}.
# Each result's full line and matched text come from ripgrep's own JSON output
# (re-searching just the selected files), never from parsing the displayed line.
print_selection() {
    local query key selection="$STATE/selection" matches="$STATE/matches.json"
    IFS= read -r query || return 0
    IFS= read -r key || return 0
    if [[ -z $key ]]; then
        if [[ $NUL_OUT == 1 ]]; then
            LC_ALL=C selected_files | LC_ALL=C sort -zu
        else
            LC_ALL=C selected_files | LC_ALL=C sort -zu | tr '\0' '\n'
        fi
        return
    fi
    if [[ $key == ctrl-o ]]; then
        # LC_ALL=C: treat text as raw bytes, so non-UTF-8 lines pass through intact
        LC_ALL=C tr -d '\0'
        return
    fi
    # In filename mode the query box holds filename text; use the saved search instead
    [[ -f $STATE/filename-mode ]] && query=$(cat "$STATE/content-q" 2>/dev/null)

    cat > "$selection"
    : > "$matches"
    if [[ -f $STATE/listing ]]; then
        jq -Rn --arg q "$query" '{query: $q, results: [inputs | {file: split("\u0000:")[0]}]}' < "$selection"
        return
    fi
    if [[ ! -f $STATE/invert ]]; then
        local engine=default
        [[ -f $STATE/pcre2 ]] && engine=pcre2
        jq -Rnj '[inputs | split("\u0000:")[0]] | unique[] | . + "\u0000"' < "$selection" |
            xargs -0 -r rg --json --engine "$engine" --ignore-case -e "$query" -- > "$matches" 2>/dev/null
    fi
    # Invert-match lines have no column (FILE, LINE, TEXT) and no matches
    jq -n --arg q "$query" --rawfile sel "$selection" --slurpfile rg "$matches" '
        ($rg | map(select(.type == "match") | .data
               | {key: "\(.path.text)\u0000\(.line_number)",
                  value: {text: (.lines.text // null | if . then rtrimstr("\n") | rtrimstr("\r") else . end),
                          matches: [.submatches[].match.text // empty]}})
             | from_entries) as $hits
        | {query: $q, results: [
            $sel | split("\n")[] | select(length > 0) | split("\u0000:")
            | if length == 3 then {file: .[0], line: (.[1] | tonumber), text: .[2]}
              else {file: .[0], line: (.[1] | tonumber), column: (.[2] | tonumber),
                    text: (.[3:] | join("\u0000:"))}
                   | $hits["\(.file)\u0000\(.line)"] as $h
                   | .text = ($h.text // .text) | .matches = ($h.matches // [])
              end]}'
}

fzf \
  --ansi \
  --disabled \
  --multi \
  --delimiter '\x00:' \
  --nth 1 \
  --expect alt-enter,ctrl-o \
  --print-query \
  --prompt 'Content (regex)> ' \
  --header "$HEADER_CONTENT" \
  --bind "start:reload:'$SEARCH' ''" \
  --bind "change:transform:'$ACTIONS' query-changed" \
  --bind "ctrl-f:transform:'$ACTIONS' switch-mode" \
  --bind "alt-v:transform:'$ACTIONS' toggle-invert" \
  --bind "alt-h:transform:'$ACTIONS' toggle-hidden" \
  --bind "alt-p:transform:'$ACTIONS' toggle-pcre2" \
  --bind "alt-u:transform:'$ACTIONS' toggle-unique" \
  --bind "tab:toggle+up" \
  --bind "shift-tab:toggle+down" \
  --bind "ctrl-a:select-all" \
  --bind "ctrl-z:deselect-all" \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind "ctrl-e:execute(${EDITOR:-vim} {1} +{2})" \
  --bind "alt-w:toggle-preview-wrap" \
  --bind "alt-n:transform:'$ACTIONS' toggle-numbers" \
  --bind "alt-/:execute:${EDITOR:-vim} $(printf '%q' "$KEYS_FILE")" \
  --bind "f1:execute:${EDITOR:-vim} $(printf '%q' "$KEYS_FILE")" \
  --preview "$PREVIEW_CMD" \
  --preview-window 'up,60%,border-bottom,+{2}+3/3,~3' < /dev/null | print_selection
