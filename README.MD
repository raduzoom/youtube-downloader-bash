## Examples

### Prompt for formats, but lock both VIDEO and AUDIO to a single ID
```bash
./yt-dl.sh --id=rVrIklMgR5s
```
### Fully automatic best (no prompts at all)
```bash
./yt-dl.sh --auto --id=rVrIklMgR5s
```
### Automatic best + cookies (helpful for age/geo/403)
```bash
USE_COOKIES=1 ./yt-dl.sh --auto --id=rVrIklMgR5s
# or:
./yt-dl.sh --auto --id=rVrIklMgR5s --cookies
```

### Force IPv4 or set custom User-Agent
```bash
./yt-dl.sh --auto --id=rVrIklMgR5s --ipv4
CUSTOM_UA="$(yt-dlp --dump-user-agent)" ./yt-dl.sh --auto --id=rVrIklMgR5s
```

Why this works well

--id uses the same ID for both video and audio, skipping the “different audio ID” prompt.

--auto enables automatic format selection (bestvideo+bestaudio with fallback to a single best stream).

Combined (--auto --id), the script becomes fully non-interactive.

Includes a resilient fallback chain to avoid 403 Forbidden issues:

Native HLS

Android client (DASH/HTTPS formats)

Cookies from browser (optional)