#!/bin/sh /etc/rc.common
# Pre-extract ath12k calibration data from the board's calibration partition
# before the ath12k modules are loaded.
#
# The card firmware asks for cal-ahb-*.bin / cal-pci-*.bin very early in probe
# and only waits a limited time.  Relying on the udev firmware hotplug path to
# generate those files was observed to be racy on eMMC units (the request
# timed out with -110 and the radio failed to register), so extract them
# deterministically at boot instead, reusing the per-board offsets that
# /etc/hotplug.d/firmware/12-ath12k-caldata already knows about.

START=09
STOP=99

start() {
	local fw handler=/etc/hotplug.d/firmware/12-ath12k-caldata

	[ -x "$handler" ] || return 0

	for fw in \
		ath12k/IPQ5332/hw1.0/cal-ahb-c000000.wifi.bin \
		ath12k/QCN9274/hw2.0/cal-pci-0001:01:00.0.bin
	do
		[ -s "/lib/firmware/$fw" ] && continue
		FIRMWARE="$fw" sh "$handler" >/dev/null 2>&1
		[ -s "/lib/firmware/$fw" ] || rm -f "/lib/firmware/$fw"
	done
}
