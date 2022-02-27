#!/bin/bash

  #-Z, --ignore-trailing-space     ignore white space at line end
  #-b, --ignore-space-change       ignore changes in the amount of white space
  #-w, --ignore-all-space          ignore all white space
  #-B, --ignore-blank-lines        ignore changes where lines are all blank
  #-I, --ignore-matching-lines=RE  ignore changes where all lines match RE


PATCHDIR="$(dirname $(readlink -f $0))"

SRCDIR="$(echo "$PATCHDIR" | sed -e 's#_patches##')"

if [ ! -d "$SRCDIR" ]; then
	echo "Error: ${SRCDIR} directory not found. Exiting."
	exit 1
fi

echo "SRCDIR   == ${SRCDIR}"
echo "PATCHDIR == ${PATCHDIR}"


for PATCHTARGET in *.c *.cpp *.h makefile *.sh *.py Makefile
do
	if [ ! -f "${SRCDIR}/${PATCHTARGET}" ] || [ "$PATCHTARGET" = 'apply.sh' ] || [ "$PATCHTARGET" = 'get_diffs.sh' ]; then
		continue
	fi

	echo "Creating patchfile for ${PATCHDIR}/${PATCHTARGET}"
	
	#~ diff options:
		#~ -r recursive
		#~ -u output NUM (default 3) lines of unified context
		#~ -p show which C function each change is in
		#~ -N treat absent files as empty
		
		#~ -Z ignore white space at line end
		#~ -b ignore changes in the amount of white space
		#~ -w ignore all white space
		#~ -B ignore changes where lines are all blank

	#~ diff -rupN -ZbwB "${SRCDIR}/${PATCHTARGET}" "${PATCHDIR}/${PATCHTARGET}" >"${PATCHDIR}/${PATCHTARGET}.diff"
	diff -rupN "${SRCDIR}/${PATCHTARGET}" "${PATCHDIR}/${PATCHTARGET}" >"${PATCHDIR}/${PATCHTARGET}.diff"

	# Delete empty diff files
	if [ $(wc -l "${PATCHTARGET}.diff" | sed -n -e 's/^\([[:digit:]]\+\).*$/\1/p' ) -lt 1 ]; then
		rm "${PATCHTARGET}.diff"
	fi

	# Remove the path info from the diff file..
	if [ -f "${PATCHTARGET}.diff" ]; then
		sed -i -e "s#${SRCDIR}/${PATCHTARGET}#${PATCHTARGET}.ORIGINAL#g" "${PATCHTARGET}.diff"
		sed -i -e "s#${PATCHDIR}/##g" "${PATCHTARGET}.diff"
	fi

	if [ -f "${PATCHTARGET}.diff" ]; then
		echo "${PATCHTARGET}.diff patchfile created"
	fi
done
