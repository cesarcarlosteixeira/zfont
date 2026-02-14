# zfont — an tool to download nerd fonts in termux
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
# Prebuilt executable
the release executable is expected to work on most aarch64 devices, if it doesn't work to you, the recommendation is to build from source.

# Building
an zig 15.x compiler is required, and you have some options to build because zig is currently unstable on termux:
- termux-chroot
- proot-distro
the easiest option is using termux-chroot:
```console
git clone https://github.com/cesarcarlosteixeira/zfont
cd zfont
zig build -Doptimize=ReleaseSmall
cd zig-out/bin/ # you now have a binary here
cp zfont $PREFIX/bin/ # add to path
exit # leave termux-chroot
```
if you have proot-distro then you just need to run zig build without termux-chroot:
```console
proot-distro login <distro> --user <user>
git clone https://github.com/cesarcarlosteixeira/zfont
cd zfont
zig build -Doptimize=ReleaseSmall
cd zig-out/bin/
cp zfont $PREFIX/bin/
exit # leave proot-distro
```
