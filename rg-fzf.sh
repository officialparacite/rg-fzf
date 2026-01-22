#!/bin/bash

show_help() {
    cat << 'EOF'
Usage: rg-fzf [options] [paths...]

Options:
  -t, --type TYPE     Filter by file type (js, py, ts, etc.)
                      Can be used multiple times: -t js -t ts
  -h, --help          Show help

Keybindings:
  Ctrl-F      Toggle content/filename mode
  Ctrl-R      Enter replace mode (only from content mode)
  Alt-C       Toggle case sensitivity
  Alt-V       Toggle invert match
  Alt-S       Toggle follow symlinks
  Alt-H       Toggle hidden files
  Tab         Select item (multiselect)
  Shift-Tab   Deselect item
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Enter       Open in editor (content/filename mode) or apply replace (replace mode)
  Esc         Exit

Examples:
  rg-fzf                        # Search current directory
  rg-fzf src/                   # Search in src/
  rg-fzf -t js -t ts src/       # Search only .js and .ts files in src/
  rg-fzf file1.txt file2.txt    # Search specific files
EOF
    exit 0
}

# Defaults
TYPES=()
PATHS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            TYPES+=("--type" "$2")
            shift 2
            ;;
        -h|--help)
            show_help
            ;;
        *)
            PATHS+=("$1")
            shift
            ;;
    esac
done

# Build paths string
PATHS_STR=""
if [[ ${#PATHS[@]} -gt 0 ]]; then
    PATHS_STR="${PATHS[*]}"
fi

# Build types string
TYPES_STR=""
if [[ ${#TYPES[@]} -gt 0 ]]; then
    TYPES_STR="${TYPES[*]}"
fi

# Base rg command (without hidden/follow - those are now toggleable)
RG_BASE="rg --pcre2 --column --line-number --no-heading --color=always"

# Headers for different modes
HEADER_CONTENT='C-f:filename | C-r:replace | M-c:case | M-v:invert | M-s:symlinks | M-h:hidden | Tab:select'
HEADER_FILENAME='C-f:content | M-c:case | M-v:invert | M-s:symlinks | M-h:hidden | Tab:select'
HEADER_REPLACE='C-f:cancel | C-r:cancel | Tab:select | Enter:apply replace'

# Create helper script for content search
SEARCH_SCRIPT=$(mktemp)
cat >"$SEARCH_SCRIPT" <<SCRIPT
#!/bin/bash
RG_BASE="$RG_BASE"
TYPES_STR="$TYPES_STR"
PATHS_STR="$PATHS_STR"

CONTENT_Q="\$1"
FILE_Q=\$(cat /tmp/fzf-file-q 2>/dev/null)
CASE_OPT=\$(cat /tmp/fzf-case 2>/dev/null || echo "--smart-case")
INVERT_OPT=\$(cat /tmp/fzf-invert 2>/dev/null)
FOLLOW_OPT=\$(cat /tmp/fzf-follow 2>/dev/null)
HIDDEN_OPT=\$(cat /tmp/fzf-hidden 2>/dev/null)

RG_CMD="\$RG_BASE \$CASE_OPT \$INVERT_OPT \$FOLLOW_OPT \$HIDDEN_OPT \$TYPES_STR"

if [[ -n "\$FILE_Q" ]]; then
    \$RG_CMD -g "*\${FILE_Q}*" -- "\$CONTENT_Q" \$PATHS_STR 2>/dev/null || true
else
    \$RG_CMD -- "\$CONTENT_Q" \$PATHS_STR 2>/dev/null || true
fi
SCRIPT
chmod +x "$SEARCH_SCRIPT"

# Create preview script for replace mode
REPLACE_PREVIEW=$(mktemp)
cat >"$REPLACE_PREVIEW" <<'SCRIPT'
#!/bin/bash
FILE="$1"
LINE="$2"
REPLACE="$3"
SEARCH=$(cat /tmp/fzf-search-q 2>/dev/null)

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
    echo "Select a file to preview replacement"
    exit 0
fi

if [[ -z "$SEARCH" ]]; then
    echo "No search pattern"
    exit 0
fi

# Resolve symlink for display
ACTUAL_FILE="$FILE"
if [[ -L "$FILE" ]]; then
    ACTUAL_FILE=$(readlink -f "$FILE")
    echo "[SYMLINK] $FILE -> $ACTUAL_FILE"
    echo ""
fi

echo "Search:  $SEARCH"
echo "Replace: ${REPLACE:-<type replacement above>}"
echo ""

if [[ -n "$REPLACE" ]]; then
    echo "=== After replacement ==="
    echo ""
    sed "s/$SEARCH/$REPLACE/g" "$ACTUAL_FILE" 2>/dev/null | bat --color=always --language="${ACTUAL_FILE##*.}" --style=numbers 2>/dev/null || sed "s/$SEARCH/$REPLACE/g" "$ACTUAL_FILE"
else
    echo "=== Current file ==="
    echo ""
    bat --color=always --highlight-line "$LINE" "$ACTUAL_FILE" 2>/dev/null || cat "$ACTUAL_FILE"
fi
SCRIPT
chmod +x "$REPLACE_PREVIEW"

# Create replace execution script
REPLACE_EXEC=$(mktemp)
cat >"$REPLACE_EXEC" <<'SCRIPT'
#!/bin/bash
SEARCH=$(cat /tmp/fzf-search-q 2>/dev/null)
REPLACE="$1"
shift
FILES=("$@")

if [[ -z "$SEARCH" || -z "$REPLACE" ]]; then
    echo "Error: Missing search or replace pattern"
    read -p "Press enter to continue..."
    exit 1
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "Error: No files selected"
    read -p "Press enter to continue..."
    exit 1
fi

echo "Replacing '$SEARCH' -> '$REPLACE'"
echo ""

count_total=0
declare -A processed_files

for file in "${FILES[@]}"; do
    filepath=$(echo "$file" | cut -d: -f1)
    if [[ -f "$filepath" ]]; then
        # Resolve symlink to actual file
        actual_file="$filepath"
        if [[ -L "$filepath" ]]; then
            actual_file=$(readlink -f "$filepath")
            echo "[SYMLINK] $filepath -> $actual_file"
        fi
        
        # Skip if we already processed this actual file
        if [[ -n "${processed_files[$actual_file]}" ]]; then
            echo "[SKIP] $actual_file (already processed)"
            continue
        fi
        processed_files[$actual_file]=1
        
        count=$(grep -c "$SEARCH" "$actual_file" 2>/dev/null || echo "0")
        if [[ "$count" -gt 0 ]]; then
            sed -i.bak "s/$SEARCH/$REPLACE/g" "$actual_file"
            echo "[OK] $actual_file ($count replacements)"
            count_total=$((count_total + count))
        fi
    fi
done

echo ""
echo "Done! $count_total total replacements"
echo "Backup files created with .bak extension"
read -p "Press enter to continue..."
SCRIPT
chmod +x "$REPLACE_EXEC"

# Cleanup
cleanup() {
    rm -f "$SEARCH_SCRIPT" "$REPLACE_PREVIEW" "$REPLACE_EXEC"
    rm -f /tmp/fzf-content-q /tmp/fzf-file-q /tmp/fzf-case /tmp/fzf-invert /tmp/fzf-search-q /tmp/fzf-replace-q /tmp/fzf-follow /tmp/fzf-hidden
}
trap cleanup EXIT

# Initialize state files (hidden OFF by default)
echo "--smart-case" > /tmp/fzf-case
rm -f /tmp/fzf-content-q /tmp/fzf-file-q /tmp/fzf-invert /tmp/fzf-search-q /tmp/fzf-replace-q /tmp/fzf-follow /tmp/fzf-hidden

# Build initial command (no --hidden flag)
INITIAL_CMD="$RG_BASE --smart-case $TYPES_STR '' $PATHS_STR"

# Normal search mode
fzf \
  --ansi \
  --disabled \
  --multi \
  --delimiter ':' \
  --nth 1 \
  --prompt 'Content [smart-case]> ' \
  --header "$HEADER_CONTENT" \
  --bind "start:reload:$INITIAL_CMD" \
  --bind "tab:toggle+down" \
  --bind "shift-tab:toggle+up" \
  --bind "ctrl-a:select-all" \
  --bind "ctrl-z:deselect-all" \
  --bind 'change:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "preview('"$REPLACE_PREVIEW"' {1} {2} {q})"
    elif [[ $FZF_PROMPT =~ Filename ]]; then
      echo "first"
    else
      echo "reload:sleep 0.1; '"$SEARCH_SCRIPT"' {q}"
    fi
  ' \
  --bind 'ctrl-f:transform:
    if [[ $FZF_PROMPT =~ Content ]]; then
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      FLAGS=""
      [[ -n "$FOLLOW" ]] && FLAGS+="L"
      [[ -n "$HIDDEN" ]] && FLAGS+="H"
      [[ -n "$FLAGS" ]] && FLAGS="[$FLAGS]"
      echo "execute-silent(echo {q} > /tmp/fzf-content-q)+change-prompt(Filename [$CASE_LABEL]${FLAGS}> )+change-header('"$HEADER_FILENAME"')+enable-search+transform-query(cat /tmp/fzf-file-q 2>/dev/null || echo)"
    elif [[ $FZF_PROMPT =~ Filename ]]; then
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      FLAGS=""
      [[ -n "$FOLLOW" ]] && FLAGS+="L"
      [[ -n "$HIDDEN" ]] && FLAGS+="H"
      [[ -n "$FLAGS" ]] && FLAGS="[$FLAGS]"
      echo "execute-silent(echo {q} > /tmp/fzf-file-q)+change-prompt(Content [$CASE_LABEL]${FLAGS}> )+change-header('"$HEADER_CONTENT"')+disable-search+reload('"$SEARCH_SCRIPT"' \"\$(cat /tmp/fzf-content-q 2>/dev/null)\")+transform-query(cat /tmp/fzf-content-q 2>/dev/null || echo)"
    else
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      FLAGS=""
      [[ -n "$FOLLOW" ]] && FLAGS+="L"
      [[ -n "$HIDDEN" ]] && FLAGS+="H"
      [[ -n "$FLAGS" ]] && FLAGS="[$FLAGS]"
      echo "execute-silent(echo {q} > /tmp/fzf-replace-q)+change-prompt(Content [$CASE_LABEL]${FLAGS}> )+change-header('"$HEADER_CONTENT"')+change-preview(bat --color=always --highlight-line {2} {1} 2>/dev/null || cat {1})+transform-query(cat /tmp/fzf-content-q 2>/dev/null || echo)"
    fi
  ' \
  --bind 'ctrl-r:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      FLAGS=""
      [[ -n "$FOLLOW" ]] && FLAGS+="L"
      [[ -n "$HIDDEN" ]] && FLAGS+="H"
      [[ -n "$FLAGS" ]] && FLAGS="[$FLAGS]"
      echo "execute-silent(echo {q} > /tmp/fzf-replace-q)+change-prompt(Content [$CASE_LABEL]${FLAGS}> )+change-header('"$HEADER_CONTENT"')+change-preview(bat --color=always --highlight-line {2} {1} 2>/dev/null || cat {1})+transform-query(cat /tmp/fzf-content-q 2>/dev/null || echo)"
    elif [[ $FZF_PROMPT =~ Filename ]]; then
      echo "first"
    else
      echo "execute-silent(echo {q} > /tmp/fzf-search-q)+execute-silent(echo {q} > /tmp/fzf-content-q)+change-prompt(Replace> )+change-header('"$HEADER_REPLACE"')+preview('"$REPLACE_PREVIEW"' {1} {2} {q})+transform-query(cat /tmp/fzf-replace-q 2>/dev/null || echo)"
    fi
  ' \
  --bind 'alt-c:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "first"
    else
      CURRENT=$(cat /tmp/fzf-case 2>/dev/null || echo "--smart-case")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      FLAGS=""
      [[ -n "$FOLLOW" ]] && FLAGS+="L"
      [[ -n "$HIDDEN" ]] && FLAGS+="H"
      [[ -n "$FLAGS" ]] && FLAGS="[$FLAGS]"
      
      if [[ "$CURRENT" == "--smart-case" ]]; then
        echo "--ignore-case" > /tmp/fzf-case
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [ignore-case]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      elif [[ "$CURRENT" == "--ignore-case" ]]; then
        echo "--case-sensitive" > /tmp/fzf-case
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [case-sensitive]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      else
        echo "--smart-case" > /tmp/fzf-case
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [smart-case]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      fi
    fi
  ' \
  --bind 'alt-v:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "first"
    else
      if [[ -f /tmp/fzf-invert ]]; then
        rm /tmp/fzf-invert
        echo "reload('"$SEARCH_SCRIPT"' {q})"
      else
        echo "--invert-match" > /tmp/fzf-invert
        echo "reload('"$SEARCH_SCRIPT"' {q})"
      fi
    fi
  ' \
  --bind 'alt-s:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "first"
    else
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      HIDDEN=$(cat /tmp/fzf-hidden 2>/dev/null)
      
      if [[ -f /tmp/fzf-follow ]]; then
        rm /tmp/fzf-follow
        FLAGS=""
        [[ -n "$HIDDEN" ]] && FLAGS="[H]"
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [$CASE_LABEL]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      else
        echo "--follow" > /tmp/fzf-follow
        FLAGS="[L"
        [[ -n "$HIDDEN" ]] && FLAGS+="H"
        FLAGS+="]"
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [$CASE_LABEL]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      fi
    fi
  ' \
  --bind 'alt-h:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "first"
    else
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      FOLLOW=$(cat /tmp/fzf-follow 2>/dev/null)
      
      if [[ -f /tmp/fzf-hidden ]]; then
        rm /tmp/fzf-hidden
        FLAGS=""
        [[ -n "$FOLLOW" ]] && FLAGS="[L]"
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [$CASE_LABEL]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      else
        echo "--hidden" > /tmp/fzf-hidden
        FLAGS="["
        [[ -n "$FOLLOW" ]] && FLAGS+="L"
        FLAGS+="H]"
        MODE=$([[ $FZF_PROMPT =~ Filename ]] && echo "Filename" || echo "Content")
        echo "change-prompt($MODE [$CASE_LABEL]${FLAGS}> )+reload('"$SEARCH_SCRIPT"' {q})"
      fi
    fi
  ' \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind 'enter:transform:
    if [[ $FZF_PROMPT =~ Replace ]]; then
      echo "execute('"$REPLACE_EXEC"' {q} {+})"
    else
      echo "execute(${EDITOR:-vim} {1} +{2})"
    fi
  ' \
  --preview 'bat --color=always --highlight-line {2} {1} 2>/dev/null || cat {1}' \
  --preview-window 'up,60%,border-bottom,+{2}+3/3,~3'
