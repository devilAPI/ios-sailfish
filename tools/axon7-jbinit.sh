#!/var/jb/bin/sh
# Boot-time setup of the rootless Procursus bootstrap on the Axon 7 iOS
# port (installed by tools/axon7-jailbreak.sh as
# /var/jb/usr/libexec/axon7-jbinit.sh, started once per boot by launchd job
# com.axon7.jbinit, as root).
# Once (marker /var/jb/.axon7_jbinit_done):
#   1. the bootstrap's own prep_bootstrap.sh (dpkg base packages, users),
#      without its password dialog: mobile and root get the password "alpine"
#   2. dpkg -i Sileo
#   3. uicache, so Sileo appears on the home screen
# Every boot:
#   - Sileo's own lists directory (/var/jb/var/lib/apt/sileolists): Sileo
#     cannot create it without root and fails to save repo indexes without it
#   - packages left in /var/jb/var/axon7/debs/ (tools/axon7-root-add.sh):
#     dpkg -i as root, removed once installed
#   - the jailbreak's launch daemons (/var/jb/Library/LaunchDaemons, e.g.
#     sshd), as rootless jailbreaks load them at boot
# Log: /var/jb/var/log/axon7-jbinit.log
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin
done_mark=/var/jb/.axon7_jbinit_done
debs=/var/jb/var/axon7/debs
mkdir -p /var/jb/var/log
exec >>/var/jb/var/log/axon7-jbinit.log 2>&1
echo "== axon7-jbinit $(date)"

# let lsd, cfprefsd and SpringBoard come up first (uicache, launchctl)
sleep 45

if [ ! -f "$done_mark" ]; then
	if [ -f /var/jb/prep_bootstrap.sh ]; then
		echo "-- prep_bootstrap.sh"
		NO_PASSWORD_PROMPT=1 /var/jb/bin/sh /var/jb/prep_bootstrap.sh
		printf '%s\n' alpine | /var/jb/usr/sbin/pw usermod 501 -h 0
		printf '%s\n' alpine | /var/jb/usr/sbin/pw usermod 0 -h 0
	fi

	if [ -f /var/jb/var/axon7/sileo.deb ]; then
		echo "-- dpkg -i sileo"
		if dpkg -i /var/jb/var/axon7/sileo.deb; then
			rm -f /var/jb/var/axon7/sileo.deb
		fi
	fi

	echo "-- uicache"
	uicache -p /var/jb/Applications/Sileo.app || uicache -a

	if dpkg -s org.coolstar.sileo >/dev/null 2>&1; then
		touch "$done_mark"
		echo "-- first-boot setup done"
	else
		echo "-- Sileo not installed yet: will retry next boot"
	fi
fi

if [ ! -d /var/jb/var/lib/apt/sileolists ]; then
	echo "-- creating /var/jb/var/lib/apt/sileolists"
	mkdir -p /var/jb/var/lib/apt/sileolists
	chown 0:0 /var/jb/var/lib/apt/sileolists
	chmod 755 /var/jb/var/lib/apt/sileolists
fi

if ls "$debs"/*.deb >/dev/null 2>&1; then
	echo "-- dpkg -i $(cd "$debs" && echo *.deb)"
	if dpkg -i "$debs"/*.deb; then
		rm -f "$debs"/*.deb
		echo "-- packages installed"
	else
		echo "-- dpkg failed: packages kept for the next boot"
		dpkg --configure -a
	fi
fi

for plist in /var/jb/Library/LaunchDaemons/*.plist; do
	[ -f "$plist" ] || continue
	echo "-- launchctl load $plist"
	launchctl load -w "$plist"
done
echo "== done"
