#!/bin/bash

show_help() {
    cat << 'EOF'
Usage: rg-fzf [options] [paths...]

Options:
  -t, --type TYPE     Filter by file type (js, py, ts, etc.)
                      Can be used multiple times: -t js -t ts
  -r, --replace       Enable search & replace mode (with prompt)
  -R, --replace-no-prompt  Replace without prompting
  -h, --help          Show help

Keybindings:
  Ctrl-F    Toggle content/filename mode
  Ctrl-I    Toggle case sensitivity
  Ctrl-V    Toggle invert match
  Ctrl-P    Toggle preview
  Ctrl-D    Scroll preview down
  Ctrl-U    Scroll preview up
  Enter     Open in editor

Examples:
  rg-fzf                        # Search current directory
  rg-fzf src/                   # Search in src/
  rg-fzf -t js -t ts src/       # Search only .js and .ts files in src/
  rg-fzf file1.txt file2.txt    # Search specific files
  rg-fzf -r src/                # Search & replace mode
EOF
    exit 0
}

# Defaults
TYPES=()
PATHS=()
REPLACE_MODE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--type)
            TYPES+=("--type" "$2")
            shift 2
            ;;
        -r|--replace)
            REPLACE_MODE="prompt"
            shift
            ;;
        -R|--replace-no-prompt)
            REPLACE_MODE="no-prompt"
            shift
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

# Base rg command (hidden files included by default)
RG_BASE="rg --pcre2 --column --line-number --no-heading --color=always --hidden"

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

RG_CMD="\$RG_BASE \$CASE_OPT \$INVERT_OPT \$TYPES_STR"

if [[ -n "\$FILE_Q" ]]; then
    \$RG_CMD -g "*\${FILE_Q}*" -- "\$CONTENT_Q" \$PATHS_STR 2>/dev/null || true
else
    \$RG_CMD -- "\$CONTENT_Q" \$PATHS_STR 2>/dev/null || true
fi
SCRIPT
chmod +x "$SEARCH_SCRIPT"

# Create replace script
REPLACE_SCRIPT=$(mktemp)
cat >"$REPLACE_SCRIPT" <<'SCRIPT'
#!/bin/bash
SEARCH="$1"
REPLACE="$2"
MODE="$3"
shift 3
FILES=("$@")

if [[ -z "$SEARCH" || -z "$REPLACE" ]]; then
    echo "Usage: search and replace requires both patterns"
    exit 1
fi

for file in "${FILES[@]}"; do
    if [[ "$MODE" == "prompt" ]]; then
        echo "=== $file ==="
        grep -n "$SEARCH" "$file" 2>/dev/null | head -5
        echo ""
        read -p "Replace in this file? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            sed -i.bak "s/$SEARCH/$REPLACE/g" "$file"
            echo "✓ Replaced"
        else
            echo "✗ Skipped"
        fi
    else
        sed -i.bak "s/$SEARCH/$REPLACE/g" "$file"
        echo "✓ $file"
    fi
done
SCRIPT
chmod +x "$REPLACE_SCRIPT"

# Cleanup
cleanup() {
    rm -f "$SEARCH_SCRIPT" "$REPLACE_SCRIPT"
    rm -f /tmp/fzf-content-q /tmp/fzf-file-q /tmp/fzf-case /tmp/fzf-invert
}
trap cleanup EXIT

# Initialize state files
echo "--smart-case" > /tmp/fzf-case
rm -f /tmp/fzf-content-q /tmp/fzf-file-q /tmp/fzf-invert

# Build initial command
INITIAL_CMD="$RG_BASE --smart-case $TYPES_STR '' $PATHS_STR"

# Replace mode
if [[ -n "$REPLACE_MODE" ]]; then
    echo "Search & Replace Mode"
    echo "===================="
    read -p "Search pattern: " SEARCH_PATTERN
    read -p "Replace with: " REPLACE_PATTERN
    
    FILES=$(rg --pcre2 --hidden --files-with-matches $TYPES_STR "$SEARCH_PATTERN" $PATHS_STR 2>/dev/null)
    
    if [[ -z "$FILES" ]]; then
        echo "No matches found."
        exit 0
    fi
    
    echo ""
    echo "Matching files:"
    echo "$FILES"
    echo ""
    
    if [[ "$REPLACE_MODE" == "prompt" ]]; then
        $REPLACE_SCRIPT "$SEARCH_PATTERN" "$REPLACE_PATTERN" "prompt" $FILES
    else
        read -p "Replace in all files? [y/N] " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            $REPLACE_SCRIPT "$SEARCH_PATTERN" "$REPLACE_PATTERN" "no-prompt" $FILES
            echo "Done!"
        else
            echo "Cancelled."
        fi
    fi
    exit 0
fi

# Normal search mode
fzf \
  --ansi \
  --disabled \
  --multi \
  --delimiter ':' \
  --nth 1 \
  --prompt 'Content [smart-case]> ' \
  --header 'C-f:mode | C-i:case | C-v:invert | C-p:preview | C-d/C-u:scroll' \
  --bind "start:reload:$INITIAL_CMD" \
  --bind "change:reload:sleep 0.1; $SEARCH_SCRIPT {q}" \
  --bind 'ctrl-f:transform:
    if [[ $FZF_PROMPT =~ Content ]]; then
      echo "execute-silent(echo {q} > /tmp/fzf-content-q)+change-prompt(Filename> )+enable-search+unbind(change)+transform-query(cat /tmp/fzf-file-q 2>/dev/null || echo)"
    else
      CASE_LABEL=$(cat /tmp/fzf-case 2>/dev/null | sed "s/--//;s/-/ /")
      echo "execute-silent(echo {q} > /tmp/fzf-file-q)+change-prompt(Content [$CASE_LABEL]> )+disable-search+rebind(change)+reload('"$SEARCH_SCRIPT"' \"\$(cat /tmp/fzf-content-q 2>/dev/null)\")+transform-query(cat /tmp/fzf-content-q 2>/dev/null || echo)"
    fi
  ' \
  --bind 'ctrl-i:transform:
    CURRENT=$(cat /tmp/fzf-case 2>/dev/null || echo "--smart-case")
    if [[ "$CURRENT" == "--smart-case" ]]; then
      echo "--ignore-case" > /tmp/fzf-case
      echo "change-prompt(Content [ignore-case]> )+reload('"$SEARCH_SCRIPT"' {q})"
    elif [[ "$CURRENT" == "--ignore-case" ]]; then
      echo "--case-sensitive" > /tmp/fzf-case
      echo "change-prompt(Content [case-sensitive]> )+reload('"$SEARCH_SCRIPT"' {q})"
    else
      echo "--smart-case" > /tmp/fzf-case
      echo "change-prompt(Content [smart-case]> )+reload('"$SEARCH_SCRIPT"' {q})"
    fi
  ' \
  --bind 'ctrl-v:transform:
    if [[ -f /tmp/fzf-invert ]]; then
      rm /tmp/fzf-invert
      echo "reload('"$SEARCH_SCRIPT"' {q})"
    else
      echo "--invert-match" > /tmp/fzf-invert
      echo "reload('"$SEARCH_SCRIPT"' {q})"
    fi
  ' \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind "enter:execute:${EDITOR:-vim} {1} +{2}" \
  --preview 'bat --color=always --highlight-line {2} {1} 2>/dev/null || cat {1}' \
  --preview-window 'up,60%,border-bottom,+{2}+3/3,~3'
