#!/var/jb/bin/sh
# First-boot setup of the rootless Procursus bootstrap on the Axon 7 iOS
# port (installed by tools/axon7-jailbreak.sh as
# /var/jb/usr/libexec/axon7-jbinit.sh, started once per boot by launchd job
# com.axon7.jbinit, as root). Does its work once, then only exits:
#   1. the bootstrap's own prep_bootstrap.sh (dpkg base packages, users),
#      without its password dialog: mobile and root get the password "alpine"
#   2. dpkg -i Sileo
#   3. uicache, so Sileo appears on the home screen
# Log: /var/jb/var/log/axon7-jbinit.log
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/usr/bin:/bin:/usr/sbin:/sbin
done_mark=/var/jb/.axon7_jbinit_done
[ -f "$done_mark" ] && exit 0
mkdir -p /var/jb/var/log
exec >>/var/jb/var/log/axon7-jbinit.log 2>&1
echo "== axon7-jbinit $(date)"

# let lsd, cfprefsd and SpringBoard come up first (uicache talks to them)
sleep 45

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
	echo "== done"
else
	echo "== Sileo not installed yet: will retry next boot"
fi
