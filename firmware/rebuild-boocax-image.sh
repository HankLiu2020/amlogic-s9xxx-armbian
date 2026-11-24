#!/usr/bin/env bash
set -euo pipefail

firmware="$(realpath "$1")"
output="$(realpath "$2")"
kernel=6.18.60
base=Armbian_26.11.0-trunk_trixie_arm64_${kernel}.img.gz
base_url=https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.11
db=build-armbian/armbian-files/common-files/etc/model_database.conf
board_boot=build-armbian/armbian-files/different-files/boocax-c50/bootfs

mkdir -p "$board_boot/dtb/rockchip" build/output/images "$output"
test "$(grep -c ':boocax-c50:' "$db")" -eq 0
printf '\n%s\n' 'r920 :BooCax C50 lab :rk3399 :rk3399-boocax-c50.dtb :NA :NA :u-boot-rockchip.bin :4GB RAM,32GB eMMC :stable/6.18.y :rockchip :rk3399 :extlinux.conf :HankLiu2020 :boocax-c50 :no' >> "$db"

kernel_dir="$RUNNER_TEMP/linux-${kernel}"
curl -fsSL --retry 3 "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel}.tar.xz" -o "$RUNNER_TEMP/kernel.tar.xz"
tar -xJf "$RUNNER_TEMP/kernel.tar.xz" -C "$RUNNER_TEMP" \
    "linux-${kernel}/arch/arm64/boot/dts/rockchip" "linux-${kernel}/include/dt-bindings"
rm -f "$RUNNER_TEMP/kernel.tar.xz"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp \
    -I "$kernel_dir/include" -I "$kernel_dir/arch/arm64/boot/dts/rockchip" \
    -I "$firmware" firmware/rk3399-boocax-c50-linux.dts "$RUNNER_TEMP/boocax.dts"
dtc -I dts -O dtb -o "$board_boot/dtb/rockchip/rk3399-boocax-c50.dtb" "$RUNNER_TEMP/boocax.dts"
test "$(fdtget "$board_boot/dtb/rockchip/rk3399-boocax-c50.dtb" / model)" = 'BooCax C50 V1.0'

install -D "$firmware/u-boot-rockchip.bin" build-armbian/u-boot/rockchip/boocax-c50/u-boot-rockchip.bin
curl -fsSL --retry 3 "$base_url/$base" -o "build/output/images/$base"
echo "9ef973264f74ca0804f8bdf941f450741394cb251da484d4f3d2355145dbd24d  build/output/images/$base" | sha256sum --check
gzip -d "build/output/images/$base"
sudo ./rebuild -b boocax-c50 -r ophub/kernel -u stable -k "$kernel" -a false -s 3000
shopt -s nullglob
images=(build/output/images/*_rockchip_boocax-c50_*.img)
test "${#images[@]}" -eq 1
image="${images[0]}"
boot_bytes="$(stat -c %s "$firmware/u-boot-rockchip.bin")"
cmp -n "$boot_bytes" -i 32768:0 "$image" "$firmware/u-boot-rockchip.bin"
loop="$(sudo losetup --find --show --partscan --read-only "$image")"
boot_mount="$(mktemp -d)"
cleanup() {
    if mountpoint -q "$boot_mount"; then sudo umount "$boot_mount"; fi
    sudo losetup -d "$loop"
    rmdir "$boot_mount"
}
trap cleanup EXIT
sudo mount -o ro "${loop}p1" "$boot_mount"
grep -F 'rk3399-boocax-c50.dtb' "$boot_mount/extlinux/extlinux.conf"
test -s "$boot_mount/dtb/rockchip/rk3399-boocax-c50.dtb"
test "$(fdtget "$boot_mount/dtb/rockchip/rk3399-boocax-c50.dtb" / model)" = 'BooCax C50 V1.0'
root_uuid="$(sudo blkid -s UUID -o value "${loop}p2")"
grep -F "UUID=$root_uuid" "$boot_mount/extlinux/extlinux.conf"
sudo umount "$boot_mount"
sudo losetup -d "$loop"
rmdir "$boot_mount"
trap - EXIT
pigz -c "$image" > "$output/${image##*/}.gz"
cd "$output"
sha256sum ./*.img.gz > SHA256SUMS
