#!/bin/bash

## License: BSD 3
## It can reinstall debian vm to archlinux.
## New archlinux root password: changeme123
## Written By https://github.com/tanbi-org


set -Eeuo pipefail
set +h

boot='/i2a'
distro='alpine'
release='edge'
waitme=false
dhcp=false
arch=$(uname -m)
kernel='linux'
reflector=false
base_packages='grub openssh sudo irqbalance haveged sudo btrfs-progs'
extra_packages='wget curl vim bash-completion screen'
mirror='https://mirrors.kernel.org/archlinux'
nameserver="nameserver 8.8.8.8\nnameserver 2606:4700:4700::1111"
uefi=$([ -d /sys/firmware/efi ] && echo true || echo false)
disk="/dev/$(lsblk -no PKNAME "$(df /boot | grep -Eo '/dev/[a-z0-9]+')")"
interface=$(ls /sys/class/net | grep -v lo)
ip_mac=$(ip link show "${interface}" | awk '/link\/ether/{print $2}')
ip4_gw=$(ip route show dev "${interface}" | awk '/default/{print $3}' | head -n 1)
ip6_gw=$(ip -6 route show dev "${interface}" | awk '/default/{print $3}' | head -n 1)
ip4_addr=$(ip -o -4 addr show dev "${interface}" | awk '{print $4}' | head -n 1)
ip6_addr=$(ip -o -6 addr show dev "${interface}" | awk '{print $4}' | head -n 1)
#password=$(openssl rand -base64 12)
password='changeme123'
case $(uname -m) in aarch64|arm64) machine="arm64";;x86_64|amd64) machine="amd64";; *) machine="";; esac

function log() {
	local _on=$'\e[0;32m'
	local _off=$'\e[0m'
    local _date=$(date +"%Y-%m-%d %H:%M:%S")
	echo "${_on}[${_date}]${_off} $@" >&2;
}

function fatal() {
	log "$@";log "Exiting."
	exit 1
}

function setup_network(){
	log '[*] Generate systemd-network ...'
	if [ "$dhcp" = "true" ]; then
		cat > ${boot}/default.network <<EOF
[Match]
Name=en* eth*

[Network]
DHCP=yes

[DHCP]
UseMTU=yes
UseDNS=yes
UseDomains=yes
EOF
	else
		cat > ${boot}/default.network <<EOF
[Match]
Name=en* eth*

[Network]
Address=${ip4_addr}
Gateway=${ip4_gw}
DNS=1.1.1.1

[Route]
Gateway=${ip4_gw}
GatewayOnLink=yes

[Match]
Name=en* eth*

[Network]
IPv6AcceptRA=0
Address=${ip6_addr}
DNS=2606:4700:4700::1111

[Route]
Gateway=${ip6_gw}
GatewayOnLink=yes
EOF
	fi
}

function download_and_extract_rootfs(){
	
	log "[*] Creating workspace in ${boot} ..."
	mkdir -p ${boot}
	
	log "[*] Mounting temporary rootfs..."
	mount -t tmpfs  -o size=100%  mid ${boot}
	  
	log "[*] Downloading temporary rootfs..."
	local mirror='https://images.linuxcontainers.org'
	local response=$(wget -qO- --show-progress "${mirror}/images/${distro}/${release}/${machine}/default/?C=M;O=D")
	local build_time=$(echo "$response" | grep -oP '(\d{8}_\d{2}:\d{2})' | tail -n 1)
		
	local link="${mirror}/images/${distro}/${release}/${machine}/default/${build_time}/rootfs.tar.xz"
	wget --continue -q --show-progress -O ${boot}/rootfs.tar.xz "${link}"
	
	log "[*] Extract temporary rootfs..."	
	xz -dc ${boot}/rootfs.tar.xz | tar -xf - --directory=${boot} --strip-components=1
	rm -rf ${boot}/rootfs.tar.xz
	log "[*] Extract temporary rootfs done..."	
}

function configure_rootfs_dependencies(){
	
	log "[*] Setting resolv config into rootfs..."
	echo -e "${nameserver}" > ${boot}/etc/resolv.conf
	
	log "[*] Loading kernel modules into rootfs..."	
	apt update && apt install dosfstools btrfs-progs -y && modprobe btrfs vfat
	
	log "[*] Installing dropbear and depends into rootfs..."
	chroot ${boot} apk update
	chroot ${boot} apk add bash dropbear arch-install-scripts zstd sgdisk dosfstools btrfs-progs eudev
	chroot ${boot} mkdir -p /etc/dropbear
	chroot ${boot} dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
	chroot ${boot} bash -c 'echo "DROPBEAR_PORT=22" >> /etc/conf.d/dropbear'
	chroot ${boot} bash -c 'echo "DROPBEAR_EXTRA_ARGS=\"-w -K 5\"" >> /etc/conf.d/dropbear'
	chroot ${boot} rc-update add dropbear
	
    log "[*] Generated password for root..."
	chroot ${boot} bash  -c "echo 'root:${password}' | chpasswd"
	
}

function cleanup(){
	if mountpoint -q ${boot}; then
		umount -d ${boot}
	fi
	rm -rf --one-file-system ${boot}
	#fuser -kvm ${boot} -15 > /dev/null 2>&1
}
trap cleanup ERR

function switch_to_rootfs(){

	log "[*] Swapping rootfs..."
	trap cleanup EXIT
	
	setup_network
	
	cat > ${boot}/init <<EOF
#!/bin/bash
export PATH="\$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

uefi=${uefi}
disk=${disk}
arch=${arch}
waitme=${waitme}
mirror=${mirror}
password=${password}
reflector=${reflector}
interface=${interface}
ip_mac=${ip_mac}
ip4_gw=${ip4_gw}
ip6_gw=${ip6_gw}
ip4_addr=${ip4_addr}
ip6_addr=${ip6_addr}

function mid_exit() { echo "[*] Reinstall Error! Force reboot by \"echo b > /proc/sysrq-trigger\". "; exec /bin/sh; }
exec </dev/tty0 && exec >/dev/tty0 && exec 2>/dev/tty0
trap mid_exit EXIT

sysctl -w kernel.sysrq=1 >/dev/null
echo i > /proc/sysrq-trigger

# Reset network
ip addr flush dev ${interface} 2>/dev/null
ip addr add ${ip4_addr} dev ${interface} 2>/dev/null
ip route add default via ${ip4_gw} dev ${interface} onlink 2>/dev/null
ip -6 addr flush dev ${interface} 2>/dev/null
ip -6 addr add ${ip6_addr} dev ${interface} 2>/dev/null
ip -6 route add default via ${ip6_gw} dev ${interface} onlink 2>/dev/nul
ping -c 2 8.8.8.8

/usr/sbin/dropbear

sgdisk -g \
    --align-end \
    --clear \
    --new 0:0:+1M --typecode=0:ef02 --change-name=0:'BIOS boot partition' \
    --new 0:0:+100M --typecode=0:ef00 --change-name=0:'EFI system partition' \
    --new 0:0:0 --typecode=0:8304 --change-name=0:'Arch Linux root' \
${disk}

# Check if the disk is nvme
[[ \$disk == /dev/nvme* ]] && disk="\${disk}p"

# format disk and mount root
mkfs.vfat -F 32 \${disk}2
mkfs.btrfs -f -L ArchRoot  \${disk}3
udevadm settle
mount -o compress-force=zstd,autodefrag,noatime \${disk}3 /mnt

# download bootstrap
wget -q -O - "${mirror}/iso/latest/archlinux-bootstrap-${arch}.tar.zst" | zstd -d | tar -xf - --directory=/mnt --strip-components=1

# mount more need 
mkdir -p /mnt/boot/efi
mount \${disk}2 /mnt/boot/efi

mount -t proc proc /mnt/proc
mount -t sysfs sys /mnt/sys
mount -t devtmpfs dev /mnt/dev
mkdir -p /mnt/dev/pts
mount -t devpts pts /mnt/dev/pts
	
# configure network
mv /default.network /mnt/etc/systemd/network/default.network
cp /etc/resolv.conf /mnt/etc/resolv.conf


# configure pacman
sed -i 's|#Color|Color|' /mnt/etc/pacman.conf
sed -i 's|#ParallelDownloads|ParallelDownloads|' /mnt/etc/pacman.conf
echo 'Server = https://mirrors.edge.kernel.org/archlinux/\$repo/os/\$arch' >> /mnt/etc/pacman.d/mirrorlist
echo "Server = ${mirror}/\$repo/os/\$arch" >> /mnt/etc/pacman.d/mirrorlist

# install archlinux
chroot /mnt pacman-key --init
chroot /mnt pacman-key --populate archlinux
chroot /mnt pacman --disable-sandbox -Sy
chroot /mnt pacman --disable-sandbox --needed --noconfirm -Su archlinux-keyring
chroot /mnt pacman --disable-sandbox --needed --noconfirm -Su $kernel $base_packages $extra_packages

if [ "\$reflector" = "true" ]; then
	echo '[*] Looking for fast mirror by reflector..."'
	chroot /mnt pacman --disable-sandbox -S --noconfirm reflector
	chroot /mnt reflector -l 30 -p https --sort rate --save /etc/pacman.d/mirrorlist
fi

# configure account allow root password login
chroot /mnt ssh-keygen -t ed25519 -f /etc/ssh/ed25519_key -N ""
chroot /mnt ssh-keygen -t rsa -b 4096 -f /etc/ssh/rsa_key -N ""
  
chroot /mnt /bin/bash -c "echo 'IyEvYmluL2Jhc2gKCmNhdCA+IC9ldGMvc3NoL3NzaGRfY29uZmlnIDw8ICJFT0YiCkluY2x1ZGUgL2V0Yy9zc2gvc3NoZF9jb25maWcuZC8qLmNvbmYKUG9ydCAgMjIKUGVybWl0Um9vdExvZ2luIHllcwpQYXNzd29yZEF1dGhlbnRpY2F0aW9uIHllcwpQdWJrZXlBdXRoZW50aWNhdGlvbiB5ZXMKQ2hhbGxlbmdlUmVzcG9uc2VBdXRoZW50aWNhdGlvbiBubwpLYmRJbnRlcmFjdGl2ZUF1dGhlbnRpY2F0aW9uIG5vCkF1dGhvcml6ZWRLZXlzRmlsZSAgL3Jvb3QvLnNzaC9hdXRob3JpemVkX2tleXMKU3Vic3lzdGVtICAgICBzZnRwICAgIC91c3IvbGliL3NzaC9zZnRwLXNlcnZlcgpYMTFGb3J3YXJkaW5nIG5vCkFsbG93VXNlcnMgcm9vdApQcmludE1vdGQgbm8KQWNjZXB0RW52IExBTkcgTENfKgpFT0YK' | base64 -d | bash"

echo "root:${password}" |  chroot /mnt chpasswd

# configure locale
sed -i 's/^#en_US/en_US/' /mnt/etc/locale.gen
echo 'LANG=en_US.utf8' > /mnt/etc/locale.conf
chroot /mnt locale-gen
chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime

# configure systemd
chroot /mnt ln -sf /usr/lib/systemd/system/multi-user.target /etc/systemd/system/default.target
chroot /mnt systemctl enable systemd-timesyncd.service
chroot /mnt systemctl enable haveged.service
chroot /mnt systemctl enable irqbalance.service
chroot /mnt systemctl enable systemd-networkd.service
chroot /mnt systemctl enable systemd-resolved.service
chroot /mnt systemctl enable sshd.service

# configure system
chroot /mnt /bin/bash -c "echo 'IyEvYmluL2Jhc2gKY2F0ID4gL3Jvb3QvLnByb2ZpbGUgPDxFT0YKZXhwb3J0IFBTMT0nXFtcZVswOzMybVxdXHVAXGggXFtcZVswOzM0bVxdXHdcW1xlWzA7MzZtXF1cblwkIFxbXGVbMG1cXScKYWxpYXMgZ2V0aXA9J2N1cmwgLS1jb25uZWN0LXRpbWVvdXQgMyAtTHMgaHR0cHM6Ly9pcHY0LWFwaS5zcGVlZHRlc3QubmV0L2dldGlwJwphbGlhcyBnZXRpcDY9J2N1cmwgLS1jb25uZWN0LXRpbWVvdXQgMyAtTHMgaHR0cHM6Ly9pcHY2LWFwaS5zcGVlZHRlc3QubmV0L2dldGlwJwphbGlhcyBuZXRjaGVjaz0ncGluZyAxLjEuMS4xJwphbGlhcyBscz0nbHMgLS1jb2xvcj1hdXRvJwphbGlhcyBncmVwPSdncmVwIC0tY29sb3I9YXV0bycgCmFsaWFzIGZncmVwPSdmZ3JlcCAtLWNvbG9yPWF1dG8nCmFsaWFzIGVncmVwPSdlZ3JlcCAtLWNvbG9yPWF1dG8nCmFsaWFzIHJtPSdybSAtaScKYWxpYXMgY3A9J2NwIC1pJwphbGlhcyBtdj0nbXYgLWknCmFsaWFzIGxsPSdscyAtbGgnCmFsaWFzIGxhPSdscyAtbEFoJwphbGlhcyAuLj0nY2QgLi4vJwphbGlhcyAuLi49J2NkIC4uLy4uLycKYWxpYXMgcGc9J3BzIGF1eCB8Z3JlcCAtaScKYWxpYXMgaGc9J2hpc3RvcnkgfGdyZXAgLWknCmFsaWFzIGxnPSdscyAtQSB8Z3JlcCAtaScKYWxpYXMgZGY9J2RmIC1UaCcKYWxpYXMgZnJlZT0nZnJlZSAtaCcKZXhwb3J0IEhJU1RUSU1FRk9STUFUPSIlRiAlVCBcYHdob2FtaVxgICIKZXhwb3J0IExBTkc9ZW5fVVMuVVRGLTgKZXhwb3J0IEVESVRPUj0idmltIgpleHBvcnQgUEFUSD0kUEFUSDouCkVPRgoKY2F0ID4gL3Jvb3QvLnZpbXJjIDw8RU9GCnN5bnRheCBvbgpzZXQgdHM9MgpzZXQgbm9iYWNrdXAKc2V0IGV4cGFuZHRhYgpFT0YKClsgLWYgL2V0Yy9zZWN1cml0eS9saW1pdHMuY29uZiBdICYmIExJTUlUPScxMDQ4NTc2JyAmJiBzZWQgLWkgJy9eXChcKlx8cm9vdFwpW1s6c3BhY2U6XV0qXChoYXJkXHxzb2Z0XClbWzpzcGFjZTpdXSpcKG5vZmlsZVx8bWVtbG9ja1wpL2QnIC9ldGMvc2VjdXJpdHkvbGltaXRzLmNvbmYgJiYgZWNobyAtbmUgIipcdGhhcmRcdG1lbWxvY2tcdCR7TElNSVR9XG4qXHRzb2Z0XHRtZW1sb2NrXHQke0xJTUlUfVxucm9vdFx0aGFyZFx0bWVtbG9ja1x0JHtMSU1JVH1cbnJvb3RcdHNvZnRcdG1lbWxvY2tcdCR7TElNSVR9XG4qXHRoYXJkXHRub2ZpbGVcdCR7TElNSVR9XG4qXHRzb2Z0XHRub2ZpbGVcdCR7TElNSVR9XG5yb290XHRoYXJkXHRub2ZpbGVcdCR7TElNSVR9XG5yb290XHRzb2Z0XHRub2ZpbGVcdCR7TElNSVR9XG5cbiIgPj4vZXRjL3NlY3VyaXR5L2xpbWl0cy5jb25mOwoKWyAtZiAvZXRjL3N5c3RlbWQvc3lzdGVtLmNvbmYgXSAmJiBzZWQgLWkgJ3MvI1w/RGVmYXVsdExpbWl0Tk9GSUxFPS4qL0RlZmF1bHRMaW1pdE5PRklMRT0xMDQ4NTc2LycgL2V0Yy9zeXN0ZW1kL3N5c3RlbS5jb25mOwoKY2F0ID4gL2V0Yy9zeXN0ZW1kL2pvdXJuYWxkLmNvbmYgIDw8IkVPRiIKW0pvdXJuYWxdClN0b3JhZ2U9YXV0bwpDb21wcmVzcz15ZXMKRm9yd2FyZFRvU3lzbG9nPW5vClN5c3RlbU1heFVzZT04TQpSdW50aW1lTWF4VXNlPThNClJhdGVMaW1pdEludGVydmFsU2VjPTMwcwpSYXRlTGltaXRCdXJzdD0xMDAKRU9GCgpjYXQgPiAvZXRjL3N5c2N0bC5kLzk5LXN5c2N0bC5jb25mICA8PCJFT0YiCnZtLnN3YXBwaW5lc3MgPSAwCm5ldC5pcHY0LnRjcF9ub3RzZW50X2xvd2F0ID0gMTMxMDcyCm5ldC5jb3JlLnJtZW1fbWF4ID0gNTM2ODcwOTEyCm5ldC5jb3JlLndtZW1fbWF4ID0gNTM2ODcwOTEyCm5ldC5jb3JlLm5ldGRldl9tYXhfYmFja2xvZyA9IDI1MDAwMApuZXQuY29yZS5zb21heGNvbm4gPSA0MDk2Cm5ldC5pcHY0LnRjcF9zeW5jb29raWVzID0gMQpuZXQuaXB2NC50Y3BfdHdfcmV1c2UgPSAxCm5ldC5pcHY0LmlwX2xvY2FsX3BvcnRfcmFuZ2UgPSAxMDAwMCA2NTAwMApuZXQuaXB2NC50Y3BfbWF4X3N5bl9iYWNrbG9nID0gODE5MgpuZXQuaXB2NC50Y3BfbWF4X3R3X2J1Y2tldHMgPSA1MDAwCm5ldC5pcHY0LnRjcF9mYXN0b3BlbiA9IDMKbmV0LmlwdjQudGNwX3JtZW0gPSA4MTkyIDI2MjE0NCA1MzY4NzA5MTIKbmV0LmlwdjQudGNwX3dtZW0gPSA0MDk2IDE2Mzg0IDUzNjg3MDkxMgpuZXQuaXB2NC50Y3BfYWR2X3dpbl9zY2FsZSA9IC0yCm5ldC5pcHY0LmlwX2ZvcndhcmQgPSAxCm5ldC5jb3JlLmRlZmF1bHRfcWRpc2MgPSBmcQpuZXQuaXB2NC50Y3BfY29uZ2VzdGlvbl9jb250cm9sID0gYmJyCkVPRg==' | base64 -d | bash"


# configure default grub
chroot /mnt /bin/bash -c "echo 'IyEvYmluL2Jhc2gKZWNobyAiR1JVQl9ESVNBQkxFX09TX1BST0JFUj10cnVlIiA+PiAvZXRjL2RlZmF1bHQvZ3J1YgpzZWQgLWkgJ3MvXkdSVUJfVElNRU9VVD0uKiQvR1JVQl9USU1FT1VUPTUvJyAvZXRjL2RlZmF1bHQvZ3J1YgpzZWQgLWkgJ3MvXkdSVUJfQ01ETElORV9MSU5VWF9ERUZBVUxUPS4qL0dSVUJfQ01ETElORV9MSU5VWF9ERUZBVUxUPVwicm9vdGZsYWdzPWNvbXByZXNzLWZvcmNlPXpzdGRcIi8nIC9ldGMvZGVmYXVsdC9ncnViCnNlZCAtaSAnc3xeR1JVQl9DTURMSU5FX0xJTlVYPS4qfEdSVUJfQ01ETElORV9MSU5VWD0ibmV0LmlmbmFtZXM9MCBiaW9zZGV2bmFtZT0wInxnJyAvZXRjL2RlZmF1bHQvZ3J1YgplY2hvICdHUlVCX1RFUk1JTkFMPSJzZXJpYWwgY29uc29sZSInID4+IC9ldGMvZGVmYXVsdC9ncnViCmVjaG8gJ0dSVUJfU0VSSUFMX0NPTU1BTkQ9InNlcmlhbCAtLXNwZWVkPTExNTIwMCInID4+IC9ldGMvZGVmYXVsdC9ncnVi' | base64 -d | bash"

chroot /mnt mkdir -p /boot/grub
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

if [ "\$uefi" = "true" ]; then
	chroot /mnt pacman --disable-sandbox --needed --noconfirm -Su efibootmgr
	mount --rbind /sys/firmware/efi/efivars /mnt/sys/firmware/efi/efivars
	chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --bootloader-id=GRUB
	umount /mnt/sys/firmware/efi/efivars
else
	chroot /mnt grub-install --target=i386-pc ${disk}
fi


# Make sure that the unnecessary partitions are mounted
genfstab -U /mnt >> /mnt/etc/fstab

umount -l /mnt/boot/efi
umount -l /mnt/dev/pts
umount -l /mnt/dev
umount -l /mnt/sys
umount -l /mnt/proc
umount -l /mnt

# will reboot or waitme
sync
sleep 5
if [ "\${waitme}" = 'true' ];then
	exec /bin/bash
else
	reboot -f
fi

EOF

	chmod 0755 ${boot}/init
	swapoff -a && losetup -D || true
	log	'[*] Now you will enter the installation process.'
	log	'[*] Machine processes with poor performance will be very slow!'
	log	"[*] You can try logging in with root and ${password} to check the situation..."
	sleep 1
	trap - EXIT
	systemctl switch-root ${boot} /init
}

function print_info(){
	log '**************************************************************************'
	log "[*] e.g. --lts --waitme --reflector --dhcp --uefi --pwd changeme123"
	log "[*] UEFI: $uefi	DHCP: $dhcp	Reflector: ${reflector}"
	log "[*] ARCH: $arch	KERNEL:	$kernel	NOREBOOT: ${waitme}"
	log "[*] V4: $ip4_addr $ip4_gw"
	log "[*] V6: $ip6_addr $ip6_gw"
	log "[*] $mirror"
	log '**************************************************************************'
}

function parse_command_and_confirm() {
	while [ $# -gt 0 ]; do
		case $1 in
			--mirror)
				mirror=$2
				shift
				;;
			--pwd)
				password=$2
				shift
				;;
			--dhcp)
				dhcp=true
				;;
			--uefi)
				uefi=true
				;;
			--lts)
				kernel='linux-lts'
				;;
			--reflector)
				reflector=true
				;;
			--waitme)
				waitme=true
				;;
			*)
				fatal "Unsupported parameters: $1"          
		esac
		shift
	done
	
	print_info
    read -r -p "${1:-[*] This operation will clear all data. Are you sure you want to continue?[y/N]} " _confirm
    case "$_confirm" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

[ "$(grep -q "ID=debian" /etc/os-release; echo $?)" -eq 0 ] || fatal '[-] This script only supports Debian systems.'
[ ${EUID} -eq 0 ] || fatal '[-] This script must be run as root.'
[ ${UID} -eq 0 ] || fatal '[-] This script must be run as root.'

if parse_command_and_confirm "$@" ; then
	download_and_extract_rootfs
	configure_rootfs_dependencies
	switch_to_rootfs
else
	echo -e "Force reboot by \"echo b > /proc/sysrq-trigger\"."
	exit 1
fi
