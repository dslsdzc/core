# Maintainer: DslsDZC <dslsdzc@example.com>
# Contributor: Core Language Team
pkgname=core
pkgver=0.0.000.0.1
pkgrel=1
pkgdesc="Core Programming Language — a semantic-preserving compiler with formal verification support"
arch=('x86_64')
url="https://github.com/dslsdzc/core"
license=('GPL3')
depends=('glibc' 'python3')
makedepends=('binutils' 'python3')
source=("$pkgname-$pkgver.tar.gz::file://$PWD/../$pkgname-$pkgver.tar.gz")
sha256sums=('SKIP')

build() {
    cd "$srcdir"
    mkdir -p build
    python3 build_selfhost_native.py
}

check() {
    cd "$srcdir"
    python3 tests/bootstrap/test_pipeline.py
}

package() {
    cd "$srcdir"

    # Binary compiler frontend + backend
    install -Dm755 build/corec "$pkgdir/usr/bin/corec"
    install -Dm755 build/corearch "$pkgdir/usr/bin/corearch"

    # Bootstrap compiler (Python CLI tool)
    install -Dm755 tools/corec "$pkgdir/usr/lib/core/tools/corec"
    install -Dm644 -t "$pkgdir/usr/lib/core/bootstrap/corec" \
        bootstrap/corec/__init__.py
    for dir in syntax frontend ir backend utils verifier; do
        install -Dm644 -t "$pkgdir/usr/lib/core/bootstrap/corec/$dir" \
            bootstrap/corec/$dir/*.py
    done

    # Standard library
    install -Dm644 -t "$pkgdir/usr/lib/core/stdlib" src/stdlib/*.cr

    # Runtime
    install -Dm644 -t "$pkgdir/usr/lib/core/runtime" src/runtime/*.cr src/runtime/*.s

    # Compiler source (for reference / self-hosting)
    install -Dm644 -t "$pkgdir/usr/lib/core/src/compiler" src/compiler/*.cr
    install -Dm644 -t "$pkgdir/usr/lib/core/src/compiler/backend" \
        src/compiler/backend/*.cr

    # Build scripts
    install -Dm755 -t "$pkgdir/usr/lib/core" build_selfhost.py build_selfhost_native.py

    # Documentation
    install -Dm644 -t "$pkgdir/usr/share/doc/core" \
        README.md CLAUDE.md LICENSE COPYING
    install -Dm644 -t "$pkgdir/usr/share/doc/core/docs" docs/*.md
    install -Dm644 -t "$pkgdir/usr/share/doc/core/docs/ir-schema" docs/ir-schema/*.md
    install -Dm644 -t "$pkgdir/usr/share/doc/core/grammar" grammar/*.ebnf

    # Test suite
    install -Dm644 -t "$pkgdir/usr/lib/core/tests/bootstrap" tests/bootstrap/*.py
    install -Dm644 -t "$pkgdir/usr/lib/core/tests/selfhost" tests/selfhost/*.py
    install -Dm644 -t "$pkgdir/usr/lib/core/tests/selfhost" tests/selfhost/*.s
    install -Dm644 -t "$pkgdir/usr/lib/core/tests/suite" tests/suite/*.cr

    # Examples
    install -Dm644 -t "$pkgdir/usr/share/doc/core/examples" examples/*.cr 2>/dev/null || true
}
