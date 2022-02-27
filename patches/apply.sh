#!/bin/bash

PATCHDIR="$(dirname $(readlink -f $0))"

SRCDIR="$(echo "$PATCHDIR" | sed -e 's#_patches##')"

if [ ! -d "$SRCDIR" ]; then
	echo "Error: ${SRCDIR} directory not found. Exiting."
	exit 1
fi

echo "SRCDIR   == ${SRCDIR}"
echo "PATCHDIR == ${PATCHDIR}"

cd "$PATCHDIR"

cd "$SRCDIR"

if [ ! "$SRCDIR" = "$(pwd)" ]; then
	echo "Cannot change to ${SRCDIR}"
	echo "${SRCDIR} != $(pwd)"
	exit 1
fi

# Apply the patches
echo "Patching ${SRCDIR} with diffs from ${PATCHDIR}.."

for PATCHTARGET in *.c *.cpp *.h *.py Makefile makefile
do
	PATCHFILE="${PATCHDIR}/${PATCHTARGET}.diff"
	if [ -f "$PATCHFILE" ]; then
		echo "Patching ${PATCHTARGET} with ${PATCHFILE}"
		cat "$PATCHFILE" | patch -p0
		echo "patch returned $?"
	fi
done

# Fixup the Makefile to install binary to /usr/local/bin rather than sbin

MAKEFILE="${SRCDIR}/Makefile"

if [ -f "$MAKEFILE" ]; then
	if [ $(cat "$MAKEFILE" | egrep -c '/sbin') -gt 0 ]; then
		echo "Patching ${MAKEFILE} to install binary to /usr/local/bin rather than sbin.."
		grep 'sbindir = ${exec_prefix}' "$MAKEFILE"
		sed -i -e 's#/sbin#/bin#g' "$MAKEFILE"
		grep 'sbindir = ${exec_prefix}' "$MAKEFILE"
	fi
fi

echo "Done."
