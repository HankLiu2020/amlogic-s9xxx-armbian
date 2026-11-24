#!/usr/bin/env bash
set -euo pipefail

firmware="$(realpath "$1")"
output="$(realpath "$2")"
kernel=6.18.60
base=Armbian_26.11.0-trunk_trixie_arm64_${kernel}.img.gz
base_url=https://github.com/ophub/amlogic-s9xxx-armbian/releases/download/Armbian_trixie_arm64_server_2026.11
db=build-armbian/armbian-files/common-files/etc/model_database.conf
board_boot=build-armbian/armbian-files/different-files/boocax-c50/bootfs

mkdir -p "$board_boot/dtb/rockchip" "$board_boot/extlinux" build/output/images "$output"
test "$(grep -c ':boocax-c50:' "$db")" -eq 0
printf '\n%s\n' 'r920 :BooCax C50 lab :rk3399 :rk3399-boocax-c50.dtb :NA :NA :u-boot-rockchip.bin :4GB RAM,32GB eMMC :stable/6.18.y :rockchip :rk3399 :extlinux.conf :HankLiu2020 :boocax-c50 :no' >> "$db"

# Keep the bootloader's CPU operating point until board DVFS is verified.
sed '/^[[:space:]]*APPEND[[:space:]]/ s/$/ cpufreq.off=1/' \
    build-armbian/armbian-files/platform-files/rockchip/bootfs/extlinux/extlinux.conf.bak \
    > "$board_boot/extlinux/extlinux.conf.bak"

kernel_dir="$RUNNER_TEMP/linux-${kernel}"
curl -fsSL --retry 3 "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${kernel}.tar.xz" -o "$RUNNER_TEMP/kernel.tar.xz"
tar -xJf "$RUNNER_TEMP/kernel.tar.xz" -C "$RUNNER_TEMP" \
    "linux-${kernel}/arch/arm64/boot/dts/rockchip" "linux-${kernel}/include/dt-bindings" \
    "linux-${kernel}/sound/soc/codecs/"{rt5651.c,rt5651.h,rl6231.c,rl6231.h}
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
images=(build/output/images/*_rockchip_boocax-c50_*.img.gz)
if [[ "${#images[@]}" -ne 1 ]]; then
    echo "Expected one compressed BooCax image in the rebuild output" >&2
    ls -lh build/output/images
    exit 1
fi
compressed="${images[0]}"
image="$RUNNER_TEMP/boocax-verification.img"
pigz -dc "$compressed" > "$image"
parted -ms "$image" unit s print
boot_bytes="$(stat -c %s "$firmware/u-boot-rockchip.bin")"
cmp -n "$boot_bytes" -i 32768:0 "$image" "$firmware/u-boot-rockchip.bin"
echo "Verified $boot_bytes U-Boot bytes at LBA 64"
loop="$(sudo losetup --find --show --partscan "$image")"
boot_mount="$(mktemp -d)"
root_mount="$(mktemp -d)"
cleanup() {
    if mountpoint -q "$root_mount"; then sudo umount "$root_mount"; fi
    if mountpoint -q "$boot_mount"; then sudo umount "$boot_mount"; fi
    sudo losetup -d "$loop"
    rmdir "$boot_mount" "$root_mount"
}
trap cleanup EXIT
sudo mount -o ro "${loop}p1" "$boot_mount"
sudo mount "${loop}p2" "$root_mount"
grep -F 'rk3399-boocax-c50.dtb' "$boot_mount/extlinux/extlinux.conf"
grep -Fw 'cpufreq.off=1' "$boot_mount/extlinux/extlinux.conf"
dtb="$boot_mount/dtb/rockchip/rk3399-boocax-c50.dtb"
cmp "$dtb" "$board_boot/dtb/rockchip/rk3399-boocax-c50.dtb"

test "$(fdtget -t s "$dtb" / model)" = 'BooCax C50 V1.0'
for address in fe300000 fe310000 fe320000 fe330000 ff180000 ff940000 fe380000 fe3e0000; do
    node="$(fdtget -l "$dtb" / | grep "@${address}$")"
    test "$(fdtget -t s "$dtb" "/$node" status)" = 'okay'
    printf '%s enabled\n' "$node"
done
test "$(fdtget -t s "$dtb" /mmc@fe310000/wifi@1 compatible)" = 'brcm,bcm4356-fmac brcm,bcm4329-fmac'
test "$(fdtget -t s "$dtb" /serial@ff180000/bluetooth compatible)" = 'brcm,bcm43438-bt'
test "$(fdtget -t u "$dtb" /ethernet@fe300000/mdio/ethernet-phy@0 reg)" = '0'
test "$(fdtget -t u "$dtb" /ethernet@fe300000/mdio reset-post-delay-us)" = '50000'
test "$(fdtget -t s "$dtb" /gpio-leds/led-red default-state)" = 'on'
test "$(fdtget -t s "$dtb" /gpio-leds/led-green default-state)" = 'off'
test "$(fdtget -t s "$dtb" /i2c@ff110000/audio-codec@1a compatible)" = 'realtek,rt5651'
for address in fe800000 fe900000; do
    test "$(fdtget -t s "$dtb" "/usb@$address" status)" = 'okay'
    test "$(fdtget -t s "$dtb" "/usb@$address/usb@$address" status)" = 'okay'
    test "$(fdtget -t s "$dtb" "/usb@$address/usb@$address" dr_mode)" = 'host'
    printf 'USB3 host at %s enabled\n' "$address"
done
emmc_phy_handle="$(fdtget -t x "$dtb" /mmc@fe330000 phys)"
syscon="$(fdtget -l "$dtb" / | grep '@ff770000$')"
test "$(fdtget -t x "$dtb" "/$syscon/phy@f780" phandle)" = "$emmc_phy_handle"
test "$(fdtget -t s "$dtb" "/$syscon/phy@f780" status)" = 'okay'

configs=("$boot_mount"/config-6.18.60*)
test "${#configs[@]}" -eq 1
config="${configs[0]}"
for option in \
    'CONFIG_DWMAC_ROCKCHIP=y' 'CONFIG_MMC_DW_ROCKCHIP=y' \
    'CONFIG_BRCMFMAC=m' 'CONFIG_BRCMFMAC_SDIO=y' \
    'CONFIG_BT_HCIUART=m' 'CONFIG_BT_HCIUART_BCM=y' \
    'CONFIG_TUN=m'; do
    grep -Fx "$option" "$config"
done
for option in COMMON_CLK_RK808 LEDS_GPIO PHY_ROCKCHIP_EMMC USB_DWC3 \
    USB_DWC3_OF_SIMPLE USB_XHCI_HCD PHY_ROCKCHIP_TYPEC DRM_ROCKCHIP \
    ROCKCHIP_DW_HDMI SND_SOC_ROCKCHIP_I2S SND_SIMPLE_CARD; do
    grep -Ex "CONFIG_$option=[ym]" "$config"
done

if ! grep -Eq '^CONFIG_SND_SOC_RT5651=[ym]$' "$config"; then
    release="${config##*/config-}"
    headers="$root_mount/usr/src/linux-headers-$release"
    test -s "$headers/Module.symvers"
    if grep -Fxq 'CONFIG_MODULE_SIG_FORCE=y' "$config"; then
        echo "The base kernel requires a signed RT5651 module" >&2
        exit 1
    fi
    codec="$kernel_dir/sound/soc/codecs"
    cat > "$codec/Makefile" <<'KBUILD'
obj-m += snd-soc-rt5651.o
snd-soc-rt5651-y := rt5651.o
KBUILD
    if ! grep -Eq '^CONFIG_SND_SOC_RL6231=[ym]$' "$config"; then
        cat >> "$codec/Makefile" <<'KBUILD'
obj-m += snd-soc-rl6231.o
snd-soc-rl6231-y := rl6231.o
KBUILD
    fi
    toolchain=arm-gnu-toolchain-15.3.rel1-aarch64-aarch64-none-linux-gnu
    curl -fsSL --retry 3 "https://github.com/ophub/kernel/releases/download/toolchain/$toolchain.tar.xz" \
        -o "$RUNNER_TEMP/$toolchain.tar.xz"
    echo "8020be7aa1013704756158400cb5ba438d6f09b2909795d13617b9e7bac53286  $RUNNER_TEMP/$toolchain.tar.xz" |
        sha256sum --check
    tar -xJf "$RUNNER_TEMP/$toolchain.tar.xz" -C "$RUNNER_TEMP"
    cross_compile="$RUNNER_TEMP/$toolchain/bin/aarch64-none-linux-gnu-"
    make -C "$headers" M="$codec" CROSS_COMPILE="$cross_compile" ARCH=arm64 -j"$(nproc)" modules
    modinfo -F vermagic "$codec/snd-soc-rt5651.ko" | grep -F "$release "
    modinfo -F alias "$codec/snd-soc-rt5651.ko" | grep -F 'realtek,rt5651'
    sudo install -d "$root_mount/usr/lib/modules/$release/updates/boocax"
    sudo install -m 644 "$codec"/*.ko "$root_mount/usr/lib/modules/$release/updates/boocax/"
    sudo depmod -b "$root_mount" "$release"
    grep -F 'updates/boocax/snd-soc-rt5651.ko:' "$root_mount/usr/lib/modules/$release/modules.dep"
fi

fw="$root_mount/usr/lib/firmware/brcm"
printf '%s\n' \
    "6154b2e7b14e3e4474c7f047cb13f0cb7c3f9d2e8fc1307bb09113250ef3d7cf  $fw/brcmfmac4356-sdio.bin" \
    "d2e459c84e062a60d6db4b618016748a2bc27cfe6bc86c15acf86f63db4fce6f  $fw/brcmfmac4356-sdio.txt" \
    "f1daa6ab28699b72c8e47a34f43c095941c9aa542d0a5f4b55baebc5fd1aae99  $fw/BCM4356A2.hcd" |
    sha256sum --check
root_uuid="$(sudo blkid -s UUID -o value "${loop}p2")"
grep -F "UUID=$root_uuid" "$boot_mount/extlinux/extlinux.conf"
cleanup
trap - EXIT
pigz -c "$image" > "$output/${compressed##*/}"
rm -f "$image"
cd "$output"
sha256sum ./*.img.gz > SHA256SUMS
