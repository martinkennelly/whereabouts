#!/bin/bash
set -eo pipefail
# e2e test cases for whereabouts
# Current Test cases
ts1="Test scenario 1: Scale up and down the number of pods in a cluster using the same IPV4 Pool
and check that:
   a. All pod IPs are unique
   b. Number of IP pool allocations reflect number of Pod IPs allocated
   c. IP pool has zero allocations with zero pods at the end of testing"

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
NUMBER_OF_THRASH_ITER=${NUMBER_OF_TRASH_ITER:-30}
TIMEOUT_K8="5000s"
TIMEOUT="5000"
IPV4_TEST_RANGE="10.10.0.0/16"
IPV4_RANGE_POOL_NAME="10.10.0.0-16"
TEST_IMAGE=${TEST_IMAGE:-"quay.io/dougbtv/alpine:latest"}
TEST_NAMESPACE="default"
WB_NAMESPACE="kube-system"
MAX_PODS_PER_NODE=30
RS_NAME="whereabouts-scale-test"
WB_LABEL_EQUAL="tier=whereabouts-scale-test"
WB_LABEL_COLON="tier: whereabouts-scale-test"

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
    let retries--
  done
  return $status
}

set_pod_count() {
cat <<EOF | retry kubectl apply -f-
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
cat <<EOF | retry kubectl apply -f -
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
        "range": "$IPV4_TEST_RANGE"
      }
    }'
EOF
}

is_pod_ip_unique() {
  echo "#### testing to ensure pod IPs are unique"
  number_of_uniq_ip="$(kubectl get pods --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE --output=jsonpath='{range .items[*].status}{.podIP}{"\n"}{end}' | uniq | wc -l)"
  number_pods_running=$(kubectl get pods --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE | grep -c Running)
  if [[ $number_pods_running != "$number_of_uniq_ip" ]]; then
      echo "number of pods '$number_pods_running' did not match number of unique IP(s) '$number_of_uniq_ip'"
      echo -e "IP(s) seen:\n$(kubectl get pods --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE --output=jsonpath='{range .items[*].status}{.podIP}{"\n"}{end}')"
      exit 1
  fi
}

is_zero_ippool_allocations() {
  echo "#### testing if ip pool has zero IP allocations"
  number_ips=$(kubectl get ippool $IPV4_RANGE_POOL_NAME --namespace $WB_NAMESPACE --output json | grep -c '\"id\"')
  if [[ $number_ips -ne 0 ]]; then
    echo "expected zero IP pool allocations, but found $number_ips IP pool allocations"
    exit 2
  fi
}

is_ippool_allocations_equal_pod_number() {
  echo "#### testing to check if IP pool allocations equal to the number of pods (each pod gets one IP)"
  number_ippool_allocations=$(kubectl get ippool $IPV4_RANGE_POOL_NAME --namespace $WB_NAMESPACE --output json | grep -c '\"id\"')
  number_pods_running=$(kubectl get pods --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE | grep -c Running)
  if [[ $number_ippool_allocations != "$number_pods_running" ]]; then
    echo "number of pods seen running ($number_pods_running) and number of IP Pool allocations ($number_ippool_allocations) dont match"
    exit 3
  fi
}

echo "$ts1"
echo "## start test"
echo "## create IPV4 network foo"
create_foo_ipv4_network
last_pod_count=0
for i in $(seq $NUMBER_OF_THRASH_ITER); do
  echo "### iteration $i of $NUMBER_OF_THRASH_ITER"
  pod_count=$(( (RANDOM % $MAX_PODS_PER_NODE) * $NUMBER_OF_COMPUTE_NODES ))
  echo "### setting pod count to $pod_count from $last_pod_count"
  set_pod_count $pod_count
  last_pod_count=$pod_count
  sleep 5
  echo "### waiting until pods are ready and also timing how long it takes to reach pod count of $pod_count"
  retry time kubectl wait --for=condition=ready pod --selector $WB_LABEL_EQUAL --namespace $TEST_NAMESPACE --timeout $TIMEOUT_K8
  sleep 5
  # tests
  is_pod_ip_unique
  is_ippool_allocations_equal_pod_number
done

echo "## deleting replicate set"
retry kubectl delete rs $RS_NAME --namespace $TEST_NAMESPACE
sleep 5
retry kubectl wait --for=delete pod --selector tier=$RS_NAME --namespace $TEST_NAMESPACE --timeout $TIMEOUT_K8
is_zero_ippool_allocations
echo "## test complete"
