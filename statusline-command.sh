#!/usr/bin/env bash
input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')

# Effort level: Claude Code exports the effective effort for the current turn
# as $CLAUDE_EFFORT (post any silent downgrade). Fall back to settings.json.
file_effort=$(jq -r '.effortLevel // empty' /Users/chanwutk/.claude/settings.json 2>/dev/null)
label=${CLAUDE_EFFORT:-${file_effort:-unknown}}

# PS1-style prompt: user@host:cwd (mirrors ~/.config/rc.sh __prompt_command, without ANSI codes)
ps1_user=$(whoami)
ps1_host=$(hostname -s)
ps1_cwd=$(echo "$input" | jq -r '.workspace.current_dir')
# Abbreviate $HOME to ~
ps1_cwd="${ps1_cwd/#$HOME/\~}"

# Truncate every path component except the last (current) directory to its
# first 2 characters. "~" is left untouched, and a leading "/" is preserved.
abbrev_cwd() {
  local path="$1" prefix="" parts part out=() i n

  if [ "${path:0:1}" = "/" ]; then
    prefix="/"
    path="${path:1}"
  fi

  IFS='/' read -r -a parts <<< "$path"
  n=${#parts[@]}
  for (( i = 0; i < n; i++ )); do
    part="${parts[$i]}"
    if [ "$i" -lt $(( n - 1 )) ] && [ "$part" != "~" ]; then
      out+=("${part:0:2}")
    else
      out+=("$part")
    fi
  done

  local joined
  joined=$(IFS=/; echo "${out[*]}")
  printf '%s%s' "$prefix" "$joined"
}
ps1_cwd=$(abbrev_cwd "$ps1_cwd")

# ps1_prompt="${ps1_user}@${ps1_host}:${ps1_cwd}"
ps1_prompt="${ps1_cwd}"

# Terminal width (Claude Code exports COLUMNS to the statusline command)
cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 100)}
usable=$(( cols - 1 ))
now=$(date +%s)

# ANSI colors
C_RESET=$'\033[0m'
C_DIM=$'\033[2m'
C_CWD=$'\033[1;36m'      # bold cyan
C_MODEL=$'\033[1;32m'    # bold green
case "$label" in
  low)       C_EFFORT=$'\033[1;38;5;46m'  ; label_disp=L    ;;  # bold green
  medium)    C_EFFORT=$'\033[1;38;5;226m' ; label_disp=M    ;;  # bold yellow
  high)      C_EFFORT=$'\033[1;38;5;208m' ; label_disp=H    ;;  # bold orange
  xhigh)     C_EFFORT=$'\033[1;38;5;196m' ; label_disp=X    ;;  # bold red
  max)       C_EFFORT=$'\033[1;38;5;93m'  ; label_disp=MAX  ;;  # bold purple
  ultracode) C_EFFORT=$'\033[1;38;5;201m'; label_disp=$label;;  # bold bright magenta (beyond max)
  auto)      C_EFFORT=$'\033[1;36m'       ; label_disp=$label;;  # bold cyan
  *)         C_EFFORT=$'\033[1;30m'       ; label_disp=$label;;  # bold gray (unknown)
esac
C_TARGET=$'\033[1;34m'   # bold blue
C_BARBACK=$'\033[38;5;238m'  # rich's bar.back grey
C_MARKER=$'\033[1;97m'       # bright white time marker
C_CORNER=$'\033[1m'      # bold
SEP="${C_CORNER} ┏ ${C_RESET}"
SEP2="${C_CORNER} ┗ ${C_RESET}"

# Color a remaining percentage (0=none left, 100=full) using d3's
# interpolateRdYlGn diverging scale on a sqrt input scale — i.e.
# d3.scaleSequentialSqrt(d3.interpolateRdYlGn).domain([0, 100]).
# interpolateRdYlGn is a uniform cubic B-spline (d3's "basis" interpolator)
# through the 11-class ColorBrewer RdYlGn stops; sqrt(x) is applied to the
# normalized input first so low-percentage values move off pure red faster.
left_color() {
  awk -v pct="$1" 'BEGIN {
    split("165 0 38|215 48 39|244 109 67|253 174 97|254 224 139|255 255 191|217 239 139|166 217 106|102 189 99|26 152 80|0 104 55", stops, "|")
    n = 11; nseg = n - 1
    x = pct / 100; if (x < 0) x = 0; if (x > 1) x = 1
    t = sqrt(x)
    if (t <= 0) { i = 0; tt = 0 }
    else if (t >= 1) { i = nseg - 1; tt = 1 }
    else { f = t * nseg; i = int(f); tt = f - i }

    split(stops[i + 1], v1, " ")
    split(stops[i + 2], v2, " ")
    if (i > 0) { split(stops[i], v0, " ") }
    else { v0[1] = 2*v1[1]-v2[1]; v0[2] = 2*v1[2]-v2[2]; v0[3] = 2*v1[3]-v2[3] }
    if (i < nseg - 1) { split(stops[i + 3], v3, " ") }
    else { v3[1] = 2*v2[1]-v1[1]; v3[2] = 2*v2[2]-v1[2]; v3[3] = 2*v2[3]-v1[3] }

    t2 = tt*tt; t3 = t2*tt
    b0 = 1 - 3*tt + 3*t2 - t3
    b1 = 4 - 6*t2 + 3*t3
    b2 = 1 + 3*tt + 3*t2 - 3*t3
    b3 = t3
    for (k = 1; k <= 3; k++) {
      c[k] = (b0*v0[k] + b1*v1[k] + b2*v2[k] + b3*v3[k]) / 6
      if (c[k] < 0) c[k] = 0
      if (c[k] > 255) c[k] = 255
      c[k] = int(c[k] + 0.5)
    }
    printf "\033[1;38;2;%d;%d;%dm", c[1], c[2], c[3]
  }'
}

# rich-style progress bar: filled ━ (+ ╸ half-cell), remainder ╺━━ in grey,
# with up to two markers overlaid at given positions (each own color/char).
# usage: rich_bar <width> <fill pct 0-100> <fill color> \
#                  [marker1 pct] [marker1 color] [marker1 char] \
#                  [marker2 pct] [marker2 color] [marker2 char]
rich_bar() {
  local width=$1 pct=$2 fill=$3
  local m1=${4:--1} m1_color=${5:-$C_MARKER} m1_char=${6:-|}
  local m2=${7:--1} m2_color=${8:-$C_TARGET} m2_char=${9:-|}
  local halves=$(( (width * 2 * pct + 50) / 100 ))
  [ "$halves" -gt $(( width * 2 )) ] && halves=$(( width * 2 ))
  [ "$halves" -lt 0 ] && halves=0
  local full=$(( halves / 2 )) half=$(( halves % 2 ))
  local m1pos=-1 m2pos=-1
  if [ "$m1" -ge 0 ]; then
    m1pos=$(( ((width - 1) * m1 + 50) / 100 ))
    [ "$m1pos" -ge "$width" ] && m1pos=$(( width - 1 ))
  fi
  if [ "$m2" -ge 0 ]; then
    m2pos=$(( ((width - 1) * m2 + 50) / 100 ))
    [ "$m2pos" -ge "$width" ] && m2pos=$(( width - 1 ))
    # avoid stacking exactly on top of marker 1
    [ "$m2pos" -eq "$m1pos" ] && m2pos=$(( m2pos + 1 < width ? m2pos + 1 : m2pos - 1 ))
  fi
  local out="" i
  for (( i = 0; i < width; i++ )); do
    if [ "$i" -eq "$m1pos" ]; then
      out+="${m1_color}${m1_char}"
    elif [ "$i" -eq "$m2pos" ]; then
      out+="${m2_color}${m2_char}"
    elif [ "$i" -lt "$full" ]; then
      out+="${fill}━"
    elif [ "$i" -eq "$full" ] && [ "$half" -eq 1 ]; then
      out+="${fill}╸"
    elif [ "$i" -eq $(( full + half )) ] && [ "$half" -eq 0 ]; then
      out+="${C_BARBACK}╺"
    else
      out+="${C_BARBACK}━"
    fi
  done
  out+="$C_RESET"
  printf '%s' "$out"
}

# Rate limits: weekly/5h remaining %, with time-left markers
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty | floor')
week_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty | floor')
five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

# --- token_prop: (5h token limit) / (weekly token limit) ---
# Not exposed by Claude Code, so we start from a default and refine it by
# observation: each time session usage rises by d5 points and weekly usage by
# dw points within the same 5h window, dw/d5 is a sample of token_prop.
# Accumulated sums live in a state file; the estimate kicks in once we have
# seen >= 25 session-percentage points of burn.
TOKEN_PROP_DEFAULT=0.1
STATE=/Users/chanwutk/.claude/cache/statusline-usage-state.json
sum_week=0; sum_five=0; last_week=-1; last_five=-1; last_reset=0
if [ -f "$STATE" ]; then
  IFS=$'\t' read -r sum_week sum_five last_week last_five last_reset < <(
    jq -r '[.sum_week//0, .sum_five//0, .last_week//-1, .last_five//-1, .last_reset//0] | @tsv' \
      "$STATE" 2>/dev/null) || { sum_week=0; sum_five=0; last_week=-1; last_five=-1; last_reset=0; }
fi
if [ -n "$five_pct" ] && [ -n "$week_pct" ] && [ -n "$five_reset" ]; then
  if [ "$five_reset" = "$last_reset" ] && [ "$last_five" -ge 0 ] \
     && [ "$five_pct" -ge "$last_five" ] && [ "$week_pct" -ge "$last_week" ]; then
    sum_five=$(( sum_five + five_pct - last_five ))
    sum_week=$(( sum_week + week_pct - last_week ))
  fi
  printf '{"sum_week":%d,"sum_five":%d,"last_week":%d,"last_five":%d,"last_reset":%s}\n' \
    "$sum_week" "$sum_five" "$week_pct" "$five_pct" "$five_reset" > "$STATE.tmp.$$" \
    && mv "$STATE.tmp.$$" "$STATE"
fi
if [ "$sum_five" -ge 25 ] && [ "$sum_week" -gt 0 ]; then
  token_prop=$(awk -v w="$sum_week" -v f="$sum_five" 'BEGIN{printf "%.4f", w/f}')
else
  token_prop=$TOKEN_PROP_DEFAULT
fi

# --- target = (sl - 1 + stl) * token_prop ---
# sl:  5h sessions left before week reset (current one + full windows after it)
# stl: fraction of the current 5h session still unused
# The result is the share of the weekly limit the remaining sessions could
# still consume at most — compare it against the weekly "left" number.
target=""
if [ -n "$five_pct" ] && [ -n "$five_reset" ] && [ -n "$week_reset" ]; then
  gap=$(( week_reset - five_reset ))
  [ "$gap" -lt 0 ] && gap=0
  sl=$(( 1 + gap / 18000 ))
  target=$(awk -v sl="$sl" -v fp="$five_pct" -v tp="$token_prop" \
    'BEGIN{t = (sl - 1 + (100 - fp) / 100) * tp * 100; if (t > 100) t = 100; printf "%d", t + 0.5}')
fi

# --- line 1: cwd | wk <bar: quota left, | = time left> left% ---
MIN_BAR=10

# Reserve room for the wk section's fixed chrome (" | wk " = 6) + a minimum
# bar, then truncate a too-long cwd path from the left so the whole line can
# never exceed the terminal.
reserve=6
avail_for_cwd=$(( usable - reserve - MIN_BAR ))
if [ "$avail_for_cwd" -lt 4 ]; then avail_for_cwd=4; fi
if [ "${#ps1_prompt}" -gt "$avail_for_cwd" ]; then
  keep=$(( avail_for_cwd - 1 ))
  [ "$keep" -lt 1 ] && keep=1
  ps1_prompt="…${ps1_prompt: -$keep}"
fi

plain1="${ps1_prompt}"
line1="${C_CWD}${ps1_prompt}${C_RESET}"
plain2_head="${model} ${label_disp}"
line2="${C_MODEL}${model}${C_RESET} ${C_EFFORT}${label_disp}${C_RESET}"

# Align the wk and 5h bars: both start at the same column, i.e. the longer
# of the two head texts plus their fixed chrome (" | wk " / " | 5h ", 6
# chars each), whichever line is shorter gets padded to match.
bar_start=$(( ${#plain1} + 6 ))    # " | wk " (6)
prefix2=$(( ${#plain2_head} + 6 )) # " | " (3) + "5h " (3)
if [ "$bar_start" -ge "$prefix2" ]; then
  common_start=$bar_start
else
  common_start=$prefix2
fi

if [ -n "$week_pct" ]; then
  week_left=$(( 100 - week_pct ))
  week_time_left=-1
  if [ -n "$week_reset" ]; then
    week_len=604800
    remain=$(( week_reset - now ))
    [ "$remain" -lt 0 ] && remain=0
    [ "$remain" -gt "$week_len" ] && remain=$week_len
    week_time_left=$(( remain * 100 / week_len ))
  fi
  pad1=""
  needed1=$(( common_start - bar_start ))
  if [ "$needed1" -gt 0 ]; then
    # Pad with U+2800 (braille blank): renders as empty space but is not
    # whitespace, so the renderer's leading-space trimming leaves it intact.
    for (( i = 0; i < needed1; i++ )); do pad1+=$'\342\240\200'; done
  fi
  # Stretch to only 95% of the remaining space, as a safety margin against
  # any residual terminal/font width discrepancy.
  bar_w=$(( (usable - common_start - 2) * 95 / 100 ))   # -2 reserves " ┐" trailer
  if [ "$bar_w" -ge 1 ]; then
    wk_color=$(left_color "$week_left")
    target_marker=${target:--1}
    line1+="${pad1}${SEP}${C_DIM}wk${C_RESET} $(rich_bar "$bar_w" "$week_left" "$wk_color" "$week_time_left" "$C_MARKER" "|" "$target_marker" "$C_TARGET" "|") ${C_CORNER}┓${C_RESET}"
  fi
fi

# --- line 2: model effort | 5h <bar: quota left, | = time left> left% ---
if [ -n "$five_pct" ]; then
  five_left=$(( 100 - five_pct ))
  five_time_left=-1
  if [ -n "$five_reset" ]; then
    remain=$(( five_reset - now ))
    [ "$remain" -lt 0 ] && remain=0
    [ "$remain" -gt 18000 ] && remain=18000
    five_time_left=$(( remain * 100 / 18000 ))
  fi
  suffix2=""

  # Stretch to only 95% of the remaining space, as a safety margin against
  # any residual terminal/font width discrepancy.
  bar_w2=$(( (usable - common_start - ${#suffix2} - 2) * 95 / 100 ))   # -2 reserves " ┘" trailer
  if [ "$bar_w2" -ge 1 ]; then
    pad2=""
    needed2=$(( common_start - prefix2 ))
    if [ "$needed2" -gt 0 ]; then
      for (( i = 0; i < needed2; i++ )); do pad2+=$'\342\240\200'; done
    fi
    five_color=$(left_color "$five_left")
    line2+="${pad2}${SEP2}${C_DIM}5h${C_RESET} $(rich_bar "$bar_w2" "$five_left" "$five_color" "$five_time_left") ${C_CORNER}┛${C_RESET}"
  fi
fi

printf '%s\n' "$line1"
[ -n "$line2" ] && printf '%s\n' "$line2"
exit 0
