# Maintainer: ArchinstallSuper <maintainers@archinstallsuper.example>
pkgname=archinstallsuper
pkgver=0.11.0
pkgrel=1
pkgdesc="Standalone UEFI installer for Arch Linux — no archinstall dependency"
arch=('x86_64')
url="https://github.com/mashituladi-star/ArchinstallSuper"
license=('MIT')
depends=('bash' 'coreutils' 'util-linux' 'gptfdisk' 'dosfstools' 'e2fsprogs'
         'btrfs-progs' 'xfsprogs' 'cryptsetup' 'arch-install-scripts'
         'systemd-boot' 'python' 'dialog')
optdepends=('iw: Wi-Fi detection'
            'iwctl: Wi-Fi configuration via iwd'
            'mokutil: Secure Boot state detection'
            'reflector: mirror list optimization')
source=("$pkgname-$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
    cd "$pkgname-$pkgver"

    # Installer entrypoint.
    install -Dm755 install.sh "$pkgdir/usr/bin/archinstallsuper"

    # Library modules.
    local libdir="$pkgdir/usr/lib/archinstallsuper"
    install -d "$libdir"
    install -Dm644 lib/*.sh "$libdir/"
    install -Dm644 lib/tui.py "$libdir/"

    # Man pages.
    install -d "$pkgdir/usr/share/man/man8"
    install -Dm644 man/archinstallsuper.8 "$pkgdir/usr/share/man/man8/"
    install -d "$pkgdir/usr/share/man/man1"
    install -Dm644 man/install.1 "$pkgdir/usr/share/man/man1/"

    # Documentation.
    install -d "$pkgdir/usr/share/doc/archinstallsuper"
    install -Dm644 README.md CHANGELOG.md LICENSE "$pkgdir/usr/share/doc/archinstallsuper/"
    install -Dm644 docs/*.md "$pkgdir/usr/share/doc/archinstallsuper/docs/"

    # Example configuration.
    install -d "$pkgdir/usr/share/archinstallsuper/examples"
    install -Dm644 examples/config.example.conf "$pkgdir/usr/share/archinstallsuper/examples/"
}
