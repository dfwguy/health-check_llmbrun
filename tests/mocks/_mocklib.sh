# shared by all mocks. MOCK_DIR must be set by the harness.
: "${MOCK_DIR:?MOCK_DIR not set}"
mock_log() { printf '%s %s\n' "${0##*/}" "$*" >> "$MOCK_DIR/calls.log"; }
# node state: lines "<node> <state>" in nodes.state; default from MOCK_DEFAULT_NODE_STATE
mock_node_state() {
  local n="$1" v=""
  [[ -r "$MOCK_DIR/nodes.state" ]] && v="$(awk -v n="$n" '$1==n{print $2; exit}' "$MOCK_DIR/nodes.state")"
  printf '%s' "${v:-${MOCK_DEFAULT_NODE_STATE:-idle}}"
}
# job state: lines "<jobid> <state> <elapsed>" in jobs.state
mock_job_field() {
  local j="$1" f="$2"
  [[ -r "$MOCK_DIR/jobs.state" ]] || return 1
  awk -v j="$j" -v f="$f" '$1==j{ if (f=="state") print $2; else if (f=="elapsed") print $3; else if (f=="nodes") print $4; exit }' "$MOCK_DIR/jobs.state"
}
