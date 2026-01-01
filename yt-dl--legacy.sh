#!/usr/bin/env bash
# Script: yt-dl.sh
# Purpose: Interactive/auto download of video+audio with yt-dlp and merge to output.mp4
# Works on macOS Bash 3.2+. Requires yt-dlp and ffmpeg.

set -u
IFS=$'\n\t'

# --------------------- CONFIG ---------------------
OUT_VIDEO="vtemp.mp4"
OUT_AUDIO="vtemp.m4a"
OUT_MERGED="output.mp4"

# Optional cookie retry (helps with age/geo/session 403s)
# Usage: USE_COOKIES=1 COOKIE_BROWSER=chrome ./yt-dl.sh
USE_COOKIES="${USE_COOKIES:-0}"
COOKIE_BROWSER="${COOKIE_BROWSER:-chrome}"

# Optional IPv4 and custom UA:
# Usage: FORCE_IPV4=1 ./yt-dl.sh
FORCE_IPV4="${FORCE_IPV4:-0}"
CUSTOM_UA="${CUSTOM_UA:-}"

# --------------------- FLAG BUILD ---------------------
COMMON_FLAGS=()
supports_flag() {
  local f="$1"
  yt-dlp --help 2>/dev/null | grep -q -- "$f"
}

# Add commonly helpful flags only if your yt-dlp supports them
supports_flag "--no-continue" && COMMON_FLAGS+=("--no-continue")
supports_flag "--no-part" && COMMON_FLAGS+=("--no-part")
supports_flag "--concurrent-fragments" && COMMON_FLAGS+=("--concurrent-fragments" "8")
# Always add -i (ignore errors) safely:
COMMON_FLAGS+=("-i")

if [ "$FORCE_IPV4" = "1" ]; then
  # -4 is widely supported
  COMMON_FLAGS+=("-4")
fi

if [ -n "$CUSTOM_UA" ]; then
  COMMON_FLAGS+=("--user-agent" "$CUSTOM_UA")
fi

# Strategy 1: prefer native HLS (avoid ffmpeg fetching segments)
STRAT1_FLAGS=()
supports_flag "--hls-prefer-native" && STRAT1_FLAGS+=("--hls-prefer-native")

# Strategy 2: use Android client to prefer DASH/HTTPS (non-HLS)
STRAT2_FLAGS=()
# extractor-args is widely supported in current yt-dlp; if missing, it will be ignored below
if supports_flag "--extractor-args"; then
  STRAT2_FLAGS+=("--extractor-args" "youtube:player_client=android")
fi

# Strategy 3: cookies from browser (if enabled)
STRAT3_FLAGS=()
if [ "$USE_COOKIES" = "1" ] && supports_flag "--cookies-from-browser"; then
  STRAT3_FLAGS+=("--cookies-from-browser" "$COOKIE_BROWSER")
fi

# --------------------- HELPERS ---------------------
print_hr() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
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

download_one_try() {
  # Args: ID FMT OUTFILE FLAGS_ARRAY_NAME
  local ID="$1" ; local FMT="$2" ; local OUT="$3" ; local FLAGS_NAME="$4"
  rm -f "$OUT"
  local TMPLOG ; TMPLOG="$(mktemp -t ytdlp_XXXX.log)"

  # Indirect expansion of array
  # shellcheck disable=SC2086,SC2154
  yt-dlp "${COMMON_FLAGS[@]}" ${!FLAGS_NAME} -f "$FMT" "$ID" -o "$OUT" >"$TMPLOG" 2>&1
  local status=$?

  if [ $status -ne 0 ]; then
    echo "Download failed for format '$FMT' (ID: $ID) with flags: ${!FLAGS_NAME}"
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
  local ID="$1" ; local FMT="$2" ; local OUT="$3"

  # Strategy 1: native HLS
  if [ "${#STRAT1_FLAGS[@]}" -gt 0 ]; then
    download_one_try "$ID" "$FMT" "$OUT" STRAT1_FLAGS && return 0
  else
    # Even without STRAT1, try with just COMMON_FLAGS
    download_one_try "$ID" "$FMT" "$OUT" COMMON_FLAGS && return 0
  fi

  # Strategy 2: Android client (DASH)
  if [ "${#STRAT2_FLAGS[@]}" -gt 0 ]; then
    download_one_try "$ID" "$FMT" "$OUT" STRAT2_FLAGS && return 0
  fi

  # Strategy 3: Cookies (alone and combined)
  if [ "${#STRAT3_FLAGS[@]}" -gt 0 ]; then
    # Try cookies with native HLS
    local COMBO1=("${STRAT1_FLAGS[@]}" "${STRAT3_FLAGS[@]}")
    download_one_try "$ID" "$FMT" "$OUT" COMBO1 && return 0
    # Try cookies with android client
    local COMBO2=("${STRAT2_FLAGS[@]}" "${STRAT3_FLAGS[@]}")
    download_one_try "$ID" "$FMT" "$OUT" COMBO2 && return 0
  fi

  return 1
}

merge_outputs() {
  local V="$1" ; local A="$2" ; local OUT="$3"
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
  local PROMPT="$1" ; local DEFAULT="$2" ; local ANSWER=""
  read -r -p "$PROMPT [$DEFAULT]: " ANSWER
  [ -z "$ANSWER" ] && ANSWER="$DEFAULT"
  echo "$ANSWER"
}

prompt_format_code() {
  local PROMPT="$1" ; local ANSWER=""
  read -r -p "$PROMPT (or type 'auto'): " ANSWER
  [ -z "$ANSWER" ] && ANSWER="auto"
  echo "$ANSWER"
}

# --------------------- FLOWS ---------------------
auto_mode() {
  local ID="$1"
  echo "Running automatic best for: $ID"

  # Prefer separate tracks first (mp4/m4a bias), then single best fallback.
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

interactive_mode() {
  echo "Enter the video ID or URL:"
  read -r FIRST_ID

  local AUDIO_ID_DEFAULT="$FIRST_ID"
  local AUDIO_ID
  AUDIO_ID="$(prompt_with_default "Enter a DIFFERENT audio ID/URL (or press Enter to reuse video ID)" "$AUDIO_ID_DEFAULT")"

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

  # MERGE
  merge_outputs "$OUT_VIDEO" "$OUT_AUDIO" "$OUT_MERGED" || exit 1
  echo "Merging complete. File: $OUT_MERGED"
}

# --------------------- ENTRY ---------------------
if [ "${1:-}" = "--auto" ] && [ -n "${2:-}" ]; then
  auto_mode "$2"
  exit 0
fi

interactive_mode
