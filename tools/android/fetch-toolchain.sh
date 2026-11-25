#!/usr/bin/env bash
# Fetch a minimal, pinned Android build toolchain WITHOUT the Android SDK / Gradle / Google Maven.
#
# Everything comes from PyPI, npm and GitHub, and every artifact is checksum-pinned:
#   java      - Temurin 25 JRE from the `jdk4py` wheel (PyPI)                    [GPLv2+CE]
#   aapt2     - Android Asset Packaging Tool 2, linux x64, from `aaptjs3` (npm)  [Apache-2.0]
#   android.jar - API 35 framework stubs (Sable/android-platforms, GitHub)        [Apache-2.0]
#   ecj       - Eclipse Java compiler 3.5.1 (Maven artifact mirrored on GitHub)   [EPL-1.0]
#   apksigner - apksigner.jar from Android build-tools 29.0.2 (GitHub mirror)     [Apache-2.0]
#   dx        - built here FROM SOURCE: AOSP platform/dalvik dx (android-4.4.4_r2) plus
#               libcore com.android.dex, compiled with ecj                       [Apache-2.0]
#
# Output: $TOOLCHAIN_DIR (default: <repo>/.cache/android-toolchain)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TC="${TOOLCHAIN_DIR:-$REPO_ROOT/.cache/android-toolchain}"
mkdir -p "$TC"
cd "$TC"

log() { printf '\033[1;34m[toolchain]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[toolchain] %s\033[0m\n' "$*" >&2; exit 1; }

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then TOKEN="$(gh auth token 2>/dev/null || true)"; fi
gh_raw() { # gh_raw <owner/repo> <path> <ref> <out>
  local auth=(); [ -n "$TOKEN" ] && auth=(-H "Authorization: Bearer $TOKEN")
  curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github.raw' \
    "https://api.github.com/repos/$1/contents/$2?ref=$3" -o "$4"
}
gh_blob() { # gh_blob <owner/repo> <blob-sha> <out>   (content-addressed: verified below)
  local auth=(); [ -n "$TOKEN" ] && auth=(-H "Authorization: Bearer $TOKEN")
  curl -fsSL "${auth[@]}" -H 'Accept: application/vnd.github.raw' \
    "https://api.github.com/repos/$1/git/blobs/$2" -o "$3"
}
check_sha256() { # check_sha256 <file> <sha256>
  echo "$2  $1" | sha256sum -c --quiet - || die "checksum mismatch for $1"
}
git_blob_sha() { python3 - "$1" <<'PY'
import hashlib,sys
d=open(sys.argv[1],'rb').read()
print(hashlib.sha1(b'blob %d\0'%len(d)+d).hexdigest())
PY
}

# ---- java (JRE only; no javac needed, ecj compiles) -------------------------------------------
if [ ! -x jre/bin/java ]; then
  log "java: jdk4py 25.0.5.1 (PyPI)"
  curl -fsSL -o jdk4py.whl "https://files.pythonhosted.org/packages/6b/7f/6647eb46d22167085af910f11776630f3027f67447104b857054bfb769b4/jdk4py-25.0.5.1-py3-none-manylinux_2_17_x86_64.whl"
  check_sha256 jdk4py.whl b989b35d24f704cb40b402a82003d131056bf2b9794c33acb84bf42b5ebffd34
  rm -rf jdk4py-x && mkdir jdk4py-x && (cd jdk4py-x && python3 -m zipfile -e ../jdk4py.whl .)
  rm -rf jre && mv jdk4py-x/jdk4py/java-runtime jre && rm -rf jdk4py-x jdk4py.whl
  chmod +x jre/bin/*
fi

# ---- aapt2 -------------------------------------------------------------------------------------
if [ ! -x aapt2 ]; then
  log "aapt2: aaptjs3 2.0.2 (npm)"
  curl -fsSL -o aaptjs3.tgz https://registry.npmjs.org/aaptjs3/-/aaptjs3-2.0.2.tgz
  tar xzf aaptjs3.tgz package/bin/x64/linux/aapt2 -O > aapt2 && rm aaptjs3.tgz
  check_sha256 aapt2 e4dff6060827a3e401bce376e47916f2f93a89602af54973ffd3fdfc2528be3f
  chmod +x aapt2
fi

# ---- android.jar (API 35) ----------------------------------------------------------------------
if [ ! -f android.jar ]; then
  log "android.jar: API 35 (Sable/android-platforms)"
  gh_raw Sable/android-platforms android-35/android.jar 1e98db1a199e8f7f85541af26bfc27019501b132 android.jar
  check_sha256 android.jar 4566663c3876e022b4fa4ced8c8697c4ab1688267f090114fd92d027b32e619b
fi

# ---- ecj 3.5.1 ---------------------------------------------------------------------------------
if [ ! -f ecj.jar ]; then
  log "ecj: 3.5.1"
  gh_raw KHP-Informatics/SDQ jar/.m2/repository/org/eclipse/jdt/core/compiler/ecj/3.5.1/ecj-3.5.1.jar 13be5b4e47f5e4c49ed5e3a7308f2215841091ea ecj.jar
  check_sha256 ecj.jar c37fb3d2b5a5065b9e538378d92ffc1904eb513b73b9e3dffbbbf7d8b7616404
fi

# ---- apksigner (build-tools 29.0.2) ------------------------------------------------------------
if [ ! -f apksigner.jar ]; then
  log "apksigner: build-tools 29.0.2"
  gh_raw warren-bank/print-apk-signature libs/apksigner/apksigner.jar 53b17265313d7c14d98d19042a165c4542b0063c apksigner.jar
  check_sha256 apksigner.jar 4245254627f4b125964a16337ec29247cf77cd2b66afe3343ffeb5f4af9450e3
fi

# ---- dx (built from AOSP source) ---------------------------------------------------------------
if [ ! -f dx.jar ]; then
  log "dx: building from AOSP platform/dalvik android-4.4.4_r2 (commit 0b3df9f1)"
  rm -rf dx-src && mkdir -p dx-src/dalvik dx-src/libdex/com/android/dex/util dx-src/classes
  curl -fsSL https://codeload.github.com/aosp-mirror/platform_dalvik/tar.gz/0b3df9f1574703044279d87f5c55a850cb2c6ce1 \
    | tar xz -C dx-src/dalvik --strip-components=1 --wildcards '*/dx/src/*'
  # libcore/dex (com.android.dex) from the same Android 4.4 era, by git blob id (content-verified)
  DEX_FILES=(
    "Annotation.java e5ef9783b7cbbe805356098bf9c39fcc1ccb2ecb"
    "ClassData.java 840756c5b71f0546bbe7da3bb27c94a002b0d014"
    "ClassDef.java b3225ec0e3b075f7d8e55198044506ff89e19355"
    "Code.java 9258af795f43fbba35c4b32cd598f3af73e5b689"
    "Dex.java 116a33c24dc12f6f0ea76e32db0c8b9887caf822"
    "DexException.java a30a46f7882810b7fe5ed8083c03f4b87cf1d6d7"
    "DexFormat.java 9319bc22ee1dc2067da50f58252bb34bdecd871f"
    "EncodedValue.java 8d0c3adcf6b3d9b9d6465a86c824af187bae0f1f"
    "EncodedValueCodec.java 7fc1724348a2afe680b2a9ed0b328299a853686c"
    "EncodedValueReader.java 6f60538a2f7f2d61d80668967a0d1525a54255e5"
    "FieldId.java 2f41708c826f523fa05323dc2d6235c958d86389"
    "Leb128.java 1a82e383e9fbd3c5f61c8d5826220abd925c950d"
    "MethodId.java e518740265c60e1f86f135f1fed062fe7a43e648"
    "Mutf8.java c64da331b3b4f0b13616c53595219e723fe34736"
    "ProtoId.java 9d9f484f24fe38a3be13adef22de3d3276a11286"
    "SizeOf.java 65fab565b34c0efa0ad5112919e5d555811aef02"
    "TableOfContents.java d1b87ac8fc4b3c99c72e6ff1bbf2986e6da0c62b"
    "TypeList.java 123e82c9ae083796b554b8208c0b6cd824d2f242"
    "util/ByteArrayByteInput.java 889a936c5156d29c2874eed3c58771d53be24985"
    "util/ByteInput.java f1a7196142ff81bd750c81757d6bdf7984c0f916"
    "util/ByteOutput.java eb77040ecb88e9abe464661d521a9b102a087258"
    "util/ExceptionWithContext.java 5dfd9547449e2910f3346b4d94b31c22e89dd831"
    "util/FileUtils.java 4cea95c59ddbd453adb00d704ef396c29e072ac9"
    "util/Unsigned.java cb50d0a40a22ba9ed49a16a9bd74620e6a3b1272"
  )
  for entry in "${DEX_FILES[@]}"; do
    f="${entry% *}"; sha="${entry#* }"; out="dx-src/libdex/com/android/dex/$f"
    gh_blob CyFI-Lab-Public/RetroScope "$sha" "$out"
    [ "$(git_blob_sha "$out")" = "$sha" ] || die "blob mismatch for $f"
  done
  find dx-src/dalvik/dx/src dx-src/libdex -name '*.java' > dx-src/sources.txt
  ./jre/bin/java -jar ecj.jar -source 1.6 -target 1.6 -nowarn -encoding UTF-8 \
    -bootclasspath android.jar -d dx-src/classes @dx-src/sources.txt 2>&1 | grep -v 'Annotation processing got disabled' || true
  [ -f dx-src/classes/com/android/dx/command/Main.class ] || die "dx compilation failed"
  python3 - <<'PY'
import os, zipfile
root = 'dx-src/classes'
with zipfile.ZipFile('dx.jar', 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\nMain-Class: com.android.dx.command.Main\n\n')
    for d, _, files in sorted(os.walk(root)):
        for f in sorted(files):
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, root))
PY
  rm -rf dx-src
fi

log "aapt2:     $(./aapt2 version 2>&1)"
log "dx:        $(./jre/bin/java -jar dx.jar --version 2>&1)"
log "apksigner: $(./jre/bin/java -jar apksigner.jar version 2>&1)"
log "toolchain ready in $TC"
