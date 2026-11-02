#!/bin/zsh
# Builds the iPad and iPhone app (Release) and installs named copies on your devices.
#
#   scripts/install-ios.sh <copy or group>...   build and install those copies
#   scripts/install-ios.sh list                 the copies and whether each device is reachable
#   scripts/install-ios.sh teams                the team IDs of the Apple IDs in this Mac's keychain
#
#   --renew     first delete the saved signing profile of each team involved, so the
#               build gets a new one (a free Personal Team's profile lasts 7 days, and
#               rebuilding reuses a saved profile until it expires)
#   --dry-run   say what would happen, change nothing
#
# The copies are listed in Config/ios-copies.local (see Config/ios-copies.example), or in
# the file named by HEXMOSPHERE_IOS_COPIES. Each copy builds into build/<copy>/.
#
# A device that isn't reachable is skipped, not failed. Exit: 0 all installed, 1 something
# failed or was refused, 2 usage, 3 something skipped. The first build for a new team or
# device may wait on a keychain prompt on the Mac.
set -uo pipefail
repo=${0:A:h:h}
copies_file=${HEXMOSPHERE_IOS_COPIES:-$repo/Config/ios-copies.local}
bundle_prefix=net.tennica.hexmosphere.ios.

usage() { print -u2 "usage: install-ios.sh <copy or group>... [--renew] [--dry-run] | list | teams"; exit 2; }

if [[ ${1:-} == teams ]]; then
    # One line per "Apple Development" certificate: the team ID (the certificate's OU), then whose it is.
    security find-certificate -a -c "Apple Development" -p |
        awk '/BEGIN/{c=""} {c=c $0 "\n"} /END/{cmd="openssl x509 -noout -subject -nameopt multiline"; printf "%s", c | cmd; close(cmd)}' |
        awk -F' = ' '/commonName/{cn=$2} /organizationalUnitName/{print $2 "  " cn}' | sort -u
    exit 0
fi

[[ -f $copies_file ]] || {
    print -u2 "no copies file: $copies_file"
    print -u2 "copy Config/ios-copies.example to Config/ios-copies.local and fill it in"
    exit 2
}

typeset -A device team icon source groups
names=()
while read -r c d t i s g rest; do
    [[ -z $c || $c == \#* ]] && continue
    [[ -n $g && -z $rest && $i == (normal|mirrored) && $s == (any|origin) ]] ||
        { print -u2 "$copies_file: can't read the line for '$c'"; exit 2; }
    names+=$c device[$c]=$d team[$c]=$t icon[$c]=$i source[$c]=$s groups[$c]=$g
done < $copies_file

connected=$(xcrun devicectl list devices 2>/dev/null)
# The UDID of a reachable device, by UDID or by exact name; empty if it isn't reachable.
reachable() {
    local line
    line=$(print -r -- $connected | grep -E "(^$1  | $1 )" | head -1)
    [[ $line == *available* && $line != *unavailable* ]] || return 1
    print -r -- $line | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | head -1
}

if [[ ${1:-} == list ]]; then
    for c in $names; do
        reachable ${device[$c]} > /dev/null && r=reachable || r="not reachable"
        print -r -- "$c: ${device[$c]}, team ${team[$c]}, ${icon[$c]} icon, from ${source[$c]}, groups ${groups[$c]}; $r"
    done
    exit 0
fi

renew=0 dry=0 chosen=()
for arg in $@; do
    case $arg in
        --renew) renew=1 ;;
        --dry-run) dry=1 ;;
        -*) usage ;;
        *)
            if (( ${+device[$arg]} )); then chosen+=$arg; continue; fi
            found=0
            for c in $names; do
                (( ${${(s:,:)groups[$c]}[(Ie)$arg]} )) && { chosen+=$c; found=1; }
            done
            (( found )) || { print -u2 "no copy or group called '$arg' in $copies_file"; exit 2; }
            ;;
    esac
done
chosen=(${(u)chosen})
(( ${#chosen} )) || usage

cd $repo
mkdir -p build  # each copy's log goes to build/<copy>.log before xcodebuild makes the folder
[[ -d Hexmosphere.xcodeproj ]] || { print -u2 "no Hexmosphere.xcodeproj: run 'xcodegen generate' first"; exit 2; }
print "hexmosphere $(git rev-parse --short HEAD)$(git diff --quiet HEAD || print ' (uncommitted changes)')"

# A copy from "origin" only from exactly what's on origin/main.
origin_ok=1 want_origin=0
for c in $chosen; do [[ ${source[$c]} == origin ]] && want_origin=1; done
if (( want_origin )); then
    if ! git fetch -q origin; then
        print "origin copies refused: can't reach origin to check origin/main"; origin_ok=0
    elif [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
        print "origin copies refused: HEAD isn't origin/main ($(git rev-parse --short origin/main))"; origin_ok=0
    elif [[ -n $(git status --porcelain --untracked-files=no) ]]; then
        print "origin copies refused: uncommitted changes"; origin_ok=0
    fi
fi

# Xcode keeps using a saved profile until it expires; deleting it makes the build get a new one.
if (( renew )); then
    teams=()
    for c in $chosen; do teams+=${team[$c]}; done
    for t in ${(u)teams}; do
        for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*(N) \
                 ~/Library/MobileDevice/Provisioning\ Profiles/*(N); do
            [[ $(security cms -D -i $f 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null) == \
               "iOS Team Provisioning Profile: $bundle_prefix$t" ]] || continue
            print "renewing $t's profile"; (( dry )) || rm -f $f
        done
    done
fi

failed=() skipped=()
for c in $chosen; do
    if [[ ${source[$c]} == origin ]] && (( ! origin_ok )); then failed+=$c; continue; fi
    id=$(reachable ${device[$c]}) || { print "== $c: not reachable, skipped"; skipped+=$c; continue; }
    print "== $c"
    iconset=AppIcon; [[ ${icon[$c]} == mirrored ]] && iconset=AppIconMirrored
    (( dry )) && { print "would build with team ${team[$c]} and icon $iconset, and install on $id"; continue; }
    app=build/$c/Build/Products/Release-iphoneos/HexmosphereiOS.app
    if xcodebuild -project Hexmosphere.xcodeproj -scheme HexmosphereiOS -configuration Release \
            -destination "id=$id" -derivedDataPath build/$c -allowProvisioningUpdates \
            DEVELOPMENT_TEAM=${team[$c]} ASSETCATALOG_COMPILER_APPICON_NAME=$iconset build > build/$c.log 2>&1 &&
       xcrun devicectl device install app --device $id $app >> build/$c.log 2>&1; then
        print "installed (log: build/$c.log)"
    else
        grep -E "error:|BUILD FAILED" build/$c.log | head -5
        failed+=$c
    fi
done
(( ${#failed} == 0 )) || { print "failed: $failed"; exit 1; }
(( ${#skipped} == 0 )) || exit 3
