#!/usr/bin/env sh

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

test -f "${HOOKS_DIR}/pingdirectory.lib.sh" && . "${HOOKS_DIR}/pingdirectory.lib.sh"

########################################################################################################################
# Change the password of the provided user.
#
# Arguments
#   ${1} -> The DN of the user.
#   ${2} -> The file containing the new password file in clear text.
#   ${3} -> Any optional control to be used with the LDAP modify request.
########################################################################################################################
change_user_password() {
  USER_DN="${1}"
  NEW_PASSWORD_FILE="${2}"
  CONTROL="${3}"

  beluga_log "resetting password for user DN: ${USER_DN}"
  if test -z "${CONTROL}"; then
    ldappasswordmodify \
      --authzID "dn:${USER_DN}" \
      --newPasswordFile "${NEW_PASSWORD_FILE}"
  else
    ldappasswordmodify \
      --authzID "dn:${USER_DN}" \
      --newPasswordFile "${NEW_PASSWORD_FILE}" \
      --control "${CONTROL}"
  fi

  pwdModStatus=$?
  beluga_log "password reset for DN ${USER_DN} status: ${pwdModStatus}"

  # The following exit codes are acceptable:
  # 0 -> success
  # 32 -> user does not exist
  # 53 -> old and new passwords are the same
  if test ${pwdModStatus} -ne 0 && test ${pwdModStatus} -ne 32 && test ${pwdModStatus} -ne 53; then
    return ${pwdModStatus}
  fi

  return 0
}

########################################################################################################################
# Change the passwords of the PF administrator user and the internal user that PF uses to communicate with PD.
########################################################################################################################
change_pf_user_passwords() {
  PASS_FILE=$(mktemp)

  echo "${PF_ADMIN_USER_PASSWORD}" > "${PASS_FILE}"
  change_user_password 'uid=administrator,ou=admins,o=platformconfig' "${PASS_FILE}"
  pwdModStatus=$?
  test ${pwdModStatus} -ne 0 && return ${pwdModStatus}

  echo "${PF_LDAP_PASSWORD}" > "${PASS_FILE}"
  change_user_password 'uid=pingfederate,ou=devopsaccount,o=platformconfig' "${PASS_FILE}"
  pwdModStatus=$?
  test ${pwdModStatus} -ne 0 && return ${pwdModStatus}

  return 0
}

########################################################################################################################
# Initialize replication for the provided base DN on this server.
#
# Arguments
#   ${1} -> The base DN for which to initialize replication.
#   ${2} -> An optional timeout (in seconds) for the dsreplication initialize command. If not provided, then a timeout
#           of 0 is assumed, which implies no retries. This argument is intended only for internal use from within the
#           function.
########################################################################################################################
initialize_server_for_dn() {
  BASE_DN=${1}
  TIMEOUT_SECONDS=${2:-0}

  # Initialize the first server in the secondary cluster from the first server in the primary cluster.
  # Initialize all other servers from the first server within the same cluster.
  is_secondary_cluster && test "${ORDINAL}" -eq 0 &&
    FROM_HOST="${K8S_STATEFUL_SET_NAME}-0.${PD_CLUSTER_PUBLIC_HOSTNAME}" ||
    FROM_HOST="${K8S_STATEFUL_SET_NAME}-0.${LOCAL_DOMAIN_NAME}"
  FROM_PORT="${PD_LDAPS_PORT}"

  TO_HOST="${K8S_STATEFUL_SET_NAME}-${ORDINAL}.${LOCAL_DOMAIN_NAME}"
  TO_PORT="${PD_LDAPS_PORT}"

  beluga_log "running dsreplication initialize for ${BASE_DN} from ${FROM_HOST}:${FROM_PORT} to ${TO_HOST}:${TO_PORT}"
  dsreplication initialize \
    --trustAll \
    --hostSource "${FROM_HOST}" --portSource "${FROM_PORT}" --useSSLSource \
    --hostDestination "${TO_HOST}" --portDestination "${TO_PORT}" --useSSLDestination \
    --retryTimeoutSeconds "${TIMEOUT_SECONDS}" \
    --baseDN "${BASE_DN}" \
    --adminUID "${ADMIN_USER_NAME}" \
    --adminPasswordFile "${ADMIN_USER_PASSWORD_FILE}" \
    --no-prompt --ignoreWarnings \
    --enableDebug \
    --globalDebugLevel verbose
  replInitResult=$?
  beluga_log "replication initialize for ${BASE_DN} status: ${replInitResult}"

  # Tolerate return code 7 - this means that the base DN does not exist on the source server.
  # When the source server is rolled out, it'll initialize replication to all servers for all DNs.
  if test ${replInitResult} -eq 7; then
    beluga_warn "base DN does not exist on this server - the seed server will initialize this server when it's rolled"
    return 0
  fi

  if test ${replInitResult} -ne 0; then
    beluga_log "contents of dsreplication.log:"
    cat "${SERVER_ROOT_DIR}"/logs/tools/dsreplication.log

    # If it was an initial call to initialize, then try to initialize again with a retry timeout.
    if test "${TIMEOUT_SECONDS}" -eq 0 && test "${RETRY_TIMEOUT_SECONDS}" -ne 0; then
      initialize_server_for_dn "${BASE_DN}" "${RETRY_TIMEOUT_SECONDS}"
      replInitResult=$?
    fi
  fi

  return ${replInitResult}
}

capture_latest_logs() {
  msg="${1}"
  status_code=${2}

  beluga_error "${msg}: ${status_code}"
  beluga_error "The following contains logs from the ${SERVER_ROOT_DIR}/logs/config-audit.log file:"
  tail -100 "${SERVER_ROOT_DIR}/logs/config-audit.log"

  beluga_error "The following contains logs from the ${SERVER_ROOT_DIR}/logs/errors file:"
  tail -100 "${SERVER_ROOT_DIR}/logs/errors"
}

########################################################################################################################
# Perform finalization on exit.
# - On non-zero exit, stop the container to signal failure with the post-start sequence.
# - On success:
#   - Add the marker file signaling that post-start is complete
########################################################################################################################
finalize() {
  if test $? -ne 0; then
    beluga_error "stopping the container to signal failure with post-start sequence"
    stop-server
  fi

  touch "${POST_START_INIT_MARKER_FILE}"
  beluga_log "post-start complete"
}

# --- MAIN SCRIPT ---
beluga_log "starting post-start hook"

# Trap all exit codes from here on so finalization is run
trap "finalize" EXIT

# Remove the post-start initialization marker file so the pod isn't prematurely considered ready
rm -f "${POST_START_INIT_MARKER_FILE}"

beluga_log "running ldapsearch test on this container (${HOSTNAME})"
waitUntilLdapUp localhost "${LDAPS_PORT}" 'cn=config'

beluga_log "pod ordinal: ${ORDINAL}; multi-cluster: ${IS_MULTI_CLUSTER}"

# Change PF user passwords
change_pf_user_passwords
test $? -ne 0 && exit 1

# The request control allows encoded passwords, which is always required for topology admin users
# ldapmodify allows a --passwordUpdateBehavior allow-pre-encoded-password=true to do the same
ALLOW_PRE_ENCODED_PW_CONTROL='1.3.6.1.4.1.30221.2.5.51:true::MAOBAf8='
change_user_password "cn=${ADMIN_USER_NAME}" "${ADMIN_USER_PASSWORD_FILE}" "${ALLOW_PRE_ENCODED_PW_CONTROL}"
test $? -ne 0 && exit 1

# --- NOTE ---
# This assumes that data initialization is only required once for the initial data in the server profile.
# Subsequent initialization of data will be performed externally after populating one of the servers using data
# sync or some other mechanism, like ldapmodidy, followed by dsreplication initialize-all. This assumption may be
# different for each customer, but the script may be easily adjusted as appropriate for the customer's use case.

# Figure out if replication is already initialized for all requested DNs
# All base DNs are already initialized, so we're good.
if test -z "${UNINITIALIZED_DNS}"; then
  beluga_warn "replication is already initialized for all base DNs: ${DNS_TO_ENABLE}"
  exit 0
fi

# If we're told to not initialize data, then skip it
if ! "${INITIALIZE_REPLICATION_DATA}"; then
  beluga_warn "not initializing replication data because INITIALIZE_REPLICATION_DATA is false"
  exit 0
fi

if is_first_time_deploy_child_server; then
  beluga_log "non-seed server - will initialize data from another server"

  command_to_run="initialize_server_for_dn"
  beluga_log "replication will be initialized for base DNs: ${UNINITIALIZED_DNS}"
  for DN in ${UNINITIALIZED_DNS}; do
    ${command_to_run} "${DN}"
    replInitResult=$?

    if test ${replInitResult} -eq 0; then
      beluga_log "adding DN ${DN} to the replication marker file ${REPL_INIT_MARKER_FILE}"
      echo "${DN}" >> "${REPL_INIT_MARKER_FILE}"
    else
      exit 1
    fi
  done
fi

exit 0