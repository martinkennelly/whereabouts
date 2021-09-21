#!/bin/bash
set -eo pipefail
# e2e test cases for whereabouts
# Current Test cases
ts1="Test scenario 1: Scale up and down the number of pods in a cluster using the same IPV4 Pool
and check that:
   a. IPs seen in IP pool allocations reflect active pod IPs
   a. Pod IPs are allocated in IP pool"

while true; do
  case "$1" in
    -n|--number-of-compute)
      NUMBER_OF_COMPUTE_NODES=$2
      break
      ;;
    *)
      echo "define argument -n (number of compute nodes)"
      exit 1
  esac
done

LEADER_LEASE_DURATION=${LEADER_LEASE_DURATION:-1500}
LEADER_RENEW_DEADLINE=${LEADER_RENEW_DEADLINE:-1000}
LEADER_RETRY_PERIOD=${LEADER_RETRY_PERIOD:-500}
TEST_NETWORK_NAME=${TEST_NETWORK_NAME:-"network1"}
TEST_INTERFACE_NAME="${TEST_INTERFACE_NAME:-"eth0"}"
NUMBER_OF_THRASH_ITER=${NUMBER_OF_THRASH_ITER:-50}
WB_NAMESPACE="${WB_NAMESPACE:-"kube-system"}"
TEST_NAMESPACE="${TEST_NAMESPACE:-"default"}"
TIMEOUT=${TIMEOUT:-5000}
TIMEOUT_K8="${TIMEOUT}s"
FILL_PERCENT_CAPACITY=${FILL_PERCENT_CAPACITY:-90}
TEST_IMAGE=${TEST_IMAGE:-"quay.io/dougbtv/alpine:latest"}
IPV4_TEST_RANGE="10.10.0.0/16"
IPV4_RANGE_POOL_NAME="10.10.0.0-16"
MAX_PODS_PER_NODE=${MAX_PODS_PER_NODE}
RS_NAME="whereabouts-scale-test"
WB_LABEL_EQUAL="tier=whereabouts-scale-test"
WB_LABEL_COLON="tier: whereabouts-scale-test"

check_requirements() {
  for cmd in nmap kubectl jq; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "$cmd is not available"
      exit 1
    fi
  done
}

retry() {
  local status=0
  local retries=${RETRY_MAX:=5}
  local delay=${INTERVAL:=5}
  local to=${TIMEOUT:=20}
  cmd="$*"

  while [ $retries -gt 0 ]
  do
    status=0
    timeout $to bash -c "echo $cmd && $cmd" || status=$?
    if [ $status -eq 0 ]; then
      break;
    fi
    echo "Exit code: '$status'. Sleeping '$delay' seconds before retrying"
    sleep $delay
    ((retries--))
  done
  return $status
}

wait_until_all_pods() {
  local timeout=${TIMEOUT:-300}
  local all_running
  local pod_phases
  while [[ $timeout -gt 0 ]]; do
    all_running=true
    pod_phases="$(kubectl get pods -o jsonpath="{range .items[*]}{.status.phase}{' '}{end}")"
    for phase in $pod_phases; do
      if [[ $phase != "Running" ]] && [[ $phase != "Succeeded" ]]; then
        all_running=false
        break
      fi
    done
    if [ "$all_running" = true ]; then
      return 0
    fi
    sleep 1
    ((timeout--))
  done
  return 1
}

wait_until_all_pods_terminated() {
  local timeout=${TIMEOUT:-300}
  while [[ $timeout -gt 0 ]]; do
    if ! kubectl get pods | grep Terminating >/dev/null; then
      return 0
    fi
    sleep 1
    ((timeout--))
  done
  return 1
}

steady_state_or_die() {
  if ! wait_until_all_pods; then
    echo "#### waiting for all pods ready failed"
    exit 1
  fi
  if ! wait_until_all_pods_terminated; then
    echo "#### waiting for pods to be finished terminating failed"
    exit 2
  fi
}

get_max_pods_per_node() {
  local max_pods
  max_pods="$(kubectl get nodes -o jsonpath='{range .items[0]}{.status.allocatable.pods}{end}')"
  echo "$(((max_pods*FILL_PERCENT_CAPACITY)/100))"
}

set_pod_count() {
  echo "#### setting relicaset pod count to '$1'"
cat <<EOF | kubectl apply -f-
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: $RS_NAME
  namespace: $TEST_NAMESPACE
  labels:
    $WB_LABEL_COLON
spec:
  replicas: $1
  selector:
    matchLabels:
      tier: $RS_NAME
  template:
    metadata:
      labels:
        tier: $RS_NAME
      annotations:
        k8s.v1.cni.cncf.io/networks: $TEST_NETWORK_NAME
      namespace: $TEST_NAMESPACE
    spec:
      containers:
      - name: samplepod
        command: ["/bin/ash", "-c", "trap : TERM INT; sleep infinity & wait"]
        image: $TEST_IMAGE
EOF
}

create_foo_ipv4_network() {
  echo "#### creating network with IPV4 IPAM"
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: $TEST_NETWORK_NAME
  namespace: $TEST_NAMESPACE
spec:
  config: '{
      "cniVersion": "0.3.0",
      "type": "macvlan",
      "master": "$TEST_INTERFACE_NAME",
      "mode": "bridge",
      "ipam": {
        "type": "whereabouts",
        "leader_lease_duration": $LEADER_LEASE_DURATION,
        "leader_renew_deadline": $LEADER_RENEW_DEADLINE,
        "leader_retry_period": $LEADER_RETRY_PERIOD,
        "range": "$IPV4_TEST_RANGE",
        "log_level": "debug",
        "log_file": "/tmp/wb"
      }
    }'
EOF
}

is_zero_ippool_allocations() {
  echo "#### testing if ip pool has zero IP allocations"
  local number_ips
  number_ips=$(kubectl get ippool $IPV4_RANGE_POOL_NAME --namespace $WB_NAMESPACE --output json | grep -c '\"id\"' &>/dev/null || true)
  if [[ $number_ips -ne 0 ]]; then
    echo "expected zero IP pool allocations, but found $number_ips IP pool allocations"
    exit 4
  fi
}

is_ippool_consistent() {
  echo "#### checking if there are any stale IPs in IP pool or any IPs in IP pool that are not seen attached to a pod"
  local ippool_keys
  local ips
  local pod_ips
  local resolved_ippool_ip
  local exit_code=0
  ippool_keys=$(kubectl get ippool $IPV4_RANGE_POOL_NAME --namespace $WB_NAMESPACE -o json \
    | jq --raw-output '.spec.allocations|to_entries |map("\(.key)")| .[]')
  ips=($(nmap -sL -n $IPV4_TEST_RANGE | awk '/Nmap scan report for/{printf "%s ", $NF}'))
  pod_ips=($(kubectl get pod --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE \
    -o jsonpath="{range .items[*].metadata.annotations}{.k8s\.v1\.cni\.cncf\.io/network-status}{end}" \
    | jq -c '.[] | select(.name == "default/network1") | .ips[0]' | tr -d '"'))

  for ippool_key in ${ippool_keys[@]}; do
    resolved_ippool_ip="${ips[$ippool_key]}"
    found=false
    for pod_ip in "${pod_ips[@]}"; do
      if [[ ${pod_ip} == "${resolved_ippool_ip}" ]]; then
        found=true
        break
      fi
    done

    if ! $found; then
      echo "#### possible stale IP pool: failed to find pod for IP pool key '$ippool_key' or IP '$resolved_ippool_ip'"
      exit_code=1
    fi
  done

  for pod_ip in ${pod_ips[@]}; do
    found=false
    for ippool_key in ${ippool_keys[@]}; do
      resolved_ippool_ip="${ips[$ippool_key]}"
      if [[ ${pod_ip} == "${resolved_ippool_ip}" ]]; then
        found=true
        break
      fi
    done

    if ! $found ]]; then
      echo "#### possible pod IP not recorded in IP pool: failed to find IP pool allocation for pod IP '${pod_ip}'"
      exit_code=1
    fi
  done
  return $exit_code
}

check_requirements
echo "$ts1"
echo "## start test"
echo "## create IPV4 network foo"
create_foo_ipv4_network
echo "## iterating the creation and deletion '$NUMBER_OF_THRASH_ITER' times in order to detect stale or duplicate IPs"
for i in $(seq $NUMBER_OF_THRASH_ITER); do
  echo "### iteration $i of $NUMBER_OF_THRASH_ITER ($(date))"
  set_pod_count 0
  steady_state_or_die
  is_zero_ippool_allocations
  set_pod_count $(( $(get_max_pods_per_node) * $NUMBER_OF_COMPUTE_NODES ))
  steady_state_or_die
  # tests
  if ! is_ippool_consistent; then
    exit 1
  fi
  echo "### iteration '$i' ended ($(date))"
done
echo "## test complete"
