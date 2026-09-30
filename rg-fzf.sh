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
  Tab         Toggle selection and move to the next line
  Shift-Tab   Toggle selection and move to the previous line
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Enter       Print selected lines (or the current line) and exit
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Esc         Exit

Prompt flags: [H] hidden files on, [V] invert match on

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
            rg --type-list | grep -q "^$2:" || die "unknown file type '$2' (see rg --type-list)"
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

HEADER_CONTENT='C-f:filename | C-e:edit | M-v:invert | M-h:hidden | Tab:select'
HEADER_FILENAME='C-f:content | C-e:edit | M-v:invert | M-h:hidden | Tab:select'

# Private directory for the helper scripts and state, removed on exit.
# State files: content-q and file-q hold the saved query of each mode;
# invert and hidden exist while that toggle is on.
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

if [[ -z $Q ]]; then
    list_files | tr '\0' '\n' | sed 's/$/:1:1:/'
    exit
fi

# --engine auto: fast default regex engine, PCRE2 only when the pattern needs it
# --max-columns: shorten huge lines in the list (they are still searched in full)
RG=(rg --engine auto --ignore-case --column --line-number --no-heading --color=always
    --with-filename --max-columns 500 --max-columns-preview "${HIDDEN[@]}" "${TYPES[@]}")
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
prompt() {
    local flags=""
    [[ -f $S/hidden ]] && flags+="H"
    [[ -f $S/invert ]] && flags+="V"
    [[ -n $flags ]] && flags=" [$flags]"
    echo "$1$flags> "
}

if [[ $FZF_PROMPT == Filename* ]]; then MODE=Filename; else MODE=Content; fi

case $1 in
    toggle-invert|toggle-hidden)
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
            echo "execute-silent(printf '%s' {q} > '$S/content-q')+change-prompt($(prompt Filename))+change-header($HEADER_FILENAME)+enable-search+reload('$SEARCH' --all-files --saved)+transform-query(cat '$S/file-q' 2>/dev/null)"
        else
            echo "execute-silent(printf '%s' {q} > '$S/file-q')+change-prompt($(prompt Content))+change-header($HEADER_CONTENT)+disable-search+reload('$SEARCH' --saved)+transform-query(cat '$S/content-q' 2>/dev/null)"
        fi
        ;;
esac
SCRIPT
} > "$ACTIONS"

chmod +x "$SEARCH" "$ACTIONS"

fzf \
  --ansi \
  --disabled \
  --multi \
  --delimiter ':' \
  --nth 1 \
  --prompt 'Content> ' \
  --header "$HEADER_CONTENT" \
  --bind "start:reload:'$SEARCH' ''" \
  --bind "change:transform:[[ \$FZF_PROMPT == Filename* ]] && echo first || echo \"reload:sleep 0.1; '$SEARCH' {q}\"" \
  --bind "ctrl-f:transform:'$ACTIONS' switch-mode" \
  --bind "alt-v:transform:'$ACTIONS' toggle-invert" \
  --bind "alt-h:transform:'$ACTIONS' toggle-hidden" \
  --bind "tab:toggle+up" \
  --bind "shift-tab:toggle+down" \
  --bind "ctrl-a:select-all" \
  --bind "ctrl-z:deselect-all" \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind "ctrl-e:execute(${EDITOR:-vim} {1} +{2})" \
  --preview 'bat --color=always --highlight-line {2} -- {1} 2>/dev/null || cat -- {1}' \
  --preview-window 'up,60%,border-bottom,+{2}+3/3,~3'
