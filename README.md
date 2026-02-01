# zfont — an tool to donwload nerd fonts in termux
# Usage
```console
~$ zfont donwload 0xProto 3270
nfo: fetching https://github.com/ryanoasis/nerd-fonts/releases/latest/download/0xProto.zip...
info: saving font 0xProto at /home/typer/.termux/fonts/0xProto.ttf
~$ zfont list
0xProto
3270
~$ zfont set 0xProto
info: copying font file at /home/typer/.termux/fonts/0xProto.ttf to /home/typer/.termux/font.ttf
```
# Building
an zig 15.x compiler is required, and you have some options to build because zig is currentely unstable on termux:
- termux-chroot
- proot-distro
the easiest one is using termux-chroot:
```console
git clone https://github.com/cesarcarlosteixeira/zfont
cd zfont
termux-chroot
zig build -Doptimize=ReleaseSmall
cd zig-out/bin/ #you now have a binary here
cp zfont $PREFIX/bin/ # add to path
exit # leave termux-chroot
```
if you have proot-distro then you just need to eun zig build without termux-chroot.

# Prebuilt execitable
the executable is expected to work
