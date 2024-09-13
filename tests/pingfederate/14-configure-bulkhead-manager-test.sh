#!/bin/bash

# CI Script Directory Initialization
CI_SCRIPTS_DIR="${SHARED_CI_SCRIPTS_DIR:-/ci-scripts}"
. "${CI_SCRIPTS_DIR}"/common.sh "${1}"

# Skip the test if necessary
if skipTest "${0}"; then
  log "Skipping test ${0}"
  exit 0
fi

# Function to run the 90-configure-bulkhead-manager.sh script in the pingfederate-admin pod
testBulkheadManagerExecution() {
  local expected_exit_code=0
  local pod_name="pingfederate-admin-0"
  local namespace="ping-cloud"
  local container_name="pingfederate-admin"
  local script_path="/opt/staging/hooks/90-configure-bulkhead-manager.sh"

  # Run the kubectl exec command
  output=$(kubectl exec "${pod_name}" -n "${namespace}" -c "${container_name}" -- sh -c "${script_path}; status_code=\$?; echo Exit status: \$status_code")
  
  # Capture the exit status from the output
  status_code=$(echo "$output" | grep "Exit status" | awk '{print $3}')
  
  # Use assertEquals from shunit2 to check if the exit code is as expected (0 for success)
  assertEquals "Bulkhead Manager script failed with exit status: ${status_code}" "${expected_exit_code}" "${status_code}"
}

# Function to export environment variables, execute the bulkhead script, and verify via GET API call
testBulkheadManagerWithAPI() {
  local expected_exit_code=0
  local pod_name="pingfederate-admin-0"
  local namespace="ping-cloud"
  local container_name="pingfederate-admin"
  local script_path="/opt/staging/hooks/90-configure-bulkhead-manager.sh"
  local bulkhead_env_var="PF_BULKHEAD_THREAD_POOL_USAGE_WARNING_THRESHOLD=0.3"
  local api_endpoint="https://pingfederate-admin:9999/pf-admin-api/v1/configStore/com.pingidentity.common.util.resiliency.BulkheadManagerImpl"
  local curl_output

  # Step 1: Export environment variable and execute the bulkhead manager script
  echo "Running bulkhead manager script with environment variable: ${bulkhead_env_var}"
  kubectl exec "${pod_name}" -n "${namespace}" -c "${container_name}" -- sh -c "export ${bulkhead_env_var}; ${script_path}; status_code=\$?; echo Exit status: \$status_code"

  # Capture the exit status from the output
  status_code=$(echo "$output" | grep "Exit status" | awk '{print $3}')
  assertEquals "Bulkhead Manager script failed with exit status: ${status_code}" "${expected_exit_code}" "${status_code}"

  # Step 2: Verify if the environment variables were applied by querying the API
  echo "Verifying that the environment variables were applied using the API"
  curl_output=$(kubectl exec -it "${pod_name}" -n "${namespace}" -c "${container_name}" -- sh -c \
    "curl -k --user \"Administrator:${PF_ADMIN_USER_PASSWORD}\" \
    -X 'GET' \
    '${api_endpoint}' \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -H 'X-XSRF-Header: PingFederate' | jq '.items'")

  # Display the result and verify
  echo "API Response:"
  echo "${curl_output}"

  # Check if the threshold value we set is present in the API output
  echo "${curl_output}" | grep "\"threadPoolUsageWarningThreshold\": \"0.3\"" >/dev/null 2>&1
  api_status=$?

  # Assert the API status
  assertEquals "Failed to verify the bulkhead configuration via API." 0 "${api_status}"
}

# Shift arguments before loading shunit
shift $#

# Load shunit for running the tests
. ${SHUNIT_PATH}
