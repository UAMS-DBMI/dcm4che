#!/usr/bin/env bash
#
# package-dcm2jpg.sh — build a minimal, standalone distribution of the dcm2jpg tool.
#
# Instead of hardcoding the jar list, this reads the classpath straight out of the
# launcher that the assembly build generates (dcm4che-assembly/.../bin/dcm2jpg), so
# version bumps and new/removed dependencies are picked up automatically.
#
# Usage:
#   ./package-dcm2jpg.sh [-b] [-p PLATFORM] [-o OUTDIR]
#
#   -b            Rebuild dcm2jpg + assembly via Maven before packaging
#                 (./mvnw package -DskipTests -pl dcm4che-assembly -am).
#                 Omit if you've already built and only want to re-pack.
#   -p PLATFORM   Target native-lib platform dir under lib/ (default: linux-x86-64).
#                 e.g. linux-x86-64, linux-aarch64, macosx-aarch64, windows-x86-64
#   -o OUTDIR     Output directory for the package + tarball (default: ./dist)
#   -h            Show this help.
#
# The resulting package needs only a Java 17+ runtime on the target machine.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLATFORM="linux-x86-64"
OUTDIR="$REPO_DIR/dist"
DO_BUILD=0

usage() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | head -n -1; exit "${1:-0}"; }

while getopts ":bp:o:h" opt; do
  case "$opt" in
    b) DO_BUILD=1 ;;
    p) PLATFORM="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    h) usage 0 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage 1 ;;
  esac
done

cd "$REPO_DIR"

if [[ "$DO_BUILD" -eq 1 ]]; then
  echo ">> Rebuilding dcm2jpg + assembly (this also rebuilds upstream modules)..."
  ./mvnw package -DskipTests -pl dcm4che-assembly -am
fi

# Locate the freshly built distribution that the assembly produced.
DIST_ROOT="$(find "$REPO_DIR/dcm4che-assembly/target" -maxdepth 2 -type d -name 'dcm4che-*' \
             -path '*-bin/dcm4che-*' 2>/dev/null | sort | tail -1)"
if [[ -z "$DIST_ROOT" || ! -d "$DIST_ROOT" ]]; then
  echo "ERROR: built distribution not found under dcm4che-assembly/target." >&2
  echo "       Run with -b to build it first." >&2
  exit 1
fi

VERSION="$(basename "$DIST_ROOT" | sed 's/^dcm4che-//')"
LAUNCHER="$DIST_ROOT/bin/dcm2jpg"
[[ -f "$LAUNCHER" ]] || { echo "ERROR: launcher not found: $LAUNCHER" >&2; exit 1; }

NATIVE_DIR="$DIST_ROOT/lib/$PLATFORM"
[[ -d "$NATIVE_DIR" ]] || {
  echo "ERROR: native lib dir for platform '$PLATFORM' not found: $NATIVE_DIR" >&2
  echo "       Available platforms:" >&2
  find "$DIST_ROOT/lib" -maxdepth 1 -mindepth 1 -type d -printf '         %f\n' >&2
  exit 1
}

echo ">> Packaging dcm2jpg $VERSION for $PLATFORM"

# Derive the jar list from the launcher's classpath:
#   - the main jar is assigned to MAIN_JAR=...
#   - every dependency appears as .../lib/<name>.jar on the CP lines
MAIN_JAR="$(grep -E '^MAIN_JAR=' "$LAUNCHER" | head -1 | cut -d= -f2)"
mapfile -t JARS < <(
  { echo "$MAIN_JAR"; grep -oE 'lib/[A-Za-z0-9._+-]+\.jar' "$LAUNCHER" | sed 's#lib/##'; } | sort -u
)
[[ "${#JARS[@]}" -gt 0 ]] || { echo "ERROR: could not parse any jars from launcher." >&2; exit 1; }

PKG_NAME="dcm2jpg-$VERSION-$PLATFORM"
PKG_DIR="$OUTDIR/$PKG_NAME"
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/etc/dcm2jpg" "$PKG_DIR/lib/$PLATFORM"

# Launcher + logging config.
cp "$LAUNCHER" "$PKG_DIR/bin/dcm2jpg"
chmod +x "$PKG_DIR/bin/dcm2jpg"
if [[ -f "$DIST_ROOT/etc/dcm2jpg/logback.xml" ]]; then
  cp "$DIST_ROOT/etc/dcm2jpg/logback.xml" "$PKG_DIR/etc/dcm2jpg/"
fi

# Jars.
for jar in "${JARS[@]}"; do
  if [[ ! -f "$DIST_ROOT/lib/$jar" ]]; then
    echo "ERROR: jar referenced by launcher is missing: lib/$jar" >&2
    exit 1
  fi
  cp "$DIST_ROOT/lib/$jar" "$PKG_DIR/lib/"
done

# Native libs for the chosen platform (opencv + any JAI native accel present).
cp -a "$NATIVE_DIR/." "$PKG_DIR/lib/$PLATFORM/"

echo ">> Copied ${#JARS[@]} jars + native libs for $PLATFORM"

# Smoke test: only meaningful when packaging for the host platform (native lib must load).
if "$PKG_DIR/bin/dcm2jpg" -h >/dev/null 2>&1; then
  echo ">> Smoke test passed (dcm2jpg -h ran cleanly)"
else
  echo ">> NOTE: smoke test skipped/failed — expected when packaging for a non-host platform."
fi

# Tarball.
TARBALL="$OUTDIR/$PKG_NAME.tar.gz"
rm -f "$TARBALL"
tar czf "$TARBALL" -C "$OUTDIR" "$PKG_NAME"

echo ""
echo "Done."
echo "  package:  $PKG_DIR"
echo "  tarball:  $TARBALL ($(du -h "$TARBALL" | cut -f1))"
echo ""
echo "Deploy: untar on the target (needs Java 17+) and run bin/dcm2jpg <in.dcm> <out.jpg>"
