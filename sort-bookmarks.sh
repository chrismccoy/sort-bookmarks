#!/usr/bin/env bash

# Parses Chrome compatible Bookmarks JSON and outputs results in various formats.

set -euo pipefail

OS=$(uname -s)

BOOKMARKS_ENV_SET=false
if [[ -n "${BOOKMARKS:-}" ]]; then
  BOOKMARKS_ENV_SET=true
fi
BOOKMARKS="${BOOKMARKS:-}"

JQ_DEFS='
  def all_nodes:
    [.roots[] | recurse(.children?[]?)];

  def to_date:
    tonumber / 1e6 - 11644473600
    | strflocaltime("%B %d, %Y at %I:%M %p");

  def to_entry:
    { date: (.date_added | to_date), title: .name, url: .url };

  def traverse(path):
    if .type == "url" then
      { folder: path, name: .name, url: .url, date_added: .date_added }
    else
      . as $node
      | (.children[]? | traverse(
          if path == "" then $node.name
          else "\(path)/\($node.name)"
          end
        ))
    end;

  def filter_folder(f; exact):
    if f == "" then .
    elif exact then [.[] | select(.folder == f)]
    else [.[] | select(.folder | ascii_downcase | contains(f | ascii_downcase))]
    end;

  def filter_search(s):
    if s == "" then .
    else [.[] | select(
      (.name | ascii_downcase | contains(s | ascii_downcase))
      or (.url  | ascii_downcase | contains(s | ascii_downcase))
    )]
    end;

  def filter_since(ts):
    if ts == 0 then .
    else [.[] | select((.date_added | tonumber) >= ts)]
    end;

  def filter_before(ts):
    if ts == 0 then .
    else [.[] | select((.date_added | tonumber) <= ts)]
    end;

  def sort_entries(field):
    if field == "title" then sort_by(.name | ascii_downcase)
    elif field == "url"  then sort_by(.url  | ascii_downcase)
    else sort_by(.date_added | tonumber)
    end;

  def apply_limit(n):
    if n > 0 then .[0:n] else . end;
'

die() {
  echo "Error: $*" >&2
  exit 1
}

date_to_chrome_ts() {
  local date_str="$1"
  local unix_ts=""
  case "$OS" in
    Darwin) unix_ts=$(date -j -f "%Y-%m-%d" "$date_str" "+%s" 2>/dev/null) ;;
    Linux)  unix_ts=$(date -d "$date_str" "+%s" 2>/dev/null) ;;
    *)      die "Date conversion not supported on OS '${OS}'. Cannot use --since/--before." ;;
  esac
  [[ -z "$unix_ts" ]] && die "Invalid date '${date_str}' — use YYYY-MM-DD format"
  echo $(( (unix_ts + 11644473600) * 1000000 ))
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  urls          List unique URLs, sorted alphabetically (default: z-a)
  json          JSON objects with date, title, url (default: newest first)
  dated         Text output: date, name, url (default: newest first)
  folders       Text output: folder path, name, url (default: z-a)
  dupes         Show duplicate URLs with all bookmark entries grouped
  stats         Summary statistics about the bookmark collection
  check         Check each URL for HTTP reachability using curl

Options:
  --asc                 Sort ascending (oldest first / a-z)
  --sort-by <field>     Sort field: date (default), title, url
                        For folders: also supports folder (default)
                        For dupes: also supports count (default) and url
  --browser <name>      Browser profile to use: chrome, brave, edge, chromium
  --profile <n>         Profile number (0=Default, 1=Profile 1, 2=Profile 2, ...)
  --folder <name>       Filter to bookmarks in folders matching this name
  --folder-exact        Require an exact folder name match (case-sensitive)
  --search <term>       Filter by title or URL substring (case-insensitive)
  --since <YYYY-MM-DD>  Only include bookmarks added on or after this date
  --before <YYYY-MM-DD> Only include bookmarks added on or before this date
  --limit <n>           Cap output to N results (N groups for dupes; N top folders for stats)
  --tsv                 Tab-separated, one record per line (all commands)
  --json                JSON object output (stats only)
  --color               Force color output even when not in a terminal
  --no-color            Disable color output
  -h, --help            Show this help message

Environment:
  BOOKMARKS     Override the bookmarks file path directly (bypasses --browser)
  NO_COLOR      Set to any value to disable colors (https://no-color.org/)

Notes:
  - json --tsv and dated --tsv produce identical output (both: date, title, url)
  - urls ignores --sort-by (URLs are always sorted alphabetically after dedup)
  - check command requires curl; use --limit to avoid checking thousands of URLs

Examples:
  $(basename "$0") urls
  $(basename "$0") json
  $(basename "$0") dated
  $(basename "$0") folders --asc --tsv
  $(basename "$0") dupes
  $(basename "$0") stats
  $(basename "$0") check --limit 50
  BOOKMARKS=/path/to/Bookmarks $(basename "$0") urls
EOF
}

CMD=""
ASC=false
TSV=false
JSON_OUTPUT=false
BROWSER=""
PROFILE_NUM=""
FOLDER=""
FOLDER_EXACT=false
SEARCH=""
LIMIT=0
SORT_BY="date"
SINCE_DATE=""
BEFORE_DATE=""
COLOR_FORCED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage; exit 0
      ;;
    --asc)
      ASC=true; shift
      ;;
    --tsv)
      TSV=true; shift
      ;;
    --json)
      JSON_OUTPUT=true; shift
      ;;
    --color)
      COLOR_FORCED=true; shift
      ;;
    --no-color)
      COLOR_FORCED=false; shift
      ;;
    --browser)
      [[ -z "${2:-}" ]] && die "--browser requires a name (chrome, brave, edge, chromium)"
      BROWSER="$2"; shift 2
      ;;
    --profile)
      [[ -z "${2:-}" ]] && die "--profile requires a number (0=Default, 1=Profile 1, ...)"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--profile must be a non-negative integer"
      PROFILE_NUM="$2"; shift 2
      ;;
    --folder)
      [[ -z "${2:-}" ]] && die "--folder requires a folder name"
      FOLDER="$2"; shift 2
      ;;
    --folder-exact)
      FOLDER_EXACT=true; shift
      ;;
    --search)
      [[ -z "${2:-}" ]] && die "--search requires a search term"
      SEARCH="$2"; shift 2
      ;;
    --sort-by)
      [[ -z "${2:-}" ]] && die "--sort-by requires a field: date, title, url, folder, count"
      case "${2}" in
        date|title|url|folder|count) SORT_BY="$2" ;;
        *) die "--sort-by must be one of: date, title, url (+ folder for folders; count for dupes)" ;;
      esac
      shift 2
      ;;
    --since)
      [[ -z "${2:-}" ]] && die "--since requires a date (YYYY-MM-DD)"
      SINCE_DATE="$2"; shift 2
      ;;
    --before)
      [[ -z "${2:-}" ]] && die "--before requires a date (YYYY-MM-DD)"
      BEFORE_DATE="$2"; shift 2
      ;;
    --limit)
      [[ -z "${2:-}" ]] && die "--limit requires a number"
      [[ "$2" =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"
      LIMIT="$2"; shift 2
      ;;
    -*)
      die "Unknown option '$1' — run with --help for usage"
      ;;
    *)
      [[ -n "$CMD" ]] && die "Unexpected argument '$1' — only one command allowed"
      CMD="$1"; shift
      ;;
  esac
done

if [[ -z "$CMD" ]]; then
  usage; exit 0
fi

if [[ -z "$PROFILE_NUM" || "$PROFILE_NUM" == "0" ]]; then
  PROFILE_DIR="Default"
else
  PROFILE_DIR="Profile ${PROFILE_NUM}"
fi

if [[ -n "$PROFILE_NUM" && -z "$BROWSER" ]]; then
  echo "Note: --profile without --browser targets Chrome '${PROFILE_DIR}'" >&2
fi

SINCE_TS=0
BEFORE_TS=0

if [[ -n "$SINCE_DATE" ]]; then
  SINCE_TS=$(date_to_chrome_ts "$SINCE_DATE")
fi
if [[ -n "$BEFORE_DATE" ]]; then
  BEFORE_TS=$(date_to_chrome_ts "$BEFORE_DATE")
fi

if [[ "$SINCE_TS" -gt 0 && "$BEFORE_TS" -gt 0 && "$SINCE_TS" -gt "$BEFORE_TS" ]]; then
  die "--since (${SINCE_DATE}) must not be later than --before (${BEFORE_DATE})"
fi

resolve_browser_path() {
  local browser="$1" profile="$2"
  local browser_lc
  browser_lc=$(echo "$browser" | tr '[:upper:]' '[:lower:]')

  case "$OS" in
    Darwin)
      case "$browser_lc" in
        chrome)   echo "${HOME}/Library/Application Support/Google/Chrome/${profile}/Bookmarks" ;;
        brave)    echo "${HOME}/Library/Application Support/BraveSoftware/Brave-Browser/${profile}/Bookmarks" ;;
        edge)     echo "${HOME}/Library/Application Support/Microsoft Edge/${profile}/Bookmarks" ;;
        chromium) echo "${HOME}/Library/Application Support/Chromium/${profile}/Bookmarks" ;;
        *) echo "Unknown browser '${browser}'. Known: chrome, brave, edge, chromium" >&2; return 1 ;;
      esac
      ;;
    Linux)
      local cfg="${XDG_CONFIG_HOME:-${HOME}/.config}"
      case "$browser_lc" in
        chrome)   echo "${cfg}/google-chrome/${profile}/Bookmarks" ;;
        brave)    echo "${cfg}/BraveSoftware/Brave-Browser/${profile}/Bookmarks" ;;
        edge)     echo "${cfg}/microsoft-edge/${profile}/Bookmarks" ;;
        chromium) echo "${cfg}/chromium/${profile}/Bookmarks" ;;
        *) echo "Unknown browser '${browser}'. Known: chrome, brave, edge, chromium" >&2; return 1 ;;
      esac
      ;;
    *)
      echo "Unsupported OS '${OS}'. Set BOOKMARKS=/path/to/Bookmarks manually." >&2
      return 1
      ;;
  esac
}

if [[ -n "$BROWSER" ]]; then
  [[ "$BOOKMARKS_ENV_SET" == true ]] && \
    echo "Warning: --browser overrides the BOOKMARKS environment variable" >&2
  BOOKMARKS=$(resolve_browser_path "$BROWSER" "$PROFILE_DIR") || exit 1
elif [[ -z "$BOOKMARKS" ]]; then
  BOOKMARKS=$(resolve_browser_path "chrome" "$PROFILE_DIR") || exit 1
fi

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  COLOR=true
else
  COLOR=false
fi
[[ -n "$COLOR_FORCED" ]] && COLOR="$COLOR_FORCED"

[[ "$TSV" == true ]] && COLOR=false

if [[ "$COLOR" == true ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_URL=$'\033[0;34m'
  C_FOLDER=$'\033[0;32m'
  C_DATE=$'\033[0;90m'
  C_COUNT=$'\033[1;33m'
  C_OK=$'\033[0;32m'
  C_WARN=$'\033[0;33m'
  C_ERROR=$'\033[0;31m'
else
  C_RESET="" C_BOLD="" C_URL="" C_FOLDER="" C_DATE=""
  C_COUNT="" C_OK="" C_WARN="" C_ERROR=""
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  case "$OS" in
    Darwin) echo "Install via: brew install jq" >&2 ;;
    Linux)  echo "Install via: sudo apt install jq  OR  sudo dnf install jq" >&2 ;;
  esac
  exit 1
fi

JQ_VERSION=$(jq --version 2>&1 | sed 's/jq-//')
JQ_MAJOR=$(echo "$JQ_VERSION" | cut -d. -f1)
JQ_MINOR=$(echo "$JQ_VERSION" | cut -d. -f2 | tr -cd '0-9')
if [[ "$JQ_MAJOR" -lt 1 ]] || { [[ "$JQ_MAJOR" -eq 1 ]] && [[ "$JQ_MINOR" -lt 6 ]]; }; then
  echo "Error: jq 1.6 or newer is required (found jq-${JQ_VERSION})" >&2
  case "$OS" in
    Darwin) echo "Upgrade via: brew install jq" >&2 ;;
    Linux)  echo "Upgrade via your package manager or https://stedolan.github.io/jq/" >&2 ;;
  esac
  exit 1
fi

if [[ ! -f "$BOOKMARKS" ]]; then
  echo "Error: Bookmarks file not found at: $BOOKMARKS" >&2
  if [[ -n "$BROWSER" ]]; then
    echo "Is '${BROWSER}' installed, and has profile '${PROFILE_DIR}' been created?" >&2
  else
    echo "Override with: BOOKMARKS=/path/to/Bookmarks $(basename "$0")" >&2
  fi
  exit 1
fi

if ! jq empty "$BOOKMARKS" 2>/dev/null; then
  echo "Error: Bookmarks file is not valid JSON: $BOOKMARKS" >&2
  echo "The browser may be writing to it. Close the browser or try again." >&2
  exit 1
fi

if [[ "$ASC" == true ]]; then
  SORT_EXPR=""
else
  SORT_EXPR="| reverse"
fi

FOLDER_EXACT_JSON=$([ "$FOLDER_EXACT" == true ] && echo "true" || echo "false")

JQ_ARGS=(
  --arg    folder        "$FOLDER"
  --argjson folder_exact "$FOLDER_EXACT_JSON"
  --arg    search        "$SEARCH"
  --arg    sort_by       "$SORT_BY"
  --argjson since_ts     "$SINCE_TS"
  --argjson before_ts    "$BEFORE_TS"
  --argjson limit        "$LIMIT"
  --arg    c_reset       "$C_RESET"
  --arg    c_bold        "$C_BOLD"
  --arg    c_url         "$C_URL"
  --arg    c_folder      "$C_FOLDER"
  --arg    c_date        "$C_DATE"
  --arg    c_count       "$C_COUNT"
)

case "$CMD" in

  urls)
    jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
      [.roots[] | traverse("")]
      | filter_folder($folder; $folder_exact)
      | filter_search($search)
      | filter_since($since_ts)
      | filter_before($before_ts)
      | [.[].url] | unique
      '"${SORT_EXPR}"'
      | apply_limit($limit)
      | .[]
      | "\($c_url)\(.)\($c_reset)"
    ' "$BOOKMARKS"
    ;;

  json)
    if [[ "$TSV" == true ]]; then
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | sort_entries($sort_by)
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[] | to_entry
        | [.date, .title, .url] | @tsv
      ' "$BOOKMARKS"
    else
      jq "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | sort_entries($sort_by)
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[] | to_entry
      ' "$BOOKMARKS"
    fi
    ;;

  dated)
    if [[ "$TSV" == true ]]; then
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | sort_entries($sort_by)
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[] | to_entry
        | [.date, .title, .url] | @tsv
      ' "$BOOKMARKS"
    else
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | sort_entries($sort_by)
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[] | to_entry
        | "\($c_date)\(.date)\($c_reset)\n\(.title)\n\($c_url)\(.url)\($c_reset)\n"
      ' "$BOOKMARKS"
    fi
    ;;

  folders)
    if [[ "$SORT_BY" == "date" || "$SORT_BY" == "folder" ]]; then
      FOLDER_SORT_JQ='sort_by([(.folder | ascii_downcase), (.name | ascii_downcase)])'
    else
      FOLDER_SORT_JQ="sort_entries(\$sort_by)"
    fi

    if [[ "$TSV" == true ]]; then
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | '"${FOLDER_SORT_JQ}"'
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[]
        | [.folder, .name, .url] | @tsv
      ' "$BOOKMARKS"
    else
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | '"${FOLDER_SORT_JQ}"'
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[]
        | "\($c_folder)\(.folder)\($c_reset)\n\n\(.name)\n\n\($c_url)\(.url)\($c_reset)\n"
      ' "$BOOKMARKS"
    fi
    ;;

  dupes)
    case "$SORT_BY" in
      url) DUPE_SORT='sort_by(.url | ascii_downcase)' ;;
      *)   DUPE_SORT='sort_by(.count)' ;;
    esac

    _dupes=$(jq -c "${JQ_ARGS[@]}" "${JQ_DEFS}"'
      [.roots[] | traverse("")]
      | filter_folder($folder; $folder_exact)
      | filter_search($search)
      | filter_since($since_ts)
      | filter_before($before_ts)
      | group_by(.url)
      | map(select(length > 1))
      | map({
          url:   .[0].url,
          count: length,
          bookmarks: (
            sort_by(.date_added | tonumber)
            | map({ title: .name, date: (.date_added | to_date), folder: .folder })
          )
        })
    ' "$BOOKMARKS")

    if [[ "$TSV" == true ]]; then
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        '"${DUPE_SORT}"'
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[]
        | .url as $url | .count as $count
        | .bookmarks[]
        | [$url, ($count | tostring), .folder, .date, .title] | @tsv
      ' <<<"$_dupes"
    else
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        '"${DUPE_SORT}"'
        '"${SORT_EXPR}"'
        | apply_limit($limit)
        | .[]
        | "\($c_count)[\(.count) copies]\($c_reset) \($c_url)\(.url)\($c_reset)",
          (.bookmarks[] | "  \($c_folder)\(.folder)\($c_reset)  |  \($c_date)\(.date)\($c_reset)  |  \(.title)"),
          ""
      ' <<<"$_dupes"

      jq -r '"---\n\(length) duplicate URLs · \([.[].count - 1] | add // 0) redundant entries"' \
        <<<"$_dupes" >&2
    fi
    ;;

  stats)
    if [[ "$JSON_OUTPUT" == true && "$TSV" == true ]]; then
      die "stats: --json and --tsv cannot be combined"
    fi
    if [[ "$TSV" == true ]]; then
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        . as $root
        | ([$root.roots[] | traverse("")] | filter_folder($folder; $folder_exact) | filter_search($search) | filter_since($since_ts) | filter_before($before_ts)) as $entries
        | if ($entries | length) == 0 then
            "no_bookmarks_found\t1"
          else
            ($entries | sort_by(.date_added | tonumber)) as $sorted |
            ($entries | group_by(.folder) | map({ folder: .[0].folder, count: length }) | sort_by(.count) | reverse | if $limit > 0 then .[0:$limit] else .[0:5] end) as $top |
            "total_bookmarks\t\($entries | length)",
            "unique_urls\t\($entries | map(.url) | unique | length)",
            "duplicate_urls\t\(($entries | map(.url) | length) - ($entries | map(.url) | unique | length))",
            "unique_folders\t\($entries | map(.folder) | unique | length)",
            "oldest_date\t\($sorted | first | .date_added | to_date)",
            "oldest_title\t\($sorted | first | .name)",
            "newest_date\t\($sorted | last | .date_added | to_date)",
            "newest_title\t\($sorted | last | .name)",
            ($top[] | "top_folder\t\(.folder)\t\(.count)")
          end
      ' "$BOOKMARKS"
    elif [[ "$JSON_OUTPUT" == true ]]; then
      jq "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        . as $root
        | ([$root.roots[] | traverse("")] | filter_folder($folder; $folder_exact) | filter_search($search) | filter_since($since_ts) | filter_before($before_ts)) as $entries
        | if ($entries | length) == 0 then
            { error: ("No bookmarks found" +
                if $folder != "" and $search != "" then
                  " matching folder \"\($folder)\" and search \"\($search)\""
                elif $folder != "" then " in folder \"\($folder)\""
                elif $search != "" then " matching \"\($search)\""
                else "" end) }
          else
            ($entries | sort_by(.date_added | tonumber)) as $sorted |
            {
              total_bookmarks: ($entries | length),
              unique_urls:     ($entries | map(.url) | unique | length),
              duplicate_urls:  (($entries | map(.url) | length) - ($entries | map(.url) | unique | length)),
              unique_folders:  ($entries | map(.folder) | unique | length),
              oldest: ($sorted | first | { title: .name, date: (.date_added | to_date) }),
              newest: ($sorted | last  | { title: .name, date: (.date_added | to_date) }),
              top_folders_by_count: (
                $entries
                | group_by(.folder)
                | map({ folder: .[0].folder, count: length })
                | sort_by(.count) | reverse
                | if $limit > 0 then .[0:$limit] else .[0:5] end
              )
            }
          end
      ' "$BOOKMARKS"
    else
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        . as $root
        | ([$root.roots[] | traverse("")] | filter_folder($folder; $folder_exact) | filter_search($search) | filter_since($since_ts) | filter_before($before_ts)) as $entries
        | if ($entries | length) == 0 then
            "No bookmarks found" +
              if $folder != "" and $search != "" then
                " matching folder \"\($folder)\" and search \"\($search)\""
              elif $folder != "" then " in folder \"\($folder)\""
              elif $search != "" then " matching \"\($search)\""
              else "" end
          else
            ($entries | sort_by(.date_added | tonumber)) as $sorted |
            ($entries | group_by(.folder) | map({ folder: .[0].folder, count: length }) | sort_by(.count) | reverse | if $limit > 0 then .[0:$limit] else .[0:5] end) as $top |
            "\($c_bold)Bookmarks\($c_reset)      \($c_count)\($entries | length)\($c_reset)",
            "\($c_bold)Unique URLs\($c_reset)    \($c_count)\($entries | map(.url) | unique | length)\($c_reset)  (\(($entries | map(.url) | length) - ($entries | map(.url) | unique | length)) duplicates)",
            "\($c_bold)Folders\($c_reset)        \($c_count)\($entries | map(.folder) | unique | length)\($c_reset)",
            "",
            "\($c_bold)Oldest\($c_reset)  \($c_date)\($sorted | first | .date_added | to_date)\($c_reset)  \($sorted | first | .name)",
            "\($c_bold)Newest\($c_reset)  \($c_date)\($sorted | last  | .date_added | to_date)\($c_reset)  \($sorted | last  | .name)",
            "",
            "\($c_bold)Top Folders\($c_reset)",
            ($top | to_entries[] | "  \($c_folder)\(.value.folder)\($c_reset)  \($c_count)\(.value.count)\($c_reset)")
          end
      ' "$BOOKMARKS"
    fi
    ;;

  check)
    if ! command -v curl &>/dev/null; then
      die "check requires curl — install via: brew install curl"
    fi

    CHECKED=0
    FAILED=0
    REDIRECTED=0
    ERRORS=0

    while IFS= read -r url; do
      [[ -z "$url" ]] && continue

      http_code=$(curl \
        --silent \
        --head \
        --max-time 10 \
        --output /dev/null \
        --write-out "%{http_code}" \
        -- "$url" 2>/dev/null) || http_code="000"

      CHECKED=$(( CHECKED + 1 ))

      if [[ "$TSV" == true ]]; then
        printf "%s\t%s\n" "$http_code" "$url"
      else
        case "$http_code" in
          2??) printf "%sOK   %s %s  %s%s%s\n" "$C_OK"    "$C_RESET" "$http_code" "$C_URL"   "$url" "$C_RESET"
               ;;
          3??) printf "%sREDIR%s %s  %s%s%s\n" "$C_WARN"  "$C_RESET" "$http_code" "$C_URL"   "$url" "$C_RESET"
               REDIRECTED=$(( REDIRECTED + 1 ))
               ;;
          4??|5??)
               printf "%sFAIL %s %s  %s\n"     "$C_ERROR" "$C_RESET" "$http_code" "$url"
               FAILED=$(( FAILED + 1 ))
               ;;
          *)   printf "%sERR  %s        %s\n"  "$C_ERROR" "$C_RESET" "$url"
               ERRORS=$(( ERRORS + 1 ))
               ;;
        esac
      fi

    done < <(
      jq -r "${JQ_ARGS[@]}" "${JQ_DEFS}"'
        [.roots[] | traverse("")]
        | filter_folder($folder; $folder_exact)
        | filter_search($search)
        | filter_since($since_ts)
        | filter_before($before_ts)
        | [.[].url] | unique
        | apply_limit($limit)
        | .[]
      ' "$BOOKMARKS"
    )

    if [[ "$TSV" != true ]]; then
      printf "---\n%s checked · %s unreachable · %s redirected · %s errors\n" \
        "$CHECKED" "$FAILED" "$REDIRECTED" "$ERRORS" >&2
    fi
    ;;

  *)
    echo "Error: Unknown command '${CMD}'" >&2
    usage >&2
    exit 1
    ;;

esac
