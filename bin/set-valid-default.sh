#!/bin/bash
#
# Run this against a node that has been manually validated as a good node
# /opt/llmb-bringup/set-valid-default.sh NodeName
# /opt/llmb-bringup/set-valid-default.sh node001

home="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
logs="$home/logs"
valid="$home/valid-config"


if [[ -d $logs/$1 ]];
then
	if [[ -d $valid/default ]];
	then
		rm $valid/default -f
	fi

	cp -r $logs/$1 $valid/
	ln -s $valid/$1 $valid/default
else
	echo "The node selected doesn't have a valid health log in $logs"
fi
