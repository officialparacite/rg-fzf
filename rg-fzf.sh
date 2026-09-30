#!/bin/bash

show_help() {
    cat << 'EOF'
Usage: rg-fzf [options] [paths...]

Options:
  -t, --type TYPE     Only search files of this type (js, py, ts, ...).
                      Repeatable: -t js -t ts. See `rg --type-list`.
  -h, --help          Show help

Keybindings:
  Ctrl-E      Open in $EDITOR at matching line
  Ctrl-F      Toggle content/filename mode
  Alt-V       Toggle invert match
  Alt-H       Toggle hidden files
  Alt-P       Toggle PCRE2 (lookarounds, backreferences)
  Tab         Toggle selection and move to the next line
  Shift-Tab   Toggle selection and move to the previous line
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Enter       Print selected lines (or the current line) and exit
  Alt-Enter   Same, as JSON with the query and matched text (needs jq)
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Esc         Exit

Prompt: "Content (regex)" uses ripgrep's default regex engine, "Content (pcre2)" uses
PCRE2 (Alt-P), and "Filename (fuzzy)" fuzzy-matches filenames.
Flags: [H] hidden files on, [V] invert match on, [P] PCRE2 on (shown in filename mode)

Examples:
  rg-fzf                        # Search current directory
  rg-fzf src/                   # Search in src/
  rg-fzf -t js -t ts src/       # Search only .js and .ts files in src/
  rg-fzf file1.txt file2.txt    # Search specific files
EOF
}

die() {
    echo "rg-fzf: $*" >&2
    exit 1
}

for cmd in rg fzf; do
    command -v "$cmd" > /dev/null || die "$cmd is not installed"
done

TYPES=()
PATHS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            [[ $# -ge 2 ]] || die "$1 needs a file type"
            [[ $2 == all ]] || rg --type-list | cut -d: -f1 | grep -qxF -- "$2" ||
                die "unknown file type '$2' (see rg --type-list)"
            TYPES+=(--type "$2")
            shift 2
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

for p in "${PATHS[@]}"; do
    [[ -e $p ]] || die "no such file or directory: $p"
done

HEADER_CONTENT='C-f:filename | C-e:edit | M-v:invert | M-h:hidden | M-p:pcre2 | Tab:select | M-enter:json'
HEADER_FILENAME='C-f:content | C-e:edit | M-v:invert | M-h:hidden | M-p:pcre2 | Tab:select | M-enter:json'

# Private directory for the helper scripts and state, removed on exit.
# State files: content-q and file-q hold the saved query of each mode;
# invert, hidden and pcre2 exist while that toggle is on.
STATE=$(mktemp -d)
SEARCH="$STATE/search.sh"
ACTIONS="$STATE/actions.sh"
trap 'rm -rf "$STATE"' EXIT

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
    emit_array TYPES "${TYPES[@]}"
    emit_array PATHS "${PATHS[@]}"
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

# Files to search, NUL-separated. With a filename filter, fzf picks the names that
# match it (the same matcher filename mode uses), and only those files get searched.
list_files() {
    if [[ -n $FILE_Q ]]; then
        rg --files --null "${HIDDEN[@]}" "${TYPES[@]}" -- "${PATHS[@]}" 2>/dev/null |
            fzf --filter "$FILE_Q" --read0 --print0 --no-sort
    else
        rg --files --null "${HIDDEN[@]}" "${TYPES[@]}" -- "${PATHS[@]}" 2>/dev/null
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
ENGINE=default
[[ -f $S/pcre2 ]] && ENGINE=pcre2
RG=(rg --engine "$ENGINE" --ignore-case --column --line-number --no-heading --color=always
    --with-filename --field-match-separator '\x00:' --max-columns 500 --max-columns-preview
    "${HIDDEN[@]}" "${TYPES[@]}")
[[ -f $S/invert ]] && RG+=(--invert-match)

if [[ -n $FILE_Q ]]; then
    # xargs -r: run nothing if no file matched (rg with no paths would search everything)
    list_files | xargs -0 -r "${RG[@]}" -e "$Q" -- 2>/dev/null
else
    "${RG[@]}" -e "$Q" -- "${PATHS[@]}" 2>/dev/null
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
    if [[ $1 == Filename ]]; then
        [[ $how == pcre2 ]] && flags+="P"
        how=fuzzy
    fi
    [[ -n $flags ]] && flags=" [$flags]"
    echo "$1 ($how)$flags> "
}

if [[ $FZF_PROMPT == Filename* ]]; then MODE=Filename; else MODE=Content; fi

case $1 in
    query-changed)
        # Filename mode: fzf filters live. Content mode: re-run the search.
        # {q} is left for fzf to fill in (it quotes it), never expanded here.
        if [[ $MODE == Filename ]]; then
            echo "first"
        else
            echo "reload(sleep 0.1; '$SEARCH' {q})"
        fi
        ;;
    toggle-invert|toggle-hidden|toggle-pcre2)
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

# fzf prints the query, then the key that closed it (empty for Enter, "alt-enter" for
# Alt-Enter), then the selected lines. Enter: plain file:line:column:text.
# Alt-Enter: JSON {query, results}. Each result's full line and matched text come from
# ripgrep's own JSON output (re-searching just the selected files), never from
# parsing the displayed line.
print_selection() {
    local query key selection="$STATE/selection" matches="$STATE/matches.json"
    IFS= read -r query || return 0
    IFS= read -r key || return 0
    if [[ $key != alt-enter ]]; then
        # LC_ALL=C: treat text as raw bytes, so non-UTF-8 lines pass through intact
        LC_ALL=C tr -d '\0'
        return
    fi
    if ! command -v jq > /dev/null; then
        echo "rg-fzf: jq is needed for JSON output (brew install jq / apt install jq)" >&2
        return 1
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
  --expect alt-enter \
  --print-query \
  --prompt 'Content (regex)> ' \
  --header "$HEADER_CONTENT" \
  --bind "start:reload:'$SEARCH' ''" \
  --bind "change:transform:'$ACTIONS' query-changed" \
  --bind "ctrl-f:transform:'$ACTIONS' switch-mode" \
  --bind "alt-v:transform:'$ACTIONS' toggle-invert" \
  --bind "alt-h:transform:'$ACTIONS' toggle-hidden" \
  --bind "alt-p:transform:'$ACTIONS' toggle-pcre2" \
  --bind "tab:toggle+up" \
  --bind "shift-tab:toggle+down" \
  --bind "ctrl-a:select-all" \
  --bind "ctrl-z:deselect-all" \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind "ctrl-e:execute(${EDITOR:-vim} {1} +{2})" \
  --preview 'bat --color=always --highlight-line {2} -- {1} 2>/dev/null || cat -- {1}' \
  --preview-window 'up,60%,border-bottom,+{2}+3/3,~3' | print_selection
