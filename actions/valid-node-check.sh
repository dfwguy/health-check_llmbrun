#!/bin/bash
#

## Use this file if categories are needed; spcx-hosts is category in following example
if [[ "$CMD_CATEGORY" == "spcx-hosts" ]]; then
	if [[ ! -s /tmp/PASS ]]; then
		echo pass > /tmp/PASS
		echo fail
	else
		echo pass
	fi
else
	echo fail
fi
