#!/bin/bash
# terminal-system/build-deb.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

VERSION="$(grep -oP '^Version:\s*\K.*' build/DEBIAN/control)"
NAME="$(grep -oP '^Package:\s*\K.*' build/DEBIAN/control)"
OUT="${NAME}_${VERSION}_all.deb"
MAN_SRC="$HERE/man/terminal-system.1"
MAN_DST="build/usr/share/man/man1/terminal-system.1.gz"

chmod +x build/usr/bin/terminal-system build/usr/bin/ts-brain
chmod +x build/DEBIAN/postinst build/DEBIAN/postrm

mkdir -p build/usr/share/doc/terminal-system build/usr/share/man/man1
gzip -cn9 "$MAN_SRC" > "$MAN_DST"
rm -f build/usr/share/man/man1/terminal-system.1

find build -type f ! -path 'build/DEBIAN/*' -exec chmod 644 {} \;
find build -type d -exec chmod 755 {} \;
chmod +x build/usr/bin/terminal-system build/usr/bin/ts-brain build/DEBIAN/postinst build/DEBIAN/postrm

installed_size="$(du -sk build/usr | awk '{print $1}')"
sed -i "s/^Installed-Size:.*/Installed-Size: $installed_size/" build/DEBIAN/control
(cd build && find . -type f ! -path './DEBIAN/*' | sort | xargs md5sum | sed 's|^\./||' > DEBIAN/md5sums)

dpkg-deb --build --root-owner-group build "$OUT"
echo "Built: $OUT"
