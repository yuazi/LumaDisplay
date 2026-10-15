#!/bin/zsh
# Move the built app into a launcher-visible location without leaving a second
# runnable copy in dist. Existing installations are archived before replacement.
set -euo pipefail
cd "${0:A:h}/.."
SOURCE_APP="$PWD/dist/LumaDisplay.app"
INSTALL_DIRECTORY="${1:-/Applications}"
INSTALL_DIRECTORY="${INSTALL_DIRECTORY:A}"
INSTALLED_APP="$INSTALL_DIRECTORY/LumaDisplay.app"
BUNDLE_ID="io.github.yuazi.LumaDisplay"
REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || { print -u2 "Run ./Scripts/build-app.sh first."; exit 1; }
[[ "$SOURCE_APP" != "$INSTALLED_APP" ]] || { print -u2 "Choose an Applications folder outside dist."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == "$BUNDLE_ID" ]]
codesign --verify --deep --strict "$SOURCE_APP"
if pgrep -x LumaDisplay >/dev/null; then
    print -u2 "Quit LumaDisplay normally before installing so its display settings are restored."
    exit 1
else
    PROCESS_RESULT=$?
    [[ "$PROCESS_RESULT" == 1 ]] || { print -u2 "Could not check whether LumaDisplay is running."; exit 1; }
fi
mkdir -p "$INSTALL_DIRECTORY"
[[ -w "$INSTALL_DIRECTORY" ]] || { print -u2 "Cannot write to $INSTALL_DIRECTORY. Try ./Scripts/install-app.sh ~/Applications"; exit 1; }
if [[ -e "$INSTALLED_APP" || -L "$INSTALLED_APP" ]]; then
    [[ -d "$INSTALLED_APP" && ! -L "$INSTALLED_APP" ]] || { print -u2 "Destination is not a regular app bundle."; exit 1; }
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] || { print -u2 "Destination belongs to another application."; exit 1; }
    BACKUP_DIRECTORY="$PWD/dist/install-backups"
    mkdir -p "$BACKUP_DIRECTORY"
    BACKUP_ARCHIVE="$BACKUP_DIRECTORY/LumaDisplay-$(date +%Y%m%d-%H%M%S)-$$.zip"
    ditto -c -k --sequesterRsrc --keepParent "$INSTALLED_APP" "$BACKUP_ARCHIVE"
    unzip -tq "$BACKUP_ARCHIVE" >/dev/null
    PREVIOUS_DIRECTORY="$(mktemp -d "$INSTALL_DIRECTORY/.LumaDisplay-previous.XXXXXX")"
    mv "$INSTALLED_APP" "$PREVIOUS_DIRECTORY/LumaDisplay.app"
    if ! mv "$SOURCE_APP" "$INSTALLED_APP"; then
        mv "$PREVIOUS_DIRECTORY/LumaDisplay.app" "$INSTALLED_APP"
        rmdir "$PREVIOUS_DIRECTORY"
        exit 1
    fi
    # A validated ZIP retains the previous app; only this temporary copy is removed.
    rm -rf "$PREVIOUS_DIRECTORY"
    print "Previous installation archived at $BACKUP_ARCHIVE"
else
    mv "$SOURCE_APP" "$INSTALLED_APP"
fi
"$REGISTER" -u "$SOURCE_APP" >/dev/null 2>&1 || true
"$REGISTER" -f "$INSTALLED_APP"
print "Installed $INSTALLED_APP"
