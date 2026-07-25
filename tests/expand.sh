#!/bin/bash
# tiny helper so mocks can expand hostlists without sourcing the whole lib
set -uo pipefail
source "$(cd "$(dirname "$0")/../lib" && pwd)/nodeset.sh"
ns_expand "$@"
