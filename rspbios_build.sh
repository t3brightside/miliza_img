#!/bin/bash
# ========================================================
# Miliza OS Image Builder Script (Runs inside GitHub Actions)
# ========================================================
set -e

SYSTEM_HOSTNAME="miliza"
BT_DEVICE_NAME="Miliza Hi-Fi"

echo "=> Configuring Hostname & Locales..."
echo "$SYSTEM_HOSTNAME" > /etc/hostname
sed -i "s/127.0.1.1.*/127.0.1.1\t$SYSTEM_HOSTNAME $SYSTEM_HOSTNAME.local/g" /etc/hosts
echo "en_GB.UTF-8 UTF-8" > /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
update-locale LANG=en_GB.UTF-8 LC_ALL=en_GB.UTF-8

echo "=> Pre-configuring Bluetooth..."
mkdir -p /etc/bluetooth
cat << EOF > /etc/bluetooth/main.conf
[General]
Name = $BT_DEVICE_NAME
Class = 0x200404
DiscoverableTimeout = 0
ControllerMode = bredr

[Policy]
AutoEnable=false
EOF

echo "=> Installing System Dependencies..."
apt-get update
apt-get purge -y bluez-alsa-utils || true

# Install runtime + build dependencies
apt-get install -y --no-install-recommends \
    rclone fuse3 network-manager dnsmasq-base iptables \
    libbluetooth3 libsbc1 libfreeaptx0 libldacbt-enc2 libldacbt-abr2 libfdk-aac2 \
    libmp3lame0 libmpg123-0 libopus0 \
    libgirepository-2.0-0 gir1.2-glib-2.0 python3-gi \
    avahi-daemon alsa-utils bluez bluez-tools rfkill dbus \
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-tools gstreamer1.0-alsa \
    gir1.2-gst-plugins-base-1.0 curl ca-certificates nano \
    git build-essential autoconf automake libtool pkg-config \
    libasound2-dev libbluetooth-dev libglib2.0-dev libsbc-dev \
    libfdk-aac-dev libfreeaptx-dev libldacbt-enc-dev libldacbt-abr-dev \
    libmp3lame-dev libmpg123-dev libopus-dev libdbus-1-dev \
    smbclient cifs-utils udisks2 id3v2 shairport-sync caddy

sed -i 's/#user_allow_other/user_allow_other/g' /etc/fuse.conf

echo "=> Enabling ALSA Loopback kernel module..."
if ! grep -q "^snd-aloop" /etc/modules; then
    echo "snd-aloop" >> /etc/modules
fi

echo "=> Building Custom BlueALSA..."
mkdir -p /tmp/bluealsa-build-temp && cd /tmp/bluealsa-build-temp
git clone https://github.com/arkq/bluez-alsa.git .
mkdir -p m4
autoreconf --install --force --verbose
./configure --prefix=/usr --enable-aac --enable-aptx --enable-aptx-hd --with-libfreeaptx --enable-ldac --enable-mp3lame --enable-mpg123 --enable-opus --enable-faststream --enable-midi --enable-a2dpconf --enable-aplay --enable-systemd
make -j$(nproc)
make install
ln -sf /usr/bin/bluealsad /usr/bin/bluealsa
mkdir -p /usr/var/lib/bluealsa
chmod 755 /usr/var/lib/bluealsa

cat << 'EOF' > /etc/systemd/system/bluealsa.service
[Unit]
Description=BluezALSA proxy
Requires=bluetooth.service
After=bluetooth.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/bluealsa -p a2dp-sink -p a2dp-source --aac-afterburner
Restart=always

[Install]
WantedBy=multi-user.target
EOF

echo "=> Protecting codecs and cleaning up build tools..."
apt-mark manual libfreeaptx0 libldacbt-enc2 libldacbt-abr2 libfdk-aac2 libmp3lame0 libmpg123-0 libopus0
cd /root
rm -rf /tmp/bluealsa-build-temp
apt-get purge -y git build-essential autoconf automake libtool pkg-config libasound2-dev libbluetooth-dev libglib2.0-dev libsbc-dev libfdk-aac-dev libfreeaptx-dev libldacbt-enc-dev libldacbt-abr-dev libmp3lame-dev libmpg123-dev libopus-dev libdbus-1-dev
apt-get autoremove -y
apt-get clean

echo "=> Patching Bluetooth Daemon..."
mkdir -p /etc/systemd/system/bluetooth.service.d
cat << 'EOF' > /etc/systemd/system/bluetooth.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/bluetoothd --noplugin=hostname
EOF

echo "=> Configuring Shairport-Sync for AirPlay..."
cat << EOF > /etc/shairport-sync.conf
general = {
    name = "${SYSTEM_HOSTNAME^}";
    port = 5005;
    ignore_volume_control = "yes";
};
alsa = { output_device = "hw:Loopback,0,0"; };
sessioncontrol = { active_state_timeout = 1.0; };
EOF

echo "=> Configuring headless USB automounting..."
cat << 'EOF' > /etc/udev/rules.d/99-usb-automount.rules
ACTION=="add", SUBSYSTEMS=="usb", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", RUN+="/usr/bin/systemd-mount --no-block --collect $devnode /media/USB-%k"
EOF
cat << 'EOF' > /etc/udev/rules.d/99-usb-cleanup.rules
ACTION=="remove", SUBSYSTEMS=="usb", SUBSYSTEM=="block", ENV{ID_FS_USAGE}=="filesystem", RUN+="/usr/bin/systemd-umount /media/USB-%k", RUN+="/bin/rmdir /media/USB-%k"
EOF

echo "=> Fetching Miliza App binary using secure GitHub Secret..."
mkdir -p /root/.config/miliza/data
curl -kL "$MILIZA_AARCH64_URL" -o /usr/local/bin/miliza
chmod +x /usr/local/bin/miliza

echo "=> Creating Miliza SystemD Service..."
cat << 'EOF' > /etc/systemd/system/miliza.service
[Unit]
Description=Miliza App
After=network.target bluetooth.target dbus.service

[Service]
ExecStart=/usr/bin/chrt -f 50 /usr/local/bin/miliza
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "=> Configuring Caddy Reverse Proxy & Hotspot..."
cat << 'EOF' > /etc/sysctl.d/99-caddy-quic.conf
net.core.rmem_max=2500000
net.core.wmem_max=2500000
EOF

mkdir -p /var/www/html
cat << EOF > /etc/caddy/Caddyfile
{
    skip_install_trust
    auto_https disable_redirects
    pki { ca local { name "${SYSTEM_HOSTNAME} CA" } }
}
http://${SYSTEM_HOSTNAME}.local, :80 {
    handle { reverse_proxy 127.0.0.1:5000 }
}
https://${SYSTEM_HOSTNAME}.local {
    reverse_proxy 127.0.0.1:5000
}
EOF
mkdir -p /etc/NetworkManager/dnsmasq-shared.d
echo 'address=/#/10.42.0.1' > /etc/NetworkManager/dnsmasq-shared.d/captive.conf

echo "=> Enabling Services (Will start automatically on first physical boot)..."
systemctl enable caddy avahi-daemon miliza bluetooth bluealsa shairport-sync

echo "=> Image Build Complete!"
