#!/usr/bin/env bash
# Script: yt-dl.sh
# Purpose: Interactive or automatic download of video+audio with yt-dlp and merge to output.mp4
# Works on macOS Bash 3.2+. Requires: yt-dlp, ffmpeg.

set -u
IFS=$'\n\t'

# --------------------- CONFIG ---------------------
OUT_VIDEO="vtemp.mp4"
OUT_AUDIO="vtemp.m4a"
OUT_MERGED="output.mp4"

# Optional toggles via env or CLI (also exposed as switches below)
USE_COOKIES="${USE_COOKIES:-0}"        # 1 to try cookies strategy
COOKIE_BROWSER="${COOKIE_BROWSER:-chrome}"
FORCE_IPV4="${FORCE_IPV4:-0}"          # 1 to add -4
CUSTOM_UA="${CUSTOM_UA:-}"             # set to a UA string

# Parsed CLI options (defaults)
CLI_ID=""
CLI_AUTO=0

# --------------------- FLAG BUILD ---------------------
COMMON_FLAGS=()

supports_flag() {
  local f="$1"
  yt-dlp --help 2>/dev/null | grep -q -- "$f"
}

# Helpful flags (guarded by version support)
if supports_flag "--no-continue"; then COMMON_FLAGS+=("--no-continue"); fi
if supports_flag "--no-part"; then COMMON_FLAGS+=("--no-part"); fi
if supports_flag "--concurrent-fragments"; then COMMON_FLAGS+=("--concurrent-fragments" "8"); fi
if supports_flag "--no-playlist"; then COMMON_FLAGS+=("--no-playlist"); fi  # avoid RD... playlist confusion
COMMON_FLAGS+=("-i")  # ignore minor errors

if [ "$FORCE_IPV4" = "1" ]; then COMMON_FLAGS+=("-4"); fi
if [ -n "$CUSTOM_UA" ]; then COMMON_FLAGS+=("--user-agent" "$CUSTOM_UA"); fi

# Strategy 1: prefer yt-dlp native HLS (avoid ffmpeg fetching segments)
STRAT1_FLAGS=()
if supports_flag "--hls-prefer-native"; then STRAT1_FLAGS+=("--hls-prefer-native"); fi

# Strategy 2: Use Android client to prefer DASH/HTTPS (non-HLS)
STRAT2_FLAGS=()
if supports_flag "--extractor-args"; then STRAT2_FLAGS+=("--extractor-args" "youtube:player_client=android"); fi

# Strategy 3: Cookies (age/geo/session issues)
STRAT3_FLAGS=()
if [ "$USE_COOKIES" = "1" ] && supports_flag "--cookies-from-browser"; then
  STRAT3_FLAGS+=("--cookies-from-browser" "$COOKIE_BROWSER")
fi

# --------------------- HELPERS ---------------------
print_hr() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

usage() {
  cat <<EOF
Usage:
  $0                       # interactive (ask for IDs and formats)
  $0 --id=VIDEOID          # interactive formats, but use this ID for both video+audio
  $0 --auto --id=VIDEOID   # fully automatic best (no prompts)
  $0 --auto                # ask for ID, then automatic best
Options:
  --id=ID | --id ID        Use this ID/URL for both video and audio
  --auto                   Choose best quality automatically (no format prompts)
  --cookies                Enable cookie-based retry (same as USE_COOKIES=1)
  --ipv4                   Force IPv4 (-4)
  --ua=STRING              Custom User-Agent
Environment vars:
  USE_COOKIES=1 COOKIE_BROWSER=chrome|safari
  FORCE_IPV4=1
  CUSTOM_UA="..."
Examples:
  $0 --id=rVrIklMgR5s
  $0 --auto --id=rVrIklMgR5s
  USE_COOKIES=1 $0 --auto --id=rVrIklMgR5s
EOF
}

list_formats() {
  local ID="$1"
  echo
  print_hr
  echo "Available formats for: $ID"
  yt-dlp "${COMMON_FLAGS[@]}" "$ID" --list-formats || true
  print_hr
  echo
}

has_403_in_log() {
  local LOGFILE="$1"
  grep -qi "403" "$LOGFILE"
}

normalize_id() {
  # If it's an RD... Mix/playlist seed, strip RD to get underlying video id.
  local raw="$1"
  if [[ "$raw" == RD* ]] && [ ${#raw} -gt 2 ]; then
    echo "${raw#RD}"
  else
    echo "$raw"
  fi
}

download_one_try() {
  # Args: ID FMT OUTFILE [EXTRA_FLAGS...]
  local ID="$1"; shift
  local FMT="$1"; shift
  local OUT="$1"; shift

  # Avoid unbound arrays under set -u on Bash 3.2
  local EXTRA_FLAGS=()
  if [ "$#" -gt 0 ]; then
    EXTRA_FLAGS=( "$@" )
  fi

  rm -f "$OUT"
  local TMPLOG; TMPLOG="$(mktemp -t ytdlp_XXXX.log)"

  if [ "${#EXTRA_FLAGS[@]}" -gt 0 ]; then
    yt-dlp "${COMMON_FLAGS[@]}" "${EXTRA_FLAGS[@]}" -f "$FMT" "$ID" -o "$OUT" >"$TMPLOG" 2>&1
  else
    yt-dlp "${COMMON_FLAGS[@]}" -f "$FMT" "$ID" -o "$OUT" >"$TMPLOG" 2>&1
  fi
  local status=$?

  if [ $status -ne 0 ]; then
    # Build a safe flags string for logging (no unbound expansion)
    local MSG_FLAGS="(none)"
    if [ "${#EXTRA_FLAGS[@]}" -gt 0 ]; then MSG_FLAGS="${EXTRA_FLAGS[*]}"; fi
    echo "Download failed for format '$FMT' (ID: $ID) with flags: $MSG_FLAGS"
    if has_403_in_log "$TMPLOG"; then
      echo "Detected HTTP 403 in logs."
    fi
    echo "Log excerpt:"
    tail -n 12 "$TMPLOG"
  fi

  rm -f "$TMPLOG"
  return $status
}

download_try_all_strategies() {
  # Args: ID FMT OUTFILE
  local ID="$1"; local FMT="$2"; local OUT="$3"

  # Strategy 1: native HLS (or plain if not supported)
  if [ "${#STRAT1_FLAGS[@]}" -gt 0 ]; then
    download_one_try "$ID" "$FMT" "$OUT" "${STRAT1_FLAGS[@]}" && return 0
  else
    download_one_try "$ID" "$FMT" "$OUT" && return 0
  fi

  # Strategy 2: Android client (DASH)
  if [ "${#STRAT2_FLAGS[@]}" -gt 0 ]; then
    download_one_try "$ID" "$FMT" "$OUT" "${STRAT2_FLAGS[@]}" && return 0
  fi

  # Strategy 3: Cookies (alone and combined)
  if [ "${#STRAT3_FLAGS[@]}" -gt 0 ]; then
    if [ "${#STRAT1_FLAGS[@]}" -gt 0 ]; then
      download_one_try "$ID" "$FMT" "$OUT" "${STRAT1_FLAGS[@]}" "${STRAT3_FLAGS[@]}" && return 0
    fi
    if [ "${#STRAT2_FLAGS[@]}" -gt 0 ]; then
      download_one_try "$ID" "$FMT" "$OUT" "${STRAT2_FLAGS[@]}" "${STRAT3_FLAGS[@]}" && return 0
    fi
    download_one_try "$ID" "$FMT" "$OUT" "${STRAT3_FLAGS[@]}" && return 0
  fi

  return 1
}

merge_outputs() {
  local V="$1"; local A="$2"; local OUT="$3"
  if [ -s "$V" ] && [ -s "$A" ]; then
    echo "Merging (stream copy) video=$V + audio=$A -> $OUT"
    ffmpeg -y -i "$V" -i "$A" -c copy "$OUT" && return 0
    return 1
  fi
  if [ -s "$V" ] && [ ! -s "$A" ]; then
    echo "Only video present ($V). Renaming to $OUT."
    mv -f "$V" "$OUT"
    return 0
  fi
  echo "Nothing to merge. Check your downloads."
  return 1
}

prompt_with_default() {
  local PROMPT="$1"; local DEFAULT="$2"; local ANSWER=""
  read -r -p "$PROMPT [$DEFAULT]: " ANSWER
  [ -z "$ANSWER" ] && ANSWER="$DEFAULT"
  echo "$ANSWER"
}

prompt_format_code() {
  local PROMPT="$1"; local ANSWER=""
  read -r -p "$PROMPT (or type 'auto'): " ANSWER
  [ -z "$ANSWER" ] && ANSWER="auto"
  echo "$ANSWER"
}

# --------------------- FLOWS ---------------------
auto_mode() {
  local RAW="$1"
  local ID; ID="$(normalize_id "$RAW")"
  echo "Running automatic best for: $ID"

  # Prefer separate tracks first (mp4/m4a bias), then single-best fallback
  if download_try_all_strategies "$ID" "bv*[ext=mp4]/bv*[ext=m4v]/bestvideo" "$OUT_VIDEO"; then
    if download_try_all_strategies "$ID" "ba[ext=m4a]/bestaudio" "$OUT_AUDIO"; then
      merge_outputs "$OUT_VIDEO" "$OUT_AUDIO" "$OUT_MERGED" || exit 1
      echo "Done: $OUT_MERGED"
      return
    fi
  fi

  local ONEPASS="onepass.temp.mp4"
  rm -f "$ONEPASS"
  if download_try_all_strategies "$ID" "bestvideo*+bestaudio/best" "$ONEPASS"; then
    mv "$ONEPASS" "$OUT_MERGED"
    echo "Done (single file): $OUT_MERGED"
    return
  fi

  echo "Automatic mode failed after multiple strategies."
  exit 1
}

interactive_mode_with_id() {
  local RAW="$1"
  local ID; ID="$(normalize_id "$RAW")"

  # VIDEO
  list_formats "$ID"
  local V_FMT
  V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"

  while true; do
    if [ "$V_FMT" = "auto" ]; then
      echo "Trying automatic best VIDEO for: $ID"
      if download_try_all_strategies "$ID" "bv*[ext=mp4]/bv*[ext=m4v]/bestvideo/best" "$OUT_VIDEO"; then
        echo "Video downloaded: $OUT_VIDEO"
        break
      else
        echo "Auto video selection failed. Re-listing formats..."
        list_formats "$ID"
        V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"
      fi
    else
      if download_try_all_strategies "$ID" "$V_FMT" "$OUT_VIDEO"; then
        echo "Video downloaded: $OUT_VIDEO"
        break
      else
        echo "Video download failed. Re-listing formats..."
        list_formats "$ID"
        V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"
      fi
    fi
  done

  # AUDIO (same ID)
  list_formats "$ID"
  local A_FMT
  A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"

  while true; do
    if [ "$A_FMT" = "auto" ]; then
      echo "Trying automatic best AUDIO for: $ID"
      if download_try_all_strategies "$ID" "ba[ext=m4a]/bestaudio/best" "$OUT_AUDIO"; then
        echo "Audio downloaded: $OUT_AUDIO"
        break
      else
        echo "Auto audio selection failed. Re-listing formats..."
        list_formats "$ID"
        A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"
      fi
    else
      if download_try_all_strategies "$ID" "$A_FMT" "$OUT_AUDIO"; then
        echo "Audio downloaded: $OUT_AUDIO"
        break
      else
        echo "Audio download failed. Re-listing formats..."
        list_formats "$ID"
        A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"
      fi
    fi
  done

  merge_outputs "$OUT_VIDEO" "$OUT_AUDIO" "$OUT_MERGED" || exit 1
  echo "Merging complete. File: $OUT_MERGED"
}

interactive_mode() {
  echo "Enter the video ID or URL:"
  read -r FIRST_ID
  FIRST_ID="$(normalize_id "$FIRST_ID")"

  local AUDIO_ID_DEFAULT="$FIRST_ID"
  local AUDIO_ID
  AUDIO_ID="$(prompt_with_default "Enter a DIFFERENT audio ID/URL (or press Enter to reuse video ID)" "$AUDIO_ID_DEFAULT")"
  AUDIO_ID="$(normalize_id "$AUDIO_ID")"

  # VIDEO
  list_formats "$FIRST_ID"
  local V_FMT
  V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"

  while true; do
    if [ "$V_FMT" = "auto" ]; then
      echo "Trying automatic best VIDEO for: $FIRST_ID"
      if download_try_all_strategies "$FIRST_ID" "bv*[ext=mp4]/bv*[ext=m4v]/bestvideo/best" "$OUT_VIDEO"; then
        echo "Video downloaded: $OUT_VIDEO"
        break
      else
        echo "Auto video selection failed. Re-listing formats..."
        list_formats "$FIRST_ID"
        V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"
      fi
    else
      if download_try_all_strategies "$FIRST_ID" "$V_FMT" "$OUT_VIDEO"; then
        echo "Video downloaded: $OUT_VIDEO"
        break
      else
        echo "Video download failed. Re-listing formats..."
        list_formats "$FIRST_ID"
        V_FMT="$(prompt_format_code "Enter the format code for the VIDEO")"
      fi
    fi
  done

  # AUDIO
  list_formats "$AUDIO_ID"
  local A_FMT
  A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"

  while true; do
    if [ "$A_FMT" = "auto" ]; then
      echo "Trying automatic best AUDIO for: $AUDIO_ID"
      if download_try_all_strategies "$AUDIO_ID" "ba[ext=m4a]/bestaudio/best" "$OUT_AUDIO"; then
        echo "Audio downloaded: $OUT_AUDIO"
        break
      else
        echo "Auto audio selection failed. Re-listing formats..."
        list_formats "$AUDIO_ID"
        A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"
      fi
    else
      if download_try_all_strategies "$AUDIO_ID" "$A_FMT" "$OUT_AUDIO"; then
        echo "Audio downloaded: $OUT_AUDIO"
        break
      else
        echo "Audio download failed. Re-listing formats..."
        list_formats "$AUDIO_ID"
        A_FMT="$(prompt_format_code "Enter the format code for the AUDIO")"
      fi
    fi
  done

  merge_outputs "$OUT_VIDEO" "$OUT_AUDIO" "$OUT_MERGED" || exit 1
  echo "Merging complete. File: $OUT_MERGED"
}

# --------------------- ARG PARSER ---------------------
# (Bash 3.2 compatible)
while [ $# -gt 0 ]; do
  case "$1" in
    --id=*)
      CLI_ID="${1#*=}"; shift
      ;;
    --id)
      shift
      [ $# -gt 0 ] || { echo "--id requires a value"; usage; exit 2; }
      CLI_ID="$1"; shift
      ;;
    --auto)
      CLI_AUTO=1; shift
      ;;
    --cookies)
      USE_COOKIES=1
      if supports_flag "--cookies-from-browser"; then
        STRAT3_FLAGS=( "--cookies-from-browser" "$COOKIE_BROWSER" )
      fi
      shift
      ;;
    --ipv4)
      FORCE_IPV4=1
      COMMON_FLAGS+=( "-4" )
      shift
      ;;
    --ua=*)
      CUSTOM_UA="${1#*=}"
      COMMON_FLAGS+=( "--user-agent" "$CUSTOM_UA" )
      shift
      ;;
    --help|-h)
      usage; exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage; exit 2
      ;;
  esac
done

# --------------------- ENTRY ---------------------
if [ "$CLI_AUTO" = "1" ]; then
  if [ -n "$CLI_ID" ]; then
    auto_mode "$CLI_ID"
  else
    echo "Enter the video ID or URL (auto mode):"
    read -r TMP_ID
    [ -n "$TMP_ID" ] || { echo "No ID provided."; exit 2; }
    auto_mode "$TMP_ID"
  fi
  exit 0
fi

if [ -n "$CLI_ID" ]; then
  interactive_mode_with_id "$CLI_ID"
else
  interactive_mode
fi
