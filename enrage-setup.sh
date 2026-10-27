#!/usr/bin/env bash
# =============================================================================
#  enrage-setup.sh — install & configure the enRAGE mod for Red Dead Redemption 2
#                    on SteamOS (Steam Deck, ROG Ally / Xbox Ally, Legion Go, …)
#
#  Version : 1.0.0
#  License : MIT (see LICENSE)
#
#  Option 1 ("Full install / repair"):
#    1. Finds RDR2 in any Steam library (internal storage, microSD, extra drives)
#       and its Proton prefix (which may live in a different library)
#    2. Backs up Story Mode saves and any game files it would overwrite
#    3. Extracts ScriptHookRDR2, ScriptHookRDR2DotNet V2 and enRAGE from your
#       Downloads folder and puts every file where it belongs
#    4. Installs .NET Framework 4.8 + VC++ 2019 into the Proton prefix via the
#       Protontricks flatpak (repairs the prefix user profile first and retries
#       with known workarounds), then verifies the result
#    5. Resets the prefix to Windows 10 (winetricks can leave it on XP)
#    6. Sets the Steam launch option  WINEDLLOVERRIDES="dinput8=n,b" %command%
#
#  Usage (from Desktop Mode, as your normal user — not root):
#    bash enrage-setup.sh                 interactive menu
#    bash enrage-setup.sh <command>       install | status | disable | enable |
#                                         uninstall | reset | fixwin | fixnet
#    bash enrage-setup.sh --help
#
#  Environment overrides (all optional):
#    DL_DIR      folder with the three downloads           (default ~/Downloads)
#    GAME_DIR    path to the "Red Dead Redemption 2" folder (auto-detected)
#    PFX_DIR     path to compatdata/1174180/pfx             (auto-detected)
#    BACKUP_ROOT where backups and logs go          (default ~/RDR2-enRAGE-backups)
#    FORCE_DEPS=1  reinstall .NET even if it's already detected
#
#  This script does not download or redistribute any mod files.
#  STORY MODE ONLY. Never play Red Dead Online with Script Hook active —
#  use "disable" first.
# =============================================================================
set -uo pipefail

APPID=1174180
OVERRIDE='WINEDLLOVERRIDES="dinput8=n,b"'
PT=com.github.Matoking.protontricks
DL_DIR="${DL_DIR:-$HOME/Downloads}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/RDR2-enRAGE-backups}"
MANIFEST_NAME=".enrage-manifest"
DISABLED_NAME="_enrage_disabled"
ROOT_FILES=(ScriptHookRDR2.dll dinput8.dll ScriptHookRDRDotNet.asi ScriptHookRDRDotNet.ini ScriptHookRDRNetAPI.dll)
ENRAGE_FILES=(scripts/NemesisMod.dll scripts/Newtonsoft.Json.dll)

DEPLOG=/dev/null ; STEAM_ROOT="" ; LIB_DIR="" ; LIBS=() ; PFX_CHECKED=() ; GAME_DIR="${GAME_DIR:-}" ; PFX="" ; DOCS=""
TS="$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/enrage-setup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- helpers ----
if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B=""; G=""; Y=""; R=""; C=""; N=""; fi
info() { echo "${C}==>${N} $*"; }
ok()   { echo "  ${G}✔${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
bad()  { echo "  ${R}✘${N} $*"; }
die()  { echo; echo "${R}${B}ERROR:${N} $*"; pause_exit 1; }
ask()  { local a; read -r -p "  $1 [Y/n] " a; [[ -z "$a" || "$a" =~ ^[Yy] ]]; }
pause_exit() { if [[ -t 0 && "${NONINTERACTIVE:-0}" != 1 ]]; then read -r -p $'\nPress Enter to close...' _; fi; exit "${1:-0}"; }

steam_running() { pgrep -x steam >/dev/null 2>&1 || pgrep -f 'ubuntu12_32/steam' >/dev/null 2>&1; }
game_running()  { pgrep -xi 'RDR2\.exe|PlayRDR2\.exe' >/dev/null 2>&1; }   # Wine names the process after the .exe

# ------------------------------------------------------------- discovery -----
find_steam_root() {
  local c
  for c in "$HOME/.local/share/Steam" "$HOME/.steam/steam" "$HOME/.steam/root" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    if [[ -f "$c/steamapps/libraryfolders.vdf" || -f "$c/config/libraryfolders.vdf" ]]; then
      STEAM_ROOT="$(readlink -f "$c")"; return 0
    fi
  done
  die "Couldn't find your Steam folder (~/.local/share/Steam)."
}

find_game() {
  if [[ -n "$GAME_DIR" ]]; then
    [[ -f "$GAME_DIR/RDR2.exe" ]] || die "GAME_DIR is set but RDR2.exe isn't in: $GAME_DIR"
    GAME_DIR="$(readlink -f "$GAME_DIR")"; LIB_DIR="$(readlink -f "$GAME_DIR/../../..")"
  else
    local l
    for l in "${LIBS[@]}"; do
      if [[ -f "$l/steamapps/common/Red Dead Redemption 2/RDR2.exe" ]]; then
        LIB_DIR="$(readlink -f "$l")"; GAME_DIR="$LIB_DIR/steamapps/common/Red Dead Redemption 2"; break
      fi
    done
    [[ -n "$GAME_DIR" ]] || die "Red Dead Redemption 2 (Steam) isn't installed in any Steam library I can see.
       If it's somewhere unusual, run:  GAME_DIR=\"/path/to/Red Dead Redemption 2\" bash $0"
  fi
  find_prefix
}

load_libs() {
  local vdf l
  LIBS=("$STEAM_ROOT")
  for vdf in "$STEAM_ROOT/steamapps/libraryfolders.vdf" "$STEAM_ROOT/config/libraryfolders.vdf"; do
    [[ -f "$vdf" ]] || continue
    while IFS= read -r l; do
      l="${l//\\\\/\\}"                       # unescape \\ from the vdf
      [[ -d "$l" ]] && LIBS+=("$(readlink -f "$l")")
    done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf")
  done
}

# The Proton prefix is NOT always in the same library as the game (e.g. game moved
# to/from the microSD, or an extra internal drive). Check every library + common spots.
find_prefix() {
  local c cands=()
  if [[ -n "${PFX_DIR:-}" ]]; then cands+=("${PFX_DIR%/}"); fi
  cands+=("$LIB_DIR/steamapps/compatdata/$APPID/pfx")
  for c in "${LIBS[@]}"; do cands+=("$c/steamapps/compatdata/$APPID/pfx"); done
  cands+=("$STEAM_ROOT/steamapps/compatdata/$APPID/pfx"
          "$HOME/.local/share/Steam/steamapps/compatdata/$APPID/pfx"
          "$HOME/.steam/steam/steamapps/compatdata/$APPID/pfx")
  PFX="" ; PFX_CHECKED=()
  local seen=" "
  for c in "${cands[@]}"; do
    [[ "$seen" == *" $c "* ]] && continue; seen+="$c "
    PFX_CHECKED+=("$c")
    if [[ -d "$c/drive_c" ]]; then PFX="$(readlink -f "$c")"; break; fi
  done
  # last resort: search internal storage + any mounted drives/SD cards
  if [[ -z "$PFX" ]]; then
    c="$(find "$HOME" /run/media /media /mnt -maxdepth 7 -type d -path "*/compatdata/$APPID/pfx" 2>/dev/null \
          | while IFS= read -r d; do [[ -d "$d/drive_c" ]] && echo "$d"; done | head -n1)"
    PFX_CHECKED+=("(searched \$HOME, /run/media, /media, /mnt)")
    [[ -n "$c" ]] && PFX="$(readlink -f "$c")"
  fi
  [[ -n "$PFX" ]] || PFX="$LIB_DIR/steamapps/compatdata/$APPID/pfx"   # expected location for messages
  DOCS="$PFX/drive_c/users/steamuser/Documents/Rockstar Games/Red Dead Redemption 2"
}

no_prefix_help() {
  echo
  bad "I couldn't find RDR2's Proton prefix (compatdata/$APPID/pfx/drive_c). Places checked:"
  local c; for c in "${PFX_CHECKED[@]}"; do echo "      - $c"; done
  echo "    Most common causes:"
  echo "     • The game was launched under a different Steam install/user or before a reinstall."
  echo "       → Launch RDR2 from Steam on THIS device, wait for the Rockstar Launcher + main menu, quit."
  echo "     • It's the Rockstar/Epic version via Heroic or Lutris (not Steam) — this script is for Steam."
  echo "     • You know where the prefix is → run:  PFX_DIR=\"/path/to/compatdata/$APPID/pfx\" bash $0"
  echo "    Tip: in Steam, RDR2 > ⚙ > Properties > Installed Files > Browse shows the library it's in."
}

discover() {
  find_steam_root
  load_libs
  find_game
  ok "Game folder: $GAME_DIR"
  if [[ -d "$PFX/drive_c" ]]; then ok "Proton prefix: $PFX"
  else warn "Proton prefix not found (see details below if this blocks the install)."; fi
}

# ---------------------------------------------------------- archives ---------
# newest archive in DL_DIR whose (lowercased) name matches $1 and not $2
newest_match() {
  find "$DL_DIR" -maxdepth 2 -type f \( -iname '*.zip' -o -iname '*.7z' -o -iname '*.rar' \) -printf '%T@\t%p\n' 2>/dev/null |
    awk -F'\t' -v inc="$1" -v exc="${2:-}" '{ n=$2; sub(".*/","",n); n=tolower(n);
         if (n ~ inc && (exc=="" || n !~ exc)) print }' | sort -rn | head -n1 | cut -f2-
}

pick_archive() {  # $1 label  $2 include-regex  $3 exclude-regex
  local f; f="$(newest_match "$2" "${3:-}")"
  if [[ -n "$f" ]]; then
    ok "$1: $(basename "$f")" >&2
  else
    warn "Couldn't find the $1 download in $DL_DIR" >&2
    read -r -p "    Drag the file into this window (or type its path) then press Enter: " f
    f="${f//\'/}"; f="${f//\"/}"; f="${f%"${f##*[![:space:]]}"}"
    [[ -f "$f" ]] || die "File not found: $f"
  fi
  printf '%s' "$f"
}

extract() {  # $1 archive  $2 dest
  mkdir -p "$2"
  if command -v bsdtar >/dev/null; then bsdtar -xf "$1" -C "$2" && return 0; fi
  if command -v 7z >/dev/null; then 7z x -y -o"$2" "$1" >/dev/null && return 0; fi
  case "${1,,}" in
    *.zip) if command -v unzip >/dev/null; then unzip -oq "$1" -d "$2" && return 0; fi
           python3 -m zipfile -e "$1" "$2" && return 0 ;;
  esac
  die "Couldn't extract $(basename "$1"). If it's a .7z/.rar, re-download the .zip version from the mod page."
}

first_file() { find "$1" -type f -iname "$2" 2>/dev/null | awk '{print length, $0}' | sort -n | head -n1 | cut -d' ' -f2-; }

# ----------------------------------------------------------- file ops --------
backup_saves() {
  local dst="$BACKUP_ROOT/$TS"
  mkdir -p "$dst"
  if [[ -d "$DOCS" ]]; then
    cp -a "$DOCS" "$dst/Documents-RDR2" && ok "Saves + settings backed up to $dst/Documents-RDR2"
  else
    warn "No save folder yet (fine on a fresh install)."
  fi
}

install_file() {  # $1 source  $2 relative destination inside GAME_DIR
  local dst="$GAME_DIR/$2"
  mkdir -p "$(dirname "$dst")"
  if [[ -e "$dst" ]] && ! cmp -s "$1" "$dst"; then
    mkdir -p "$BACKUP_ROOT/$TS/game-root/$(dirname "$2")"
    cp -a "$dst" "$BACKUP_ROOT/$TS/game-root/$2"
  fi
  cp -f "$1" "$dst" || die "Couldn't copy $(basename "$1") into the game folder."
  grep -qxF "$2" "$GAME_DIR/$MANIFEST_NAME" 2>/dev/null || echo "$2" >> "$GAME_DIR/$MANIFEST_NAME"
}

manifest_list() {
  if [[ -s "$GAME_DIR/$MANIFEST_NAME" ]]; then cat "$GAME_DIR/$MANIFEST_NAME"
  else printf '%s\n' "${ROOT_FILES[@]}" "${ENRAGE_FILES[@]}"; fi
}

copy_mod_files() {
  info "Locating your downloads in $DL_DIR"
  local sh net en
  sh="$(pick_archive  "ScriptHookRDR2"          'scripthook.*rdr2|scripthookrdr2' 'dotnet|\.net|netapi')"
  net="$(pick_archive "ScriptHookRDR2DotNet V2" 'dotnet')"
  en="$(pick_archive  "enRAGE"                  'enrage|nemesis')"
  [[ -f "$sh" && -f "$net" && -f "$en" ]] || die "One of the three downloads is missing — see the list above."

  info "Extracting"
  extract "$sh"  "$WORK/sh"; extract "$net" "$WORK/net"; extract "$en" "$WORK/en"

  info "Installing files into the game folder"
  local f name
  # ScriptHookRDR2 core — prefer the copies under bin/
  for name in ScriptHookRDR2.dll dinput8.dll; do
    f="$(find "$WORK/sh" -type f -ipath '*bin*' -iname "$name" | head -n1)"
    [[ -n "$f" ]] || f="$(first_file "$WORK/sh" "$name")"
    [[ -n "$f" ]] || die "$name wasn't in $(basename "$sh"). Is that the ScriptHookRDR2 download from dev-c.com?"
    install_file "$f" "$name"; ok "$name"
  done
  # ScriptHookRDR2DotNet V2 — the .asi, its .ini and the API dll go in the ROOT
  for name in ScriptHookRDRDotNet.asi ScriptHookRDRNetAPI.dll; do
    f="$(first_file "$WORK/net" "$name")"
    [[ -n "$f" ]] || die "$name wasn't in $(basename "$net"). Is that ScriptHookRDR2DotNet V2 (2.2.0+)?"
    install_file "$f" "$name"; ok "$name"
  done
  f="$(first_file "$WORK/net" 'ScriptHookRDRDotNet.ini')"
  if [[ -n "$f" ]]; then
    if [[ -f "$GAME_DIR/ScriptHookRDRDotNet.ini" ]]; then ok "ScriptHookRDRDotNet.ini (kept your existing one)"
    else install_file "$f" ScriptHookRDRDotNet.ini; ok "ScriptHookRDRDotNet.ini"; fi
  fi
  # enRAGE — everything next to NemesisMod.dll goes into <game>/scripts/
  f="$(first_file "$WORK/en" 'NemesisMod.dll')"
  [[ -n "$f" ]] || die "NemesisMod.dll wasn't in $(basename "$en"). Download the main enRAGE archive (the one with the 'scripts' folder), not just the .exe installer."
  local src; src="$(dirname "$f")"
  while IFS= read -r -d '' f; do
    install_file "$f" "scripts/${f#"$src"/}"
  done < <(find "$src" -type f -print0)
  ok "enRAGE scripts → scripts/ ($(find "$src" -type f | wc -l) files)"
  # clean up the classic mistake of a nested scripts/scripts folder from earlier manual attempts
  if [[ -f "$GAME_DIR/scripts/scripts/NemesisMod.dll" ]]; then
    warn "Found an old nested scripts/scripts/ folder — moving it to the backup."
    mkdir -p "$BACKUP_ROOT/$TS"; mv "$GAME_DIR/scripts/scripts" "$BACKUP_ROOT/$TS/nested-scripts"
  fi
}

# ------------------------------------------------------- dependencies --------
# .NET 4.8 counts as installed only if BOTH the runtime DLL and the setup registry key exist.
dotnet_files() { [[ -f "$PFX/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll" ]]; }
dotnet_release() {  # prints the .NET 4.x "Release" number from system.reg (empty if none)
  [[ -f "$PFX/system.reg" ]] || return 0
  python3 - "$PFX/system.reg" <<'PY'
import sys, re
want = {r'Software\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full',
        r'Software\\Wow6432Node\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full'}
sec, rel = None, 0
for line in open(sys.argv[1], encoding='utf-8', errors='surrogateescape'):
    if line.startswith('['): sec = line.split(']')[0][1:]
    elif sec in want:
        m = re.match(r'"Release"=dword:([0-9a-fA-F]+)', line)
        if m: rel = max(rel, int(m.group(1), 16))
print(rel or '')
PY
}
dotnet_present() { local r; r="$(dotnet_release)"; dotnet_files && [[ -n "$r" && "$r" -ge 528040 ]]; }

pt() { flatpak run "$PT" "$@"; }       # protontricks wrapper
pt_cmd() { pt -c "$1" "$APPID"; }      # run a shell command with the game's Wine/prefix env

wine_idle() { pkill -f wineserver >/dev/null 2>&1; sleep 2; }

ensure_protontricks() {
  command -v flatpak >/dev/null || die "flatpak isn't available — this doesn't look like SteamOS."
  if ! flatpak info "$PT" >/dev/null 2>&1; then
    info "Installing Protontricks (flatpak, one-time)"
    flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 || true
    flatpak install -y --user flathub "$PT" || flatpak install -y flathub "$PT" || die "Couldn't install Protontricks. Install it from Discover, then re-run."
  fi
  # let the sandboxed Protontricks see the game's library AND the prefix's library (e.g. microSD)
  flatpak override --user --filesystem="$LIB_DIR" "$PT" >/dev/null 2>&1 || true
  flatpak override --user --filesystem="${PFX%/steamapps/compatdata/*}" "$PT" >/dev/null 2>&1 || true
  flatpak override --user --filesystem=/run/media "$PT" >/dev/null 2>&1 || true
  if ! pt -l 2>/dev/null | grep -q "$APPID"; then
    warn "Protontricks doesn't list RDR2 ($APPID) yet — it may not see your Steam library."
  fi
  ok "Protontricks ready"
}

# Known Proton problem: the prefix's user SID has no ProfileList entry, so the .NET 4.8
# installer aborts ("...does not have a valid profile") while protontricks still exits 0.
fix_profile_sid() {
  local sid
  sid="$(sed -n 's/^;; All keys relative to \\\\User\\\\\(S-[0-9-]*\).*/\1/p' "$PFX/user.reg" 2>/dev/null | head -n1)"
  [[ -n "$sid" ]] || sid="S-1-5-21-0-0-0-1000"
  info "Repairing the prefix user profile ($sid) so the .NET installer accepts it"
  # shellcheck disable=SC2016  # $WINE is expanded by protontricks' shell, not ours
  pt_cmd '"${WINE:-wine}" wineboot -u' >>"$DEPLOG" 2>&1 || true
  wine_idle
  pt_cmd "\"\${WINE:-wine}\" reg add 'HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\$sid' /v ProfileImagePath /t REG_EXPAND_SZ /d 'C:\\users\\steamuser' /f" >>"$DEPLOG" 2>&1 || true
  pt_cmd "\"\${WINE:-wine}\" reg add 'HKLM\\Software\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\$sid' /v Flags /t REG_DWORD /d 0 /f" >>"$DEPLOG" 2>&1 || true
  wine_idle
  if grep -q "ProfileList\\\\\\\\$sid\]" "$PFX/system.reg" 2>/dev/null; then ok "User profile entry present"
  else warn "Couldn't confirm the profile entry (continuing anyway)"; fi
}

# Some Proton builds link the prefix's Windows files back into Proton itself; the
# .NET installer can't replace those. Turning the links into real files fixes it (~1–1.5 GB).
deref_windows_dir() {
  local w="$PFX/drive_c/windows" n
  n="$(find "$w" -type l 2>/dev/null | wc -l)"
  [[ "$n" -gt 0 ]] || { ok "Prefix Windows folder has no links to fix"; return 1; }
  info "Converting $n linked Windows files into real files (one-time, ~1–1.5 GB)"
  local free; free="$(df -Pk "$PFX" | awk 'NR==2{print $4}')"
  [[ "$free" -gt 3000000 ]] || { bad "Need ~3 GB free on that drive for this step."; return 1; }
  rm -rf "$w.enrage-deref"
  if cp -RL "$w" "$w.enrage-deref" 2>>"$DEPLOG"; then
    mv "$w" "$BACKUP_ROOT/$TS/windows-before-deref" 2>/dev/null || mv "$w" "$w.enrage-orig"
    mv "$w.enrage-deref" "$w" && ok "Done"
  else
    rm -rf "$w.enrage-deref"; bad "Copy failed (see log)"; return 1
  fi
}

dotnet_attempt() {  # $1 = label, rest = extra protontricks args
  local label="$1"; shift
  info ".NET 4.8 install — $label   (10–25 min; installer windows may flash — don't close them)"
  echo "===== attempt: $label  $(date)" >>"$DEPLOG"
  wine_idle
  pt "$@" "$APPID" -q --force dotnet48 >>"$DEPLOG" 2>&1
  wine_idle
  if dotnet_present; then ok ".NET Framework 4.8 installed (release $(dotnet_release))"; return 0; fi
  bad "Not installed after this attempt."
  return 1
}

install_deps() {
  [[ -d "$PFX/drive_c" ]] || { no_prefix_help; die "Can't install .NET without the Proton prefix."; }
  game_running && die "Quit Red Dead Redemption 2 / the Rockstar Launcher first."
  mkdir -p "$BACKUP_ROOT/$TS"; DEPLOG="$BACKUP_ROOT/$TS/dotnet-install.log"; : >"$DEPLOG"
  if dotnet_present && [[ "${FORCE_DEPS:-0}" != 1 ]]; then
    ok ".NET Framework 4.8 already in the prefix (release $(dotnet_release))"
  else
    ensure_protontricks
    cp -a "$PFX/user.reg" "$PFX/system.reg" "$BACKUP_ROOT/$TS/" 2>/dev/null
    fix_profile_sid
    dotnet_attempt "attempt 1" \
    || dotnet_attempt "attempt 2 (without sandbox)" --no-bwrap \
    || { deref_windows_dir && fix_profile_sid && dotnet_attempt "attempt 3 (after unlinking Windows files)" --no-bwrap; } \
    || {
      echo
      bad ".NET 4.8 still isn't installed. Last lines of the installer log:"
      grep -iE 'error|fail|valid profile|warning: .*dotnet|returned' "$DEPLOG" | tail -n 12 | sed 's/^/      /'
      echo "    Full log: $DEPLOG"
      warn "Next thing to try: Steam > RDR2 > ⚙ > Properties > Compatibility > tick 'Force…'"
      warn "and pick a different Proton (GE-Proton or Proton 9.0), launch to the menu once,"
      warn "quit, then run option 8 (Repair .NET)."
      return 1
    }
  fi
  info "Installing Visual C++ 2019 runtime"
  pt "$APPID" -q vcrun2019 >>"$DEPLOG" 2>&1 || pt --no-bwrap "$APPID" -q vcrun2019 >>"$DEPLOG" 2>&1 || warn "VC++ install reported an error (often harmless — Proton bundles it)."
  wine_idle
  ok "VC++ step done"
}

# -------------------------------------------------- windows version fix ------
# winetricks' dotnet installers temporarily switch the prefix to Windows XP and
# sometimes leave it there -> Rockstar Launcher: "Windows XP and Vista are no
# longer supported". Force the prefix (and any per-exe overrides) back to win10.
winver_get() {  # prints the HKCU Wine "Version" (empty = Proton default, which is win10)
  [[ -f "$PFX/user.reg" ]] || return 0
  python3 - "$PFX/user.reg" <<'PY'
import sys, re
sec, out = None, ''
for line in open(sys.argv[1], encoding='utf-8', errors='surrogateescape'):
    if line.startswith('['):
        sec = line.split(']')[0][1:]
    elif sec == r'Software\\Wine':
        m = re.match(r'"Version"="([^"]*)"', line)
        if m: out = m.group(1)
print(out)
PY
}

winver_bad() {  # true if the prefix (or an RDR2/launcher per-app override) reports an old Windows
  [[ -f "$PFX/user.reg" ]] || return 1
  grep -qiE '^"Version"="(win(xp|xp64|2k|2k3|2k8|98|95|nt40|me|7|8|81)|vista)"' "$PFX/user.reg"
}

winver_reg_edit() {  # direct, offline edit of user.reg (Wine must not be running)
  python3 - "$PFX/user.reg" <<'PY'
import sys, re, shutil, time
p = sys.argv[1]
lines = open(p, encoding='utf-8', errors='surrogateescape').read().split('\n')
shutil.copy2(p, p + '.bak-enrage-' + time.strftime('%Y%m%d-%H%M%S'))
old = re.compile(r'^"Version"="(?!win10|win11)[^"]*"', re.I)
out, sec, have_main, in_main = [], None, False, False
for line in lines:
    if line.startswith('['):
        if in_main and not have_main:
            # main section ended without a Version value: add it before the blank line
            while out and out[-1] == '': out.pop()
            out += ['"Version"="win10"', '']; have_main = True
        sec = line.split(']')[0][1:]
        in_main = (sec == r'Software\\Wine')
    elif sec and (sec == r'Software\\Wine' or sec.startswith(r'Software\\Wine\\AppDefaults\\')) and old.match(line):
        line = '"Version"="win10"'
        if in_main: have_main = True
    elif in_main and line.startswith('"Version"='):
        have_main = True
    out.append(line)
if in_main and not have_main:
    out += ['"Version"="win10"']; have_main = True
if not have_main:
    ts = int(time.time())
    out += ['', f'[Software\\\\Wine] {ts}', f'#time={ts:x}', '"Version"="win10"', '']
open(p, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(out))
PY
}

fix_winver() {
  info "Making sure the game sees Windows 10 (fixes 'Windows XP/Vista no longer supported')"
  [[ -d "$PFX/drive_c" ]] || { no_prefix_help; return 1; }
  game_running && die "Quit Red Dead Redemption 2 / the Rockstar Launcher first."
  wine_idle                                   # Wine flushes the registry on exit
  if command -v flatpak >/dev/null && flatpak info "$PT" >/dev/null 2>&1; then
    pt "$APPID" -q win10 >/dev/null 2>&1 || true
    wine_idle
  fi
  winver_bad && winver_reg_edit
  if winver_bad; then
    bad "Prefix still reports an old Windows version."
    warn "Run this in Konsole, set 'Windows Version' to Windows 10, click OK:"
    echo "      flatpak run $PT $APPID winecfg"
    return 1
  fi
  local v; v="$(winver_get)"
  ok "Windows version: ${B}${v:-Proton default (Windows 10)}${N}"
}

# ------------------------------------------------------- launch options ------
# Edits Steam's localconfig.vdf safely (Steam must be closed). $1 = set|remove|get
vdf_launch() {
  python3 - "$1" "$APPID" "$OVERRIDE" <<'PY'
import sys, os, re, glob, shutil, time
mode, appid, override = sys.argv[1], sys.argv[2], sys.argv[3]
steam = os.environ["STEAM_ROOT"]

def tokens(s):
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c.isspace(): i += 1; continue
        if s.startswith('//', i):
            j = s.find('\n', i); i = n if j < 0 else j; continue
        if c in '{}': yield c; i += 1; continue
        if c == '"':
            j, buf = i + 1, []
            while j < n and s[j] != '"':
                if s[j] == '\\' and j + 1 < n: buf.append(s[j:j+2]); j += 2
                else: buf.append(s[j]); j += 1
            yield ('S', ''.join(buf)); i = j + 1; continue
        j = i
        while j < n and not s[j].isspace() and s[j] not in '{}"': j += 1
        yield ('S', s[i:j]); i = j

def parse(it):
    out = []
    for t in it:
        if t == '}': return out
        v = next(it)
        out.append([t[1], parse(it) if v == '{' else v[1]])
    return out

def dump(node, d=0):
    s, t = '', '\t' * d
    for k, v in node:
        if isinstance(v, list): s += f'{t}"{k}"\n{t}{{\n{dump(v, d+1)}{t}}}\n'
        else: s += f'{t}"{k}"\t\t"{v}"\n'
    return s

def child(node, name, create=True):
    for kv in node:
        if kv[0].lower() == name.lower() and isinstance(kv[1], list): return kv[1]
    if not create: return None
    new = []; node.append([name, new]); return new

esc   = lambda v: v.replace('\\', '\\\\').replace('"', '\\"')
unesc = lambda v: re.sub(r'\\(.)', r'\1', v)

files = glob.glob(os.path.join(steam, 'userdata', '*', 'config', 'localconfig.vdf'))
if not files: print('NOCONFIG'); sys.exit(2)
rc = 0
for path in files:
    raw = open(path, encoding='utf-8', errors='surrogateescape').read()
    tree = parse(tokens(raw))
    root = child(tree, 'UserLocalConfigStore', False)
    if root is None: continue
    apps = child(child(child(child(root, 'Software'), 'Valve'), 'Steam'), 'apps')
    app = child(apps, appid, mode == 'set')
    if app is None: print(f'{path}\t(none)'); continue
    ent = next((kv for kv in app if kv[0].lower() == 'launchoptions' and not isinstance(kv[1], list)), None)
    cur = unesc(ent[1]) if ent else ''
    if mode == 'get':
        print(f'{path}\t{cur or "(empty)"}'); continue
    if mode == 'set':
        if 'dinput8' in cur and 'WINEDLLOVERRIDES' in cur: print('ALREADY'); continue
        if 'WINEDLLOVERRIDES' in cur:
            print(f'CONFLICT\t{cur}'); rc = 3; continue
        new = f'{override} {cur}' if '%command%' in cur else f'{override} %command% {cur}'.strip()
    else:  # remove
        new = cur.replace(override + ' ', '').replace(override, '').strip()
        if new == '%command%': new = ''
        if new == cur: continue
    if ent: ent[1] = esc(new)
    else: app.append(['LaunchOptions', esc(new)])
    shutil.copy2(path, path + '.bak-enrage-' + time.strftime('%Y%m%d-%H%M%S'))
    tmp = path + '.tmp-enrage'
    open(tmp, 'w', encoding='utf-8', errors='surrogateescape').write(dump(tree))
    os.replace(tmp, path)
    print(f'WROTE\t{new or "(cleared)"}')
sys.exit(rc)
PY
}

close_steam_for_edit() {
  steam_running || return 0
  warn "Steam has to be closed to change launch options (it rewrites the file on exit)."
  if ask "Close Steam now? (it'll reopen when you go back to Game Mode)"; then
    steam -shutdown >/dev/null 2>&1 &
    for _ in $(seq 1 40); do steam_running || return 0; sleep 1; done
    bad "Steam didn't close."; return 1
  fi
  return 1
}

set_launch_options() {
  info "Steam launch option"
  if ! close_steam_for_edit; then
    warn "Set it by hand: Steam > RDR2 > ⚙ > Properties > Launch Options, paste:"
    echo "      ${B}${OVERRIDE} %command%${N}"
    echo "${OVERRIDE} %command%" > "$HOME/Desktop/RDR2-launch-option.txt" 2>/dev/null && \
      warn "(also saved to ~/Desktop/RDR2-launch-option.txt for easy copy/paste)"
    return 0
  fi
  local out; out="$(STEAM_ROOT="$STEAM_ROOT" vdf_launch set)"; local rc=$?
  case "$out" in
    *ALREADY*) ok "Launch option already set" ;;
    *WROTE*)   ok "Launch option set: ${out##*WROTE$'\t'}" ;;
    *CONFLICT*) warn "You already have custom WINEDLLOVERRIDES: ${out##*CONFLICT$'\t'}"
                warn "Add  dinput8=n,b  to it yourself (comma-separated) — I didn't touch it." ;;
    *NOCONFIG*) warn "No Steam user config found — set it by hand: ${OVERRIDE} %command%" ;;
    *) [[ $rc -eq 0 ]] || warn "Couldn't edit automatically — set by hand: ${OVERRIDE} %command%" ;;
  esac
}

# ------------------------------------------------------------- actions -------
do_install() {
  echo; info "${B}Full install of enRAGE for RDR2${N}"
  game_running && die "Quit Red Dead Redemption 2 first."
  discover
  if [[ ! -d "$PFX/drive_c" ]]; then
    no_prefix_help
    die "Can't continue without the Proton prefix."
  fi
  echo
  echo "  You need these 3 downloads in ${B}$DL_DIR${N} (zips are fine, no need to extract):"
  echo "   • ScriptHookRDR2        — https://www.dev-c.com/rdr2/scripthookrdr2/  (latest!)"
  echo "   • ScriptHookRDR2DotNet V2 (2.2.0+) — https://github.com/Halen84/ScriptHookRDR2DotNet-V2/releases"
  echo "   • enRAGE                — Nexus Mods: 'enRage - Living World and Nemesis System'"
  echo
  info "Backing up"
  backup_saves
  copy_mod_files
  echo; install_deps || warn "Dependency step needs attention (see above) — mod files are in place."
  echo; fix_winver  || warn "Windows-version fix needs attention (see above)."
  echo; set_launch_options
  echo; do_status quiet
  echo
  if ! dotnet_present; then
    echo "${R}${B}NOT READY:${N} .NET 4.8 is missing, so enRAGE won't load yet. See the messages above (option 8 retries)."
    return 1
  fi
  echo "${G}${B}Done.${N} Back to Game Mode → launch RDR2 → Story Mode → load a ${B}test save${N} first."
  echo "  enRAGE menu: double-tap ${B}D-pad Right${N} (F11 on a keyboard). Welcome guide shows on first run."
  echo "  Backups: $BACKUP_ROOT/$TS"
}

do_status() {
  [[ "${1:-}" == quiet ]] || { echo; info "${B}Installation check${N}"; discover; }
  local f miss=0
  for f in RDR2.exe "${ROOT_FILES[@]}"; do
    if [[ -f "$GAME_DIR/$f" ]]; then ok "$f"; else bad "$f missing"; miss=1; fi
  done
  for f in "${ENRAGE_FILES[@]}"; do
    if [[ -f "$GAME_DIR/$f" ]]; then ok "$f"; else bad "$f missing"; miss=1; fi
  done
  [[ -d "$GAME_DIR/scripts/scripts" ]] && bad "Nested scripts/scripts/ folder found — run option 1 to fix"
  [[ -d "$GAME_DIR/$DISABLED_NAME" ]] && warn "Mods are currently DISABLED (option 4 re-enables)"
  if [[ -d "$PFX/drive_c" ]]; then
    if dotnet_present; then ok ".NET Framework 4.8 in prefix (release $(dotnet_release))"
    else
      bad ".NET Framework 4.8 not detected in prefix — ScriptHookRDR2DotNet (and so enRAGE) can't run. Use option 8."
      dotnet_files || warn "   runtime files missing (Framework64/v4.0.30319/clr.dll)"
      [[ -n "$(dotnet_release)" ]] || warn "   setup registry key missing"
      local lastlog; lastlog="$(find "$BACKUP_ROOT" -mindepth 2 -maxdepth 2 -name dotnet-install.log -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2-)"
      [[ -n "$lastlog" ]] && warn "   last install log: $lastlog"
    fi
    if winver_bad; then bad "Prefix reports an OLD Windows version — the game will refuse to start. Use option 7."
    else ok "Windows version OK ($(winver_get | sed 's/^$/Proton default/'))"; fi
  fi
  local lo; lo="$(STEAM_ROOT="$STEAM_ROOT" vdf_launch get 2>/dev/null | cut -f2- | head -n1)"
  if [[ "$lo" == *dinput8* ]]; then ok "Launch option: $lo"
  else bad "Launch option missing dinput8 override (current: ${lo:-unknown})"; fi
  local log
  for log in "$GAME_DIR/ScriptHookRDR2.log" "$GAME_DIR/ScriptHookRDRDotNet.log" "$DOCS/enRAGE/startup.log"; do
    if [[ -f "$log" ]]; then
      echo "  ${C}— last lines of $(basename "$log") —${N}"; tail -n 4 "$log" | sed 's/^/      /'
    fi
  done
  [[ -f "$GAME_DIR/ScriptHookRDR2.log" ]] && grep -qi 'unsupported\|version' "$GAME_DIR/ScriptHookRDR2.log" && \
    warn "If the log mentions an unsupported game version: download the latest ScriptHookRDR2 and run option 1 again."
  return $miss
}

do_disable() {
  echo; info "${B}Disabling mods (safe for Red Dead Online)${N}"; discover
  game_running && die "Quit the game first."
  local f n=0
  while IFS= read -r f; do
    [[ -e "$GAME_DIR/$f" ]] || continue
    mkdir -p "$GAME_DIR/$DISABLED_NAME/$(dirname "$f")"
    mv -f "$GAME_DIR/$f" "$GAME_DIR/$DISABLED_NAME/$f" && n=$((n+1))
  done < <(manifest_list)
  ok "Moved $n mod files aside. The launch option is harmless with them gone."
}

do_enable() {
  echo; info "${B}Re-enabling mods${N}"; discover
  [[ -d "$GAME_DIR/$DISABLED_NAME" ]] || { warn "Nothing is disabled."; return 0; }
  local f n=0
  while IFS= read -r -d '' f; do
    local rel="${f#"$GAME_DIR/$DISABLED_NAME"/}"
    mkdir -p "$GAME_DIR/$(dirname "$rel")"; mv -f "$f" "$GAME_DIR/$rel" && n=$((n+1))
  done < <(find "$GAME_DIR/$DISABLED_NAME" -type f -print0)
  find "$GAME_DIR/$DISABLED_NAME" -depth -type d -empty -delete
  ok "Restored $n files."
}

do_uninstall() {
  echo; info "${B}Uninstalling enRAGE + ScriptHook${N}"; discover
  game_running && die "Quit the game first."
  ask "Remove the mod files? (they're moved to $BACKUP_ROOT, not deleted)" || return 0
  local dst="$BACKUP_ROOT/$TS/uninstalled" f
  mkdir -p "$dst"
  [[ -d "$GAME_DIR/$DISABLED_NAME" ]] && do_enable >/dev/null
  while IFS= read -r f; do
    [[ -e "$GAME_DIR/$f" ]] || continue
    mkdir -p "$dst/$(dirname "$f")"; mv -f "$GAME_DIR/$f" "$dst/$f"
  done < <(manifest_list)
  mv -f "$GAME_DIR/$MANIFEST_NAME" "$dst/" 2>/dev/null
  rmdir "$GAME_DIR/scripts" 2>/dev/null
  ok "Mod files moved to $dst"
  if close_steam_for_edit; then
    STEAM_ROOT="$STEAM_ROOT" vdf_launch remove >/dev/null && ok "Launch option removed"
  else warn "Remove  ${OVERRIDE}  from RDR2's launch options yourself."; fi
  ask "Also archive enRAGE's world data (nemeses, wars, history)?" && do_reset noconfirm
}

do_reset() {
  [[ "${1:-}" == noconfirm ]] || { echo; info "${B}Reset enRAGE world data${N}"; discover; }
  if [[ ! -d "$DOCS/enRAGE" ]]; then warn "No enRAGE data folder yet."; return 0; fi
  [[ "${1:-}" == noconfirm ]] || ask "Archive (and so reset) all enRAGE nemeses/wars/history?" || return 0
  mkdir -p "$BACKUP_ROOT/$TS"; mv "$DOCS/enRAGE" "$BACKUP_ROOT/$TS/enRAGE-data"
  ok "World data archived to $BACKUP_ROOT/$TS/enRAGE-data (your normal saves are untouched)"
}

menu() {
  clear 2>/dev/null
  cat <<EOF
${B}  ┌─────────────────────────────────────────────┐
  │   enRAGE for Red Dead Redemption 2 — SteamOS │
  └─────────────────────────────────────────────┘${N}
   1) Full install / repair  ${G}(start here)${N}
   2) Check installation
   3) Disable mods  (before playing Red Dead Online)
   4) Re-enable mods
   5) Uninstall
   6) Reset enRAGE world data
   7) Fix "Windows XP / Vista no longer supported" error
   8) Repair .NET Framework 4.8  (if the check shows it missing)
   q) Quit
EOF
  local c; read -r -p "  Choose: " c
  case "$c" in
    1) do_install ;; 2) do_status ;; 3) do_disable ;; 4) do_enable ;;
    5) do_uninstall ;; 6) do_reset ;;
    7) echo; discover; fix_winver ;;
    8) echo; discover; FORCE_DEPS=1 install_deps; fix_winver ;;
    q|Q) exit 0 ;; *) warn "Pick 1-8 or q" ;;
  esac
  pause_exit 0
}

usage() { awk 'NR>2 && /^# =====/{exit} NR>2{sub(/^#  ?/,""); sub(/^#$/,""); print}' "$0"; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
if [[ $EUID -eq 0 ]]; then
  echo "Don't run this with sudo/root — run it as your normal user (e.g. 'deck')."; exit 1
fi
case "${1:-}" in
  "")        menu ;;
  *)
    NONINTERACTIVE=1
    case "$1" in
      install)   do_install ;;
      status)    do_status ;;
      disable)   do_disable ;;
      enable)    do_enable ;;
      uninstall) do_uninstall ;;
      reset)     do_reset ;;
      fixwin)    discover; fix_winver ;;
      fixnet)    discover; FORCE_DEPS=1 install_deps; fix_winver ;;
      *) echo "Unknown command: $1"; echo; usage; exit 1 ;;
    esac ;;
esac
