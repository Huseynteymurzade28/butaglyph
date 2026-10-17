# AUR packages

`butaglyph` builds from the release's source tarball; `butaglyph-bin`
installs the prebuilt Linux binary. They are published at
https://aur.archlinux.org/packages/butaglyph and
https://aur.archlinux.org/packages/butaglyph-bin.

For a new release `vX.Y.Z` (after the release workflow has finished):

```sh
cd packaging/aur/butaglyph        # then the same in butaglyph-bin
sed -i 's/^pkgver=.*/pkgver=X.Y.Z/; s/^pkgrel=.*/pkgrel=1/' PKGBUILD
updpkgsums && makepkg -f          # new checksums, and a test build
makepkg --printsrcinfo > .SRCINFO
# copy PKGBUILD and .SRCINFO into a clone of ssh://aur@aur.archlinux.org/<name>.git,
# commit and push to master
```
