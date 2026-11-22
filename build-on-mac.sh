#!/bin/bash
# Builds Jax Reddit Eclipse on this Mac with Theos and puts both .deb files in
# packages/.
#
#   bash build-on-mac.sh
#
# Needs Xcode (or the Command Line Tools) and an internet connection the first
# time. Installs Theos into ~/theos if it isn't there yet; nothing else on the
# Mac is changed and no password is needed. Safe to run again.
# Everything it prints is also saved to build.log next to this script.

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$PROJECT_DIR/build.log"

step() { printf '\n==> %s\n' "$*"; }
fail() {
  printf '\nBUILD FAILED: %s\n' "$*"
  exit 1
}

# Shows the permissions of the tweak's files inside a package, and stops the
# build if Reddit couldn't read one of them once it's installed (see "File
# permissions" below).
check_package() {
  local deb="$1" member files unzip=""
  member="$(ar -t "$deb" 2>/dev/null | grep '^data\.tar' | head -1)"
  case "$member" in
    *.gz) unzip=z ;;
    *.xz) unzip=J ;;
  esac
  if [ -n "$member" ]; then
    files="$(ar -p "$deb" "$member" 2>/dev/null | tar -tv${unzip}f - 2>/dev/null | grep -E 'HideRead\.(dylib|plist)$')"
  fi
  if [ -z "$files" ]; then
    echo "$(basename "$deb"): couldn't look inside it, so its permissions weren't checked."
    return 0
  fi
  echo "$(basename "$deb"):"
  printf '%s\n' "$files" | awk '{ n = split($NF, part, "/"); print "  " $1 "  " part[n] }'
  # Readable by group and others: rw-r--r-- or rwxr-xr-x.
  if printf '%s\n' "$files" | grep -qvE '^.{4}r..r'; then
    fail "a file in $(basename "$deb") can only be read by its owner, so Reddit wouldn't load the tweak."
  fi
}

main() {
  cd "$PROJECT_DIR" || fail "can't open $PROJECT_DIR"
  echo "Jax Reddit Eclipse build, $(date)"
  echo "macOS $(sw_vers -productVersion 2>/dev/null), $(uname -m)"

  step "Checking Xcode"
  DEV_DIR="$(xcode-select -p 2>/dev/null)" ||
    fail "Xcode isn't installed. Install Xcode or run: xcode-select --install"
  case "$DEV_DIR" in
    */CommandLineTools*)
      # The Command Line Tools are selected. If the full Xcode app is installed,
      # use its newer compiler instead (without changing the Mac's setting).
      XCODE_APP=""
      if [ -d /Applications/Xcode.app/Contents/Developer ]; then
        XCODE_APP=/Applications/Xcode.app
      else
        XCODE_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
      fi
      if [ -n "$XCODE_APP" ] && [ -d "$XCODE_APP/Contents/Developer" ]; then
        DEV_DIR="$XCODE_APP/Contents/Developer"
        echo "The Command Line Tools are selected, but Xcode is installed, so this uses Xcode."
      fi
      ;;
  esac
  export DEVELOPER_DIR="$DEV_DIR"
  echo "Developer folder: $DEV_DIR"
  CLANG="$(xcrun -f clang 2>/dev/null)" ||
    fail "Xcode's compiler isn't usable. If Xcode asks you to accept its license, open Xcode once."
  CLANG_VERSION="$("$CLANG" --version 2>/dev/null | head -1)"
  echo "Compiler: $CLANG_VERSION"
  CLANG_MAJOR="$(echo "$CLANG_VERSION" | sed -n 's/.*clang version \([0-9][0-9]*\).*/\1/p')"
  if [ -n "$CLANG_MAJOR" ] && [ "$CLANG_MAJOR" -lt 13 ]; then
    fail "this compiler is too old for the iOS SDK. Update Xcode, or the Command Line Tools in System Settings > General > Software Update."
  fi

  export THEOS="${THEOS:-$HOME/theos}"
  step "Theos ($THEOS)"
  if [ -f "$THEOS/makefiles/common.mk" ]; then
    echo "Already installed."
  else
    command -v git >/dev/null 2>&1 || fail "git isn't available (it comes with Xcode)."
    git clone --recursive --depth 1 --shallow-submodules https://github.com/theos/theos.git "$THEOS" ||
      fail "couldn't download Theos from GitHub."
  fi

  EXTRA=()

  step "iOS SDK"
  if xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    echo "Using Xcode's iOS $(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null) SDK."
  else
    echo "Xcode has no iOS SDK installed, so this uses Theos' iOS 16.5 SDK instead."
    if ! ls -d "$THEOS"/sdks/iPhoneOS*.sdk >/dev/null 2>&1; then
      echo "Downloading it (about 80 MB)..."
      "$THEOS/bin/install-sdk" iPhoneOS16.5 >"$PROJECT_DIR/.sdk-download.log" 2>&1 || {
        tail -20 "$PROJECT_DIR/.sdk-download.log"
        fail "couldn't download the iOS SDK."
      }
    fi
    # Without an iOS SDK in Xcode, xcrun can't look up the tools for iOS, so
    # point Theos at them directly. They're the same tools for every platform.
    EXTRA+=(
      "TARGET_CC=$CLANG" "TARGET_CXX=$(xcrun -f clang++)" "TARGET_LD=$CLANG"
      "TARGET_STRIP=$(xcrun -f strip)" "TARGET_LIPO=$(xcrun -f lipo)"
      "TARGET_LIBTOOL=$(xcrun -f libtool)" "TARGET_CODESIGN_ALLOCATE=$(xcrun -f codesign_allocate)"
    )
  fi

  step "Code signing"
  if command -v ldid >/dev/null 2>&1 && ldid 2>&1 | grep -qi usage; then
    echo "Using ldid."
  else
    if command -v ldid >/dev/null 2>&1; then
      echo "The installed ldid doesn't run (a library it needs is missing; 'brew reinstall ldid' fixes it)."
    else
      echo "ldid isn't installed."
    fi
    echo "Signing with Apple's codesign (ad-hoc) instead."
    EXTRA+=("TARGET_CODESIGN=codesign" "TARGET_CODESIGN_FLAGS=--force --sign -")
  fi

  step "File permissions"
  # Reddit runs as the mobile user, and the tweak loader inside it reads
  # HideRead.plist to know the tweak is for Reddit. The package installs that
  # file owned by root with the permissions it has here, so it has to be
  # readable by everyone (rw-r--r--), or Reddit never loads the tweak.
  umask 022
  chmod 644 HideRead.plist || fail "couldn't make HideRead.plist readable."
  echo "HideRead.plist: $(stat -f %Sp HideRead.plist 2>/dev/null)"

  # Only this build's packages should end up in packages/.
  rm -f "$PROJECT_DIR"/packages/*.deb

  for scheme in rootless rootful; do
    step "Building the $scheme package"
    if [ "$scheme" = rootful ]; then rootful=1; else rootful=0; fi
    make clean >/dev/null 2>&1
    # gzip needs no extra tools on macOS; GO_EASY_ON_ME keeps a newer compiler's
    # warnings from stopping the build (they still show up in this log).
    make package FINALPACKAGE=1 ROOTFUL=$rootful GO_EASY_ON_ME=1 \
      THEOS_PLATFORM_SDK_ROOT="$DEV_DIR" THEOS_PLATFORM_DEB_COMPRESSION_TYPE=gzip "${EXTRA[@]}" ||
      fail "the $scheme build failed (see the messages above)."
  done

  step "Checking the packages"
  for deb in "$PROJECT_DIR"/packages/*.deb; do
    check_package "$deb"
  done

  step "BUILD SUCCEEDED"
  ls -1 "$PROJECT_DIR"/packages/*.deb
  echo
  echo "Dopamine or palera1n (rootless):      the file ending in _iphoneos-arm64.deb"
  echo "unc0ver, checkra1n, Taurine (rootful): the file ending in _iphoneos-arm.deb"
  open "$PROJECT_DIR/packages" 2>/dev/null
}

main "$@" 2>&1 | tee "$LOG"
exit "${PIPESTATUS[0]}"
