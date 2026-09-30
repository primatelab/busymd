#!/usr/bin/env bash

# BUSYMD - Markdown Viewer for Busybox and Beyond
# Pure bash markdown renderer with no external dependencies
#
# Usage:
#   ./busymd.sh FILE.md                        # Run as script directly
#
# For ZSH users, add this to ~/.zshrc:
#   busymd() { bash /Users/avi/git/markdown-viewer-terminal/busymd.sh "$@"; }
#
# For BASH users, you can source it:
#   source busymd.sh && busymd FILE.md

# Only set strict mode when running as script, not when sourcing
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    set -euo pipefail
fi

# Only define variables if not already set (for sourcing in bashrc/zshrc)
# Check if R is already defined - if so, skip all initialization
if [[ -z ${R+x} ]]; then
    # Never use readonly - it prevents re-sourcing
    R=$'\033[0m'      # Reset
    B=$'\033[1m'      # Bold
    I=$'\033[3m'      # Italic
    U=$'\033[4m'      # Underline
    S=$'\033[9m'      # Strikethrough
    D=$'\033[2m'      # Dim

    # Authentic Monokai color palette (RGB)
    W=$'\033[38;2;248;248;242m'   # #F8F8F2 - White (bold text, H1)
    Y=$'\033[38;2;230;219;116m'   # #E6DB74 - Yellow (strings, italic)
    G=$'\033[38;2;166;226;46m'    # #A6E22E - Green (code, functions)
    O=$'\033[38;2;253;151;31m'    # #FD971F - Orange (parameters, bold+italic)
    M=$'\033[38;2;174;129;255m'   # #AE81FF - Purple (constants, H3)
    RED=$'\033[38;2;255;120;160m' # Very bright pink for maximum visibility
    C=$'\033[38;2;102;217;239m'   # #66D9EF - Blue (classes, links, borders)
    BL=$'\033[38;2;102;217;239m'  # #66D9EF - Blue (same as C for consistency)
    GR=$'\033[38;2;150;150;130m'  # Lighter gray for comments (more visible)

    BG=$'\033[48;2;39;40;34m'     # #272822 - Monokai background (inline code)
    BB=$'\033[48;2;39;40;34m'     # #272822 - Monokai background (code lang tag)
fi

in_code=0
code_num=0

WIDTH=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}

repeat_char() {
    local char=$1 count=$2 result=""
    printf -v result '%*s' "$count"
    echo "${result// /$char}"
}

format_text() {
    local t="$1" m
    
    # Bold+Italic: ***text*** (must be before ** and *)
    while [[ $t =~ \*\*\*([^*]+)\*\*\* ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${B}${I}${O}${BASH_REMATCH[1]}${R}}"
    done
    
    # Bold: **text** or __text__
    while [[ $t =~ \*\*([^*]+)\*\* ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${B}${RED}${BASH_REMATCH[1]}${R}}"
    done
    
    while [[ $t =~ __([^_]+)__ ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${B}${RED}${BASH_REMATCH[1]}${R}}"
    done
    
    # Italic: *text* or _text_
    while [[ $t =~ \*([^*]+)\* ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${I}${Y}${BASH_REMATCH[1]}${R}}"
    done
    
    while [[ $t =~ _([^_]+)_ ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${I}${Y}${BASH_REMATCH[1]}${R}}"
    done
    
    # Strikethrough: ~~text~~
    while [[ $t =~ ~~([^~]+)~~ ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${S}${GR}${BASH_REMATCH[1]}${R}}"
    done
    
    # Inline code: `text`
    while [[ $t =~ \`([^\`]+)\` ]]; do
        m="${BASH_REMATCH[0]}"
        t="${t/"$m"/${BG}${RED} ${BASH_REMATCH[1]} ${R}}"
    done
    
    echo "$t"
}

# Visible character count, ignoring ANSI color sequences
visible_len() {
    local s="$1"
    local re=$'\033[[][0-9;]*[a-zA-Z]'
    while [[ $s =~ $re ]]; do
        s="${s//"${BASH_REMATCH[0]}"}"
    done
    echo "${#s}"
}

# Trim leading and trailing whitespace from a table cell
trim_cell() {
    local s="$1"
    if [[ $s =~ ^[[:space:]]+(.*)$ ]]; then
        s="${BASH_REMATCH[1]}"
    fi
    if [[ $s =~ ^(.*[^[:space:]])[[:space:]]+$ ]]; then
        s="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$s"
}

# Pad text to a visible width. align is left, right, or center.
pad_cell() {
    local text="$1" width="$2" align="${3:-left}"
    local len left_pad right_pad
    len=$(visible_len "$text")
    if (( len >= width )); then
        printf '%s' "$text"
        return 0
    fi
    case "$align" in
        right)
            printf '%s%s' "$(repeat_char ' ' $((width - len)))" "$text"
            ;;
        center)
            left_pad=$(( (width - len) / 2 ))
            right_pad=$(( width - len - left_pad ))
            printf '%s%s%s' "$(repeat_char ' ' "$left_pad")" "$text" "$(repeat_char ' ' "$right_pad")"
            ;;
        *)
            printf '%s%s' "$text" "$(repeat_char ' ' $((width - len)))"
            ;;
    esac
}

# Field idx from a unit-separator-terminated packed row.
# `row` is assigned on its own so it does not see the caller's packed array.
nth_field() {
    local row="$1" idx="$2"
    local rest="$row" n=0 cell fs=$'\x1F'
    while [[ $rest == *"$fs"* ]]; do
        cell="${rest%%"$fs"*}"
        rest="${rest#*"$fs"}"
        if (( n == idx )); then
            printf '%s' "$cell"
            return 0
        fi
        n=$((n + 1))
    done
}

table_rule() {
    local left="$1" join="$2" right="$3"
    shift 3
    local -a widths=("$@")
    local out="${C}${left}" c
    for ((c=0; c<${#widths[@]}; c++)); do
        if (( c > 0 )); then
            out+="${join}"
        fi
        out+="$(repeat_char '─' $(( widths[c] + 2 )))"
    done
    echo "${out}${right}${R}"
}

# Draw a collected markdown table as a padded box
render_box_table() {
    local -a lines=("$@")
    local n=${#lines[@]}
    if (( n == 0 )); then
        return 0
    fi

    local -a packed=() seps=()
    local max_cols=0
    local fs=$'\x1F'
    local i j line rest cell count vlen

    for ((i=0; i<n; i++)); do
        line="${lines[i]}"
        if [[ $line =~ ^\|[[:space:]:\|\-]+\|$ ]]; then
            seps[i]=1
        else
            seps[i]=0
        fi
        line="${line#|}"
        line="${line%|}"
        rest="$line"
        packed[i]=""
        count=0
        while [[ $rest =~ ^([^|]*)\|(.*)$ ]]; do
            cell="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            packed[i]+="$(trim_cell "$cell")${fs}"
            count=$((count + 1))
        done
        packed[i]+="$(trim_cell "$rest")${fs}"
        count=$((count + 1))
        if (( count > max_cols )); then
            max_cols=$count
        fi
    done

    local -a disp=() widths=() aligns=()
    for ((j=0; j<max_cols; j++)); do
        widths[j]=0
        aligns[j]=left
    done

    for ((i=0; i<n; i++)); do
        for ((j=0; j<max_cols; j++)); do
            cell=$(nth_field "${packed[i]}" "$j")
            if (( seps[i] )); then
                if [[ $cell =~ ^:-+:$ ]]; then
                    aligns[j]=center
                elif [[ $cell =~ ^-+:$ ]]; then
                    aligns[j]=right
                fi
            else
                cell=$(inline "$cell")
                disp[i*max_cols+j]="$cell"
                vlen=$(visible_len "$cell")
                if (( vlen > widths[j] )); then
                    widths[j]=$vlen
                fi
            fi
        done
    done

    local out
    table_rule "┌" "┬" "┐" "${widths[@]}"
    for ((i=0; i<n; i++)); do
        if (( seps[i] )); then
            table_rule "├" "┼" "┤" "${widths[@]}"
            continue
        fi
        out="${C}│${R}"
        for ((j=0; j<max_cols; j++)); do
            cell=$(pad_cell "${disp[i*max_cols+j]:-}" "${widths[j]}" "${aligns[j]}")
            out+=" ${cell} ${C}│${R}"
        done
        echo "$out"
    done
    table_rule "└" "┴" "┘" "${widths[@]}"
}

inline() {
    local t="$1" m link_text placeholder
    local -a replacements=()
    local placeholder_idx=0
    local PH=$'\x1F'  # ASCII Unit Separator - won't be in normal text
    
    # HTML links with bold: <a href="url"><b>text</b></a> - MUST be before plain <b> tags!
    while [[ $t =~ \<a[[:space:]]+href=\"([^\"]+)\"\>\<b\>([^\<]+)\</b\>\</a\> ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${B}${M}${U}${BASH_REMATCH[2]}${R} ${G}→${R} ${G}${BASH_REMATCH[1]}${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # HTML links: <a href="url">text</a>
    while [[ $t =~ \<a[[:space:]]+href=\"([^\"]+)\"\>([^\<]+)\</a\> ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${B}${M}${U}${BASH_REMATCH[2]}${R} ${G}→${R} ${G}${BASH_REMATCH[1]}${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # HTML bold tags: <b>text</b>
    while [[ $t =~ \<b\>([^\<]+)\</b\> ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${B}${RED}${BASH_REMATCH[1]}${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # Footnote references: [^1] - MUST be before other bracket patterns!
    while [[ $t =~ \[\^([0-9]+)\] ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${M}[${BASH_REMATCH[1]}]${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # Linked images: [![alt](img-url)](link-url) - MUST be first!
    # Use variable to avoid bash version regex escaping issues
    local img_link_pattern='\[!\[([^]]*)\]\(([^)]+)\)\]\(([^)]+)\)'
    while [[ $t =~ $img_link_pattern ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${M}${U}🖼  ${BASH_REMATCH[1]}${R} ${BL}→${R} ${BL}${BASH_REMATCH[3]}${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # Images: ![alt](url)
    local img_pattern='!\[([^]]*)\]\(([^)]+)\)'
    while [[ $t =~ $img_pattern ]]; do
        m="${BASH_REMATCH[0]}"
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${M}🖼  ${BASH_REMATCH[1]}${R} ${D}${C}[${BASH_REMATCH[2]}]${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # Links: [text](url) - Format the link text first!
    local link_pattern='\[([^]]+)\]\(([^)]+)\)'
    while [[ $t =~ $link_pattern ]]; do
        m="${BASH_REMATCH[0]}"
        link_text=$(format_text "${BASH_REMATCH[1]}")
        placeholder="${PH}${placeholder_idx}${PH}"
        replacements[$placeholder_idx]="${B}${M}${U}${link_text}${R} ${G}→${R} ${G}${BASH_REMATCH[2]}${R}"
        t="${t/"$m"/$placeholder}"
        placeholder_idx=$((placeholder_idx + 1))
    done
    
    # Format remaining text (not in links/images)
    t=$(format_text "$t")
    
    # Restore placeholders
    for ((i=0; i<placeholder_idx; i++)); do
        t="${t//${PH}${i}${PH}/${replacements[$i]}}"
    done
    
    echo "$t"
}

render() {
    local input="$1" line prev_empty=1 pending="" pending_set=0
    local -a table_lines=()
    
    [[ -f "$input" ]] || input="/dev/stdin"
    
    while true; do
        if ((pending_set)); then
            line="$pending"
            pending_set=0
            pending=""
        elif ! IFS= read -r line; then
            break
        fi
        # Code blocks: ```lang (with optional leading whitespace)
        if [[ $line =~ ^[[:space:]]*\`\`\`(.*)$ ]]; then
            if ((in_code == 0)); then
                in_code=1
                code_num=0
                local lang="${BASH_REMATCH[1]}"
                lang="${lang# }"  # Trim leading space
                ((prev_empty == 0)) && echo ""
                [[ -n $lang ]] && echo "${BB}${W} $lang ${R}"
                echo "${D}${C}┌$(repeat_char ─ $((WIDTH-2)))┐${R}"
            else
                echo "${D}${C}└$(repeat_char ─ $((WIDTH-2)))┘${R}"
                in_code=0
            fi
            continue
        fi
        
        if ((in_code == 1)); then
            code_num=$((code_num + 1))
            local num=$(printf "%3d" $code_num)
            if [[ $line =~ ^[[:space:]]*# ]] || [[ $line =~ ^[[:space:]]*// ]]; then
                echo "${D}${C}${num}${R} ${D}${C}│${R} ${GR}${line}${R}"
            else
                echo "${D}${C}${num}${R} ${D}${C}│${R} ${G}${line}${R}"
            fi
            prev_empty=0
            continue
        fi
        
        if [[ -z $line ]]; then
            ((prev_empty == 0)) && echo ""
            prev_empty=1
            continue
        fi
        prev_empty=0
        
        # HTML details/summary tags
        if [[ $line =~ ^[[:space:]]*\<details\> ]]; then
            echo "${D}${C}▼ Details${R}"
            continue
        fi
        
        # Summary with content on same line
        if [[ $line =~ ^[[:space:]]*\<summary\>(.+)\</summary\> ]]; then
            echo "  ${B}${C}${BASH_REMATCH[1]}${R}"
            continue
        fi
        
        # Summary opening tag (content on next line)
        if [[ $line =~ ^[[:space:]]*\<summary\>(.*)$ ]]; then
            local content="${BASH_REMATCH[1]}"
            if [[ -n $content ]]; then
                echo "  ${B}${C}${content}${R}"
            fi
            continue
        fi
        
        # Summary closing tag
        if [[ $line =~ ^[[:space:]]*(.+)\</summary\>$ ]] || [[ $line =~ ^[[:space:]]*\</summary\>$ ]]; then
            local content="${BASH_REMATCH[1]}"
            if [[ -n $content ]]; then
                echo "  ${B}${C}${content}${R}"
            fi
            continue
        fi
        
        if [[ $line =~ ^[[:space:]]*\</details\> ]]; then
            continue
        fi
        
        # Strip paragraph and other HTML tags
        if [[ $line =~ ^[[:space:]]*\<p[[:space:]].*\>$ ]] || [[ $line =~ ^[[:space:]]*\</p\>$ ]]; then
            continue
        fi
        
        # Strip other HTML tags but keep content
        if [[ $line =~ ^[[:space:]]*\</?[a-z]+.*\>$ ]]; then
            continue
        fi
        
        # Footnote references: [^1]: text
        if [[ $line =~ ^\[\^([0-9]+)\]:[[:space:]](.+)$ ]]; then
            echo "${M}[${BASH_REMATCH[1]}]${R} ${D}$(inline "${BASH_REMATCH[2]}")${R}"
            continue
        fi
        
        # Headers: # through ######
        if [[ $line =~ ^(#{1,6})[[:space:]](.+)$ ]]; then
            local lvl=${#BASH_REMATCH[1]} txt="${BASH_REMATCH[2]}"
            echo ""
            case $lvl in
                1) echo "${B}${C}$(repeat_char ═ $WIDTH)${R}"
                   echo "${B}${RED}$txt${R}"
                   echo "${B}${C}$(repeat_char ═ $WIDTH)${R}" ;;
                2) echo "${B}${C}$txt${R}"
                   echo "${C}$(repeat_char ━ ${#txt})${R}" ;;
                3) echo "${B}${M}$txt${R}" ;;
                4) echo "${B}${O}▸ $txt${R}" ;;
                5) echo "${G}● $txt${R}" ;;
                6) echo "${D}${C}○ $txt${R}" ;;
            esac
            continue
        fi
        
        # Horizontal rule: --- or *** or ___
        [[ $line =~ ^[*_-]{3,}$ ]] && { echo "${D}${C}$(repeat_char ─ $WIDTH)${R}"; continue; }
        
        # Admonitions: !!! type "title" or ??? type "title"
        if [[ $line =~ ^(\?\?\?|!!![!]*)[[:space:]]+([a-z]+)([[:space:]]+\"([^\"]+)\")? ]]; then
            local marker="${BASH_REMATCH[1]}" type="${BASH_REMATCH[2]}" title="${BASH_REMATCH[4]}"
            [[ -z $title ]] && title="$type"
            local icon="ⓘ" color="$C"
            case "$type" in
                danger|error) icon="⚠" color="$RED" ;;
                warning) icon="⚡" color="$O" ;;
                success|tip) icon="✓" color="$G" ;;
                info|note) icon="ⓘ" color="$BL" ;;
            esac
            echo "${B}${color}${icon} ${title}${R}"
            continue
        fi
        
        # Blockquote: > text
        if [[ $line =~ ^\>[[:space:]]?(.*)$ ]]; then
            echo "${O}┃${R} ${I}${O}$(inline "${BASH_REMATCH[1]}")${R}"
            continue
        fi
        
        # Task list: - [ ] or - [x]
        if [[ $line =~ ^[[:space:]]*[-*][[:space:]]\[([[:space:]xX])\][[:space:]](.+)$ ]]; then
            local chk="${BASH_REMATCH[1]}" txt="${BASH_REMATCH[2]}"
            if [[ $chk =~ [xX] ]]; then
                echo "  ${G}✓${R} ${D}$(inline "$txt")${R}"
            else
                echo "  ${BL}○${R} $(inline "$txt")"
            fi
            continue
        fi
        
        # Ordered list: 1. item
        if [[ $line =~ ^([[:space:]]*)(([0-9]+)\.)[[:space:]](.+)$ ]]; then
            local ind="${BASH_REMATCH[1]}" num="${BASH_REMATCH[3]}" txt="${BASH_REMATCH[4]}"
            echo "${ind}${C}${num}.${R} $(inline "$txt")"
            continue
        fi
        
        # Unordered list: - item or * item
        if [[ $line =~ ^([[:space:]]*)[-*+][[:space:]](.+)$ ]]; then
            local ind="${BASH_REMATCH[1]}" txt="${BASH_REMATCH[2]}"
            local bullet="●"
            case $(( (${#ind} / 2) % 3 )) in
                1) bullet="○" ;;
                2) bullet="▪" ;;
            esac
            echo "${ind}${C}${bullet}${R} $(inline "$txt")"
            continue
        fi
        
        # Tables: | col | col |  (buffered so columns can be padded)
        if [[ $line =~ ^\|.*\|$ ]]; then
            table_lines=("$line")
            while IFS= read -r line; do
                if [[ $line =~ ^\|.*\|$ ]]; then
                    table_lines+=("$line")
                else
                    pending="$line"
                    pending_set=1
                    break
                fi
            done
            render_box_table "${table_lines[@]}"
            continue
        fi
        
        inline "$line"
    done < "$input"
}

help() {
    cat << 'EOF'
BUSYMD - Markdown Viewer for Busybox and Beyond

USAGE:
    busymd FILE.md          View markdown file with pager
    busymd --no-pager FILE  Direct output without pager
    cat FILE | busymd       Read from stdin

NAVIGATION (in less):
    g / G         Go to beginning / end of file
    j / k         Scroll down / up one line
    d / u         Scroll down / up half page
    f / b         Scroll down / up full page
    Space         Scroll down full page

SEARCH:
    /pattern      Search forward
    ?pattern      Search backward
    n / N         Next / previous match

OTHER:
    q             Quit
    h             Help

EOF
}

busymd() {
    local use_pager=1 input=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) help; return 0 ;;
            --no-pager) use_pager=0; shift ;;
            *) input="$1"; break ;;
        esac
    done
    
    [[ -z $input ]] && { [[ -p /dev/stdin ]] && input="/dev/stdin" || { help; return 0; }; }
    [[ -f $input ]] || [[ $input == /dev/stdin ]] || { echo "Error: File not found: $input" >&2; return 1; }
    
    if ((use_pager == 1)) && [[ -t 1 ]]; then
        # Use -I (uppercase) for BusyBox compatibility, omit -X as it's not supported everywhere
        render "$input" | less -R -F -I -M 2>/dev/null || render "$input" | less -R -F -M
    else
        render "$input"
    fi
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && busymd "$@"
