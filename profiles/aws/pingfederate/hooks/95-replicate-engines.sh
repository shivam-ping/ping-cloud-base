#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

${VERBOSE} && set -x

OUT=$( make_api_request -X GET https://localhost:9999/pf-admin-api/v1/cluster/status )
test ${?} -ne 0 && echo "Failed GET request => /cluster/status" && exit 1

# Exit script if replication isn't required.
IS_REPLICATION_REQUIRED=$(jq -n "${OUT}" | jq '.replicationRequired' )
test "${IS_REPLICATION_REQUIRED}" != "true" && echo "No replication needed, engine(s) are in sync" && exit 0

# There are a couple of scenarios that can occur here as the admin replicates to the engines:
# Scenario 1: On initial deploy, there will be 0 engines. This is fine as the engines
#             will be getting the admin configuration as its pod spin up. Calling
#             replicate API will hide the replication banner in admin UI.
#
# Scenario 2: Admin has restarted while engines are running. As the admin comes
#             up it will replicate its changes to the running engines.

echo "Beginning to replicate the engine(s)"
make_api_request -X POST https://localhost:9999/pf-admin-api/v1/cluster/replicate
test ${?} -ne 0 && echo "Could not replicate, failed POST request => /cluster/replicate" && exit 1
echo "Replication to engine(s) was successful"

exit 0