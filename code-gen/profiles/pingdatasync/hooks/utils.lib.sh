#!/usr/bin/env sh

. "${HOOKS_DIR}/logger.lib.sh"
. "${HOOKS_DIR}/belugacommon.lib.sh"


########################################################################################################################
# Export values for PingDirectory configuration settings based on single vs. multi cluster.
########################################################################################################################
export_config_settings() {
  export SHORT_HOST_NAME=$(hostname)
  export ORDINAL=${SHORT_HOST_NAME##*-}
  export LOCAL_DOMAIN_NAME="$(hostname -f | cut -d'.' -f2-)"

  # For multi-region:
  # If using NLB to route traffic between the regions, the hostnames will be the same per region (i.e. that of the NLB),
  # but the ports will be different. If using VPC peering (i.e. creating a super network of the subnets) for routing
  # traffic between the regions, then each PD server will be directly addressable, and so will have a unique hostname
  # and may use the same port.

  # NOTE: If using NLB, then corresponding changes will be required to the 80-post-start.sh script to export port 6360,
  # 6361, etc. on each server in a region. Since we have VPC peering in Ping Cloud, all servers can use the same LDAPS
  # port, i.e. 1636, so we don't expose 636${ORDINAL} anymore.

  if is_multi_cluster; then
    export MULTI_CLUSTER=true
    is_primary_cluster &&
      export PRIMARY_CLUSTER=true ||
      export PRIMARY_CLUSTER=false

    # NLB settings:
    # export PD_HTTPS_PORT="443"
    # export PD_LDAP_PORT="389${ORDINAL}"
    # export PD_LDAPS_PORT="636${ORDINAL}"
    # export PD_REPL_PORT="989${ORDINAL}"

    # VPC peer settings (same as single-region case):
    export PD_HTTPS_PORT="${HTTPS_PORT}"
    export PD_LDAP_PORT="${LDAP_PORT}"
    export PD_LDAPS_PORT="${LDAPS_PORT}"
    export PD_REPL_PORT="${REPLICATION_PORT}"

    export PD_CLUSTER_DOMAIN_NAME="${PD_CLUSTER_PUBLIC_HOSTNAME}"
  else
    export MULTI_CLUSTER=false
    export PRIMARY_CLUSTER=true

    export PD_HTTPS_PORT="${HTTPS_PORT}"
    export PD_LDAP_PORT="${LDAP_PORT}"
    export PD_LDAPS_PORT="${LDAPS_PORT}"
    export PD_REPL_PORT="${REPLICATION_PORT}"

    export PD_CLUSTER_DOMAIN_NAME="${LOCAL_DOMAIN_NAME}"
  fi

  export PD_SEED_LDAP_HOST="${K8S_STATEFUL_SET_NAME}-0.${PD_CLUSTER_DOMAIN_NAME}"
  export LOCAL_HOST_NAME="${K8S_STATEFUL_SET_NAME}-${ORDINAL}.${PD_CLUSTER_DOMAIN_NAME}"
  export LOCAL_INSTANCE_NAME="${K8S_STATEFUL_SET_NAME}-${ORDINAL}-${REGION_NICK_NAME}"

  # Figure out the list of DNs to initialize replication on
  DN_LIST=
  BASE_DNS_LIST="${USER_BASE_DN} ${USER_BASE_DN_2} ${USER_BASE_DN_3} ${USER_BASE_DN_4} ${USER_BASE_DN_5}"
  # Separate each USER_BASE_DN with a ';'
  BASE_DNS_LIST=$(echo ${BASE_DNS_LIST} | tr '[[:blank:]]/' ';')

  if test -z "${REPLICATION_BASE_DNS}"; then
    DN_LIST="${BASE_DNS_LIST}"
  else
    # Separate each USER_BASE_DN with a '|' to grep with a regex pattern.
    # Example: grep -qE "dc=example,dc=com|dc=test,dc=com"
    GREP_BASE_DNS_LIST=$(echo ${BASE_DNS_LIST} | tr ';' '|')
    echo "${REPLICATION_BASE_DNS}" | grep -qE "${GREP_BASE_DNS_LIST}"
    test $? -eq 0 &&
      DN_LIST="${REPLICATION_BASE_DNS}" ||
      DN_LIST="${REPLICATION_BASE_DNS};${BASE_DNS_LIST}"
  fi

  export DNS_TO_ENABLE=$(echo "${DN_LIST}" | tr ';' ' ')
  export POST_START_INIT_MARKER_FILE="${SERVER_ROOT_DIR}"/config/post-start-init-complete

  beluga_log "MULTI_CLUSTER - ${MULTI_CLUSTER}"
  beluga_log "PRIMARY_CLUSTER - ${PRIMARY_CLUSTER}"
  beluga_log "PD_HTTPS_PORT - ${PD_HTTPS_PORT}"
  beluga_log "PD_LDAP_PORT - ${PD_LDAP_PORT}"
  beluga_log "PD_LDAPS_PORT - ${PD_LDAPS_PORT}"
  beluga_log "PD_REPL_PORT - ${PD_REPL_PORT}"
  beluga_log "PD_CLUSTER_DOMAIN_NAME - ${PD_CLUSTER_DOMAIN_NAME}"
  beluga_log "PD_SEED_LDAP_HOST - ${PD_SEED_LDAP_HOST}"
  beluga_log "LOCAL_HOST_NAME - ${LOCAL_HOST_NAME}"
  beluga_log "LOCAL_INSTANCE_NAME - ${LOCAL_INSTANCE_NAME}"
  beluga_log "DNS_TO_ENABLE - ${DNS_TO_ENABLE}"
}

########################################################################################################################
# Get LDIF for the base entry of USER_BASE_DN(s) and return the LDIF file as stdout
# Add ds-sync-generation-id: -1 to attribute if this is a first time deployment of a child non-seed server
########################################################################################################################
get_base_entry_ldif() {
  local base_dn="${1}"

  COMPUTED_DOMAIN=$(echo "${base_dn}" | sed 's/^dc=\([^,]*\).*/\1/')
  COMPUTED_ORG=$(echo "${base_dn}" | sed 's/^o=\([^,]*\).*/\1/')

  USER_BASE_ENTRY_LDIF=$(mktemp)

  if ! test "${base_dn}" = "${COMPUTED_DOMAIN}"; then
    cat >"${USER_BASE_ENTRY_LDIF}" <<EOF
dn: ${base_dn}
objectClass: top
objectClass: domain
dc: ${COMPUTED_DOMAIN}
EOF
  elif ! test "${base_dn}" = "${COMPUTED_ORG}"; then
    cat >"${USER_BASE_ENTRY_LDIF}" <<EOF
dn: ${base_dn}
objectClass: top
objectClass: organization
o: ${COMPUTED_ORG}
EOF
  else
    beluga_error "User base DN must be either 1 or 2-level deep, for example: dc=foobar,dc=com or o=data"
    return 80
  fi

  # Append by setting ds-sync-generation-id to -1 if this is a first time deployment of a child non-seed server
  if is_first_time_deploy_child_server; then
    cat >> "${USER_BASE_ENTRY_LDIF}" <<EOF
ds-sync-generation-id: -1
EOF
  fi

  # Append some required ACIs to the base entry file. Without these, PF SSO will not work.
  cat >>"${USER_BASE_ENTRY_LDIF}" <<EOF
aci: (targetattr!="userPassword")(version 3.0; acl "Allow self-read access to all user attributes except the password"; allow (read,search,compare) userdn="ldap:///self";)
aci: (targetattr="*")(version 3.0; acl "Allow users to update their own entries"; allow (write) userdn="ldap:///self";)
aci: (targetattr="* || +")(version 3.0; acl "Allow PF Administrator to update user entries"; allow (all,proxy) groupdn="ldap:///cn=pfadmingrp,ou=Groups,o=platformconfig";)
aci: (targetattr="* || +")(version 3.0; acl "Grant full access for the PingDataSync user"; allow (all) userdn="ldap:///cn=pingdatasync,cn=Root DNs,cn=config";)
aci: (targetcontrol="1.3.6.1.4.1.30221.2.5.5")(version 3.0; acl "Grant Ignore NO-USER-MODIFICATION Request Control for PingDataSync"; allow (all) userdn="ldap:///cn=pingdatasync,cn=Root DNs,cn=config";)
EOF

  echo "${USER_BASE_ENTRY_LDIF}"
}

########################################################################################################################
# Add the base entry of USER_BASE_DN(s) if it needs to be added
########################################################################################################################
add_base_entry_if_needed() {

  # Easily access all global variables of user_backend_ids for PingDirectory
  local user_backend_ids="${USER_BACKEND_ID} \
			  ${USER_BACKEND_ID_2} \
			  ${USER_BACKEND_ID_3} \
			  ${USER_BACKEND_ID_4} \
			  ${USER_BACKEND_ID_5}"

  local error_msg=

  # Iterate over all backends and get it's corresponding DN
  for backend_key in ${user_backend_ids}; do
    dn_value=$(get_base_dn_using_backend_id "${backend_key}")

    if [ -z "${dn_value}" ]; then
      beluga_log "Backend '${backend_key}' base DN is empty. Skipping..."

      # Continue to the next backend as its base DN is disabled
      continue
    fi

    beluga_log "Checking if backend_id: ${backend_key}, dn: ${dn_value} base entry needs to be added to the PingDirectory server"

    num_user_entries=$(dbtest list-entry-containers --backendID "${backend_key}" 2>/dev/null |
      grep -i "${dn_value}" | awk '{ print $4; }')
    beluga_log "Number of sub entries of DN ${dn_value} in ${backend_key} backend: ${num_user_entries}"

    if test "${num_user_entries}" && test "${num_user_entries}" -gt 0; then
      beluga_log "Replication base DN ${dn_value} already added"
    else
      base_entry_ldif=$(get_base_entry_ldif "${dn_value}")
      get_entry_status=$?
      beluga_log "get user base entry status: ${get_entry_status}"

      if test ${get_entry_status} -ne 0; then
        error_msg="${error_msg} backend_id:${backend_key} with dn:${dn_value} \
						   failed to get base entry ldif entry: ${get_entry_status}"

        # Continue to next backend, due to error
        continue
      fi

      beluga_log "Adding replication base DN ${dn_value} with contents:"
      cat "${base_entry_ldif}"

      import-ldif -n "${backend_key}" -l "${base_entry_ldif}" \
        --includeBranch "${dn_value}" --overwriteExistingEntries
      import_status=$?
      beluga_log "import user base entry status: ${import_status}"

      if test ${import_status} -ne 0; then
        error_msg="${error_msg} backend_id:${backend_key} with dn:${dn_value} \
								failed to import base entry: ${import_status}"

        # Continue to next backend, due to error
        continue
      fi
    fi
  done

  if [ -n "${error_msg}" ]; then
    beluga_error "The following backend and DN failed when attempting to import its base entries into the server"
    beluga_error "${error_msg}"
    return 1
  fi
}

########################################################################################################################
# Rebuilds indexes for backends
########################################################################################################################
rebuildIndex() {
  local base_dn="${1}"

  beluga_log "Rebuilding any new or untrusted indexes for base DN ${base_dn}"
  rebuild-index --bulkRebuild new --bulkRebuild untrusted --baseDN "${base_dn}" &>/tmp/rebuild-index.out
  rebuild_index_status=$?
  if test ${rebuild_index_status} -ne 0; then
    beluga_error "rebuild-index tool status of ${base_dn}: ${rebuild_index_status}"
    cat /tmp/rebuild-index.out
    return ${rebuild_index_status}
  fi
}

########################################################################################################################
# Multiple User base Dns and backend ids
#
# Arguments
#   ${1} -> backend name
#   ${2} -> user base dn
########################################################################################################################
create_backend() {
  local backend_name="${1}"
  local base_dn="${2}"
  local backends_dsconfig_filepath="${PD_PROFILE}/dsconfig/00-backends-initialize.dsconfig"

  cat <<EOF >>"${backends_dsconfig_filepath}"

dsconfig create-backend \
    --backend-name "${backend_name}" \
    --type local-db \
    --set enabled:true \
    --set prime-method:none \
    --set base-dn:"${base_dn}"
EOF

}

########################################################################################################################
# Create Multiple User base Dns and backend ids
########################################################################################################################
create_backends_dsconfig() {
  # Easily access user backend_ids for PingDirectory
  all_backend_ids="${USER_BACKEND_ID_2} \
      ${USER_BACKEND_ID_3} \
      ${USER_BACKEND_ID_4} \
      ${USER_BACKEND_ID_5}"

  # Iterate over all backends and get it's corresponding DN
  for backend_key in ${all_backend_ids}; do
    dn_value=$(get_base_dn_using_backend_id "${backend_key}")

    # If the USER_BASE_DN_# (aka dn_value) is set then create its backend
    if test -n "${dn_value}"; then
      create_backend "${backend_key}" "${dn_value}"
    fi
  done
}

########################################################################################################################
# Offline Enablement for backends
########################################################################################################################
offline_enable_command() {
  local backendid="${1}"
  local base_dn="${2}"

  beluga_log "configuring ${backendid} for base DN ${base_dn}"
  dsconfig --no-prompt --offline set-backend-prop \
    --backend-name "${backend_id}" \
    --add "base-dn:${base_dn}" \
    --set enabled:true
  config_status=$?
  beluga_log "configure base DN ${base_dn} update status: ${config_status}"
  return ${config_status}
}

########################################################################################################################
# Enable the replication sub-system in offline mode.
########################################################################################################################
offline_enable_replication() {

  # Enable replication offline.
  "${HOOKS_DIR}"/185-offline-enable-wrapper.sh
  enable_status=$?
  beluga_log "offline replication enable status: ${enable_status}"
  test ${enable_status} -ne 0 && return ${enable_status}

  return 0
}

########################################################################################################################
# Get backend corresponding DN.
# Returns
#   DN of backend_id.
########################################################################################################################
get_base_dn_using_backend_id() {
  # Build a map/dictionary by storing backend_id as keys and its value as its corresponding DN.

  # To create map/dictionary use the eval command to set the backend_id real value as variables
  # This will be called, _backend_id_key, variable.
  # The _backend_id_key will be equal to its corresponding DN
  #
  # e.g.
  #      => _backend_id_key real value 'appintegrations' will be set as DN value 'o=appintegrations'
  #      => _backend_id_key real value 'platformconfig'  will be set as DN value 'o=platformconfig'
  #      => _backend_id_key real value 'userRoot'        will be set as DN value 'dc=example,dc=com'
  #
  # So in summary bourne-shell will create following variables in memory:
  # local appintegrations=o=appintegrations
  # local platformconfig=o=platformconfig
  # local userRoot=dc=example,dc=com
  eval local $(echo "${PLATFORM_CONFIG_BACKEND_ID}"=)"${PLATFORM_CONFIG_BASE_DN}"
  eval local $(echo "${APP_INTEGRATIONS_BACKEND_ID}"=)"${APP_INTEGRATIONS_BASE_DN}"
  eval local $(echo "${USER_BACKEND_ID}"=)"${USER_BASE_DN}"
  eval local $(echo "${USER_BACKEND_ID_2}"=)"${USER_BASE_DN_2}"
  eval local $(echo "${USER_BACKEND_ID_3}"=)"${USER_BASE_DN_3}"
  eval local $(echo "${USER_BACKEND_ID_4}"=)"${USER_BASE_DN_4}"
  eval local $(echo "${USER_BACKEND_ID_5}"=)"${USER_BASE_DN_5}"

  _backend_id_key="${1}"

  # Using eval echo commands, return DN
  # e.g.
  # echo ${appintegrations} will return o=appintegrations
  # echo ${platformconfig} will return o=platformconfig
  # echo ${userRoot} will return dc=example,dc=com
  eval echo \$"${_backend_id_key}"
}

########################################################################################################################
# Attempt to rebuild index of base DN for all backends.
########################################################################################################################
rebuild_base_dn_indexes() {

  # Easily access all global variables of backend_ids for PingDirectory
  local all_backend_ids="${PLATFORM_CONFIG_BACKEND_ID} \
    ${APP_INTEGRATIONS_BACKEND_ID} \
    ${USER_BACKEND_ID} \
    ${USER_BACKEND_ID_2} \
    ${USER_BACKEND_ID_3} \
    ${USER_BACKEND_ID_4} \
    ${USER_BACKEND_ID_5}"

  local ERROR_MSG=

  # Iterate over all backends and get its corresponding DN
  for backend_key in ${all_backend_ids}; do
    dn_value=$(get_base_dn_using_backend_id "${backend_key}")
    if [ -z "${dn_value}" ]; then
      beluga_log "Backend '${backend_key}' base DN is empty. Skipping..."

      # Continue to the next backend as its base DN is disabled
      continue
    fi

    beluga_log "Checking if backend_id: ${backend_key}, dn: ${dn_value} needs its indexes rebuilt"

    # Rebuild indexes, if necessary for DN.
    if dbtest list-database-containers --backendID "${backend_key}" 2> /dev/null | grep -E '(NEW|UNTRUSTED)'; then
      beluga_log "Rebuilding any new or untrusted indexes for base DN ${dn_value}"
      rebuild-index --bulkRebuild new --bulkRebuild untrusted --baseDN "${dn_value}" 2>> /tmp/rebuild-index.out
      rebuild_index_status=$?

      if test ${rebuild_index_status} -ne 0; then
        ERROR_MSG="${ERROR_MSG} backend_id:${backend_key} with dn:${dn_value} \
          failed during rebuild index: ${rebuild_index_status}"
      fi
    else
      beluga_log "Not rebuilding indexes for backend_id:'${backend_key}' dn:'${dn_value}' as there are no indexes to rebuild with status NEW or UNTRUSTED"
    fi
  done

  if [ -n "${ERROR_MSG}" ]; then
    beluga_error "The following backend and DN failed when attempting to build its indexes"
    beluga_error "${ERROR_MSG}"
    cat /tmp/rebuild-index.out
    return 1
  fi

  return 0
}

# TODO: remove once BRASS fixes export_container_env in:
#   docker-builds/pingcommon/opt/staging/hooks/pingcommon.lib.sh
# CUSTOM Beluga version of export_container_env - overrides the BRASS version to
# add single quotes around the env var value to support spaces in the value,
# but without any unexpected interpolation (e.g. JAVA_OPTS='-D1 -D2')
b_export_container_env() {
  {
    echo ""
    echo "# Following variables set by hook ${CALLING_HOOK}"
  } >> "${CONTAINER_ENV}"

  while test -n "${1}"; do
    _var=${1} && shift
    _val=$(get_value "${_var}")

    # Modified portion - add single quotes
    echo "${_var}='${_val}'" >> "${CONTAINER_ENV}"
  done
}

# Decrypts the file passed in as $1 to $1.decrypted, if it isn't already decrypted
decrypt_file() {
  FILE_TO_DECRYPT=$1
  if test ! -f "${FILE_TO_DECRYPT}.decrypted"; then
    encrypt-file --decrypt \
      --input-file "${FILE_TO_DECRYPT}" \
      --output-file "${FILE_TO_DECRYPT}.decrypted" ||
      (beluga_warn "Error decrypting" && exit 0)
  fi
}

########################################################################################################################
# Set the default user permissions that is set in the server-profile/pingdirectory/default-permissions directory.
# This logic will copy the default-permissions directory to the pd.profile/ldif directory
########################################################################################################################
set_default_user_permissions() {
  local pd_profile_root_target_dir="${PD_PROFILE}/ldif"
  local default_permissions_root_source_dir="${STAGING_DIR}/default-permissions"

  # Iterate through each file in the default-permissions directory and move it to pd.profile/ldif
  find "${default_permissions_root_source_dir}" -type f -print0 | while IFS= read -r -d '' default_permissions_source_file; do

    # Within default-permissions folder contain sub-folders like userRoot
    # Extract the relative path of these folders
    # e.g. ./userRoot
    default_permissions_subfolder_rel_path=$(dirname "${default_permissions_source_file#${default_permissions_root_source_dir}}")

    # Append the relative path that was extracted above to pd.profile/ldif target
    # e.g. pd.profile/ldif/userRoot
    pd_profile_subfolder_target_dir="${pd_profile_root_target_dir}/${default_permissions_subfolder_rel_path}"

    # Check if the targeted subfolder from default-permissions doesn't exist in pd.profile/ldif
    # Reasoning: we don't want to override anything if BeOps or anyone else in the future decide to customize pd.profile/ldif directory.
    # We will just ignore this code and won't override if it exists.
    if [ ! -d "${pd_profile_subfolder_target_dir}" ]; then
      # Create the target directory since it doesn't exist
      mkdir -p "${pd_profile_subfolder_target_dir}"

      # Before calling manage-profile setup, extract the first dc value from USER_BASE_DN
      # This will be injected into pd.profile/ldif/userRoot/00-ditstructure.ldif as the variable USER_BASE_NAME

      # e.g. USER_BASE_DN=dc=example,dc=com would set USER_BASE_NAME as 'example'
      # Or USER_BASE_DN=dc=com would set USER_BASE_NAME as 'com'
      export USER_BASE_NAME="${USER_BASE_DN#*=}"
      USER_BASE_NAME=${USER_BASE_NAME%%,*}

      # Use envsubst to substitute environment variables and save the output to the target location
      envsubst < "${default_permissions_source_file}" > "${pd_profile_subfolder_target_dir}/$(basename "${default_permissions_source_file}")"
    fi
  done
}

########################################################################################################################
# Get the names of all the pingdirectory pods that are successfully running within cluster.
# Returns
#   pingdirectory pod names per line
#   OR
#   Nothing
########################################################################################################################
get_all_running_pingdirectory_pods() {
  # Use jsonpath to:
  # 1) extract all pingdirectory pod names using "metadata.name" property
  # 2) extract every container within pod status using "status.containerStatuses[*].ready" property
  # Then, use 'awk' to filter out only those pods where all containers have a 'ready' status of 'true'.
  local pods
  pods=$(kubectl get pods \
      -l class=pingdirectory-server \
      --sort-by='{.metadata.name}' \
      --output=jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[*].ready}{"\n"}{end}' |\
        awk '$2=="true"{print $1}')
  kubectl_status=$?

  if test ${kubectl_status} -ne 0; then
    # Return nothing
    echo -e ""
  fi

  echo -e "${pods}"
}

########################################################################################################################
# Get the names of all the pingdirectory pods (except for current pod that executes this method) that are
# successfully running within cluster.
# Returns
#   pingdirectory pod names per line
#   OR
#   Nothing
########################################################################################################################
get_other_running_pingdirectory_pods() {
  pods=$(get_all_running_pingdirectory_pods)
  local other_pingdirectory_pods=""
  for current_pingdirectory_pod in ${pods}; do
    if test "${SHORT_HOST_NAME}" = "${current_pingdirectory_pod}"; then
      # Skip current pod that executes this method
      continue
    fi
    other_pingdirectory_pods="${current_pingdirectory_pod}\n"
  done
  echo -e "${other_pingdirectory_pods}"
}

########################################################################################################################
# Detect if this is the first pingdirectory pod within the cluster.
# This method doesn't just assume pingdirectory-0 as the first pod it filters successful pods only.
# Returns
#   True, if there are no other success pingdirectory pods running in cluster
#   False, if there are other successful pingdirectory pods currently running in the cluster
########################################################################################################################
is_first_pingdirectory_pod_in_cluster() {
  other_successful_pods=$(get_other_running_pingdirectory_pods)

  if test -z "${other_successful_pods}"; then
    return 0 # Return true, there are no other success pingdirectory pods running in cluster
  fi

  return 1 # Return false
}

########################################################################################################################
# Return true if this pingdirectory pod is a 1st time deployment and is the 2nd(or more) successful pod to be deployed
# into the cluster.
#
# If true, this pod is consider as a child server.
# Child servers can also be referenced as a non-seed server.
#
# Child servers are detected differently by region:
# 1) In primary region, if the pod is the 2nd(or more) pod running in the cluster then this is considered to be a
#                       child non-seed server
# 2) In secondary region, all pods are considered a child non-seed server because primary region
#                       always deploy before secondary
# Returns
#   True, if child server is detected
#   False, as the default
########################################################################################################################
is_first_time_deploy_child_server() {
  # Detect if this is a first time deployment (1st time PVC mounting to pod)
  if [ "${PD_LIFE_CYCLE}" = "START" ]; then
    if (is_primary_cluster && ! is_first_pingdirectory_pod_in_cluster) || is_secondary_cluster; then
      return 0 # Return true
    fi
  fi

  return 1 # Return false as the default
}

########################################################################################################################
# Add ds-sync-generation-id: -1 attribute to all backends base_dn
########################################################################################################################
add_sync_generation_id_to_base_dn() {
  # Easily access all global variables of base_dns for PingDirectory
  all_base_dns="${PLATFORM_CONFIG_BASE_DN} \
    ${APP_INTEGRATIONS_BASE_DN} \
    ${USER_BASE_DN} \
    ${USER_BASE_DN_2} \
    ${USER_BASE_DN_3} \
    ${USER_BASE_DN_4} \
    ${USER_BASE_DN_5}"

  # Iterate over all base DNs by searching for its DIT file within pd.profile/ldif/<backend>/<whatever>.ldif
  # Once found add 'ds-sync-generation-id: -1' to its base DN
  modify_ldif=$(mktemp)
  for base_dn in ${all_base_dns}; do

    if [ -z "${base_dn}" ]; then
      # Continue to the next backend as its base DN is disabled
      continue
    fi

    cat > "${modify_ldif}" <<EOF
dn: ${base_dn}
changetype: modify
add: ds-sync-generation-id
ds-sync-generation-id: -1
EOF

    # Use -E flag to provide regex
    # '\s*' matches zero or more whitespace characters between 'dn:' and base_dn
    # e.g. the following will still be found in PD_PROFILE
    # a) No space
    # dn:dc=example,dc=com
    # b) 1 space
    # dn: dc=example,dc=com
    # c) Multiple spaces
    # dn:     dc=example,dc=com
    profile_ldif=$(grep -rlE "dn:\s*${base_dn}" "${PD_PROFILE}"/ldif/* | head -1)
    if test ! -z "${profile_ldif}"; then
      ldifmodify --doNotWrap \
                 --suppressComments \
                 --sourceLDIF ${profile_ldif} \
                 --changesLDIF ${modify_ldif} \
                 --targetLDIF ${profile_ldif}
      ldif_status=$?

      if test ${ldif_status} -ne 0; then
        beluga_error "Adding 'ds-sync-generation-id: -1' to base dn, ${base_dn}, failed with status: ${ldif_status}"
        cat "${modify_ldif}"
        rm -f "${modify_ldif}"
        return ${add_base_entry_status}
      fi
    fi
  done

  rm -f "${modify_ldif}"
  return 0
}

########################################################################################################################
# TODO : We need to cleanup this below method when all the customers are upgraded to 1.19/PDv9.3
# PD team removed an undocumented workaround "issue-ds-46516-allow-multiple-pta-plugin-instances" from
# v9.3 and making it officially supported but with different set of config. So to upgrade from v9.2 to
# v9.3 we have to reset the undocumented workaround before exporting the old server configurations.
# Below approach would reset the use-undocumented-workaround only during the time of upgrade and
# not on every restart after upgrade.
########################################################################################################################
validate_and_reset_workaround() {

    beluga_log "Checking for undocumented-workaround 'issue-ds-46516-allow-multiple-pta-plugin-instances' from previous versions"
    # using the offline flag below because, at this point of time PD server will not be in a running state
    dsconfig get-global-configuration-prop --property use-undocumented-workaround \
                                --offline --no-prompt | grep -i "issue-ds-46516-allow-multiple-pta-plugin-instances"
    workaround_status=$?
    if [[ ${workaround_status} -eq 0 ]]; then
      # using the offline flag below because, at this point of time PD server will not be in a running state
      beluga_log "Resetting the global configuration property use-undocumented-workaround"
      dsconfig set-global-configuration-prop --reset use-undocumented-workaround --offline --no-prompt > /dev/null
      reset_status=$?
      if [[ ${reset_status} -ne 0 ]]; then
        beluga_warn "There is an error when resetting undocumented-workarounds"
      else
        beluga_log "Reset undocumented-workaround done successfully"
      fi
    else
      beluga_log "Reset undocumented-workaround is not required"
    fi
}

########################################################################################################################
# Function to capture alerts and alarms in PD liveness and readiness probes
#
########################################################################################################################
capture_alarms_and_alerts() {
    # 1. Convert current time in seconds: $(date +%s)
    # 2. Subtract 600 seconds (which is 10 minutes ago)
    # 3. Gather format: "%Y%m%d%H%M%S".000Z
    #    %Y   - Year ####
    #    %m   - Month ##
    #    %d   - Day ##
    #    %H   - 24-hour
    #    %M   - Minute ##
    #    %S   - Second ##
    #    .000 - Millisecond
    #    Z    - UTC
    ten_minutes_ago=$(date -u -d @$(($(date +%s) - 600)) +"%Y%m%d%H%M%S").000Z

    # Capture Alarms
    ldifsearch \
        --ldifFile /opt/out/instance/config/alarms.ldif \
        --baseDN "cn=alarms" \
        --scope sub "(|(ds-alarm-warning-last-time>=$ten_minutes_ago)(ds-alarm-indeterminate-last-time>=$ten_minutes_ago))" >"${OUT_DIR}/last-ten-min-alarms.json"

    # Capture Alerts
    ldifsearch \
        --ldifFile /opt/out/instance/config/alerts.ldif \
        --baseDN "cn=alerts" \
        --scope sub "(ds-alert-time>=$ten_minutes_ago)" >"${OUT_DIR}/last-ten-min-alerts.json"

    beluga_log "Printing last ten mins Alarms"
    cat "${OUT_DIR}/last-ten-min-alarms.json"

    beluga_log "Printing last ten mins  Alerts"
    cat "${OUT_DIR}/last-ten-min-alerts.json"
}

# These are needed by every script - so export them when this script is sourced.
beluga_log "export config settings"
export_config_settings