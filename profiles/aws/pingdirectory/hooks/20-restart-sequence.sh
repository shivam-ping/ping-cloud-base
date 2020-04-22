#!/usr/bin/env sh

${VERBOSE} && set -x

. "${HOOKS_DIR}/pingcommon.lib.sh"
test -f "${HOOKS_DIR}/pingdata.lib.sh" && . "${HOOKS_DIR}/pingdata.lib.sh"

echo "Restarting container"

# Before running any ds tools, remove java.properties and re-create it
# for the current JVM.
echo "Re-generating java.properties for current JVM"
rm -f "${SERVER_ROOT_DIR}/config/java.properties"
dsjavaproperties

# If this hook is provided it can be executed early on
run_hook "21-update-server-profile.sh"

export encryptionOption=$(getEncryptionOption)
export jvmOptions=$(getJvmOptions)

echo "Checking license file"
_currentLicense="${LICENSE_DIR}/${LICENSE_FILE_NAME}"
_pdProfileLicense="${STAGING_DIR}/pd.profile/server-root/pre-setup/${LICENSE_FILE_NAME}"

if test ! -f "${_pdProfileLicense}" ; then
  echo "Copying in license from existing install."
  echo "  ${_currentLicense} ==> "
  echo "    ${_pdProfileLicense}"
  cp -af "${_currentLicense}" "${_pdProfileLicense}"
fi

ORIG_UNBOUNDID_JAVA_ARGS="${UNBOUNDID_JAVA_ARGS}"
HEAP_SIZE_INT=$(echo "${MAX_HEAP_SIZE}" | grep 'g$' | cut -d'g' -f1)

if test ! -z "${HEAP_SIZE_INT}" && test "${HEAP_SIZE_INT}" -ge 4; then
  NEW_HEAP_SIZE=$((HEAP_SIZE_INT - 2))g
  echo "Changing manage-profile heap size to ${NEW_HEAP_SIZE}"
  export UNBOUNDID_JAVA_ARGS="-client -Xmx${NEW_HEAP_SIZE} -Xms${NEW_HEAP_SIZE}"
fi

echo "Merging changes from new server profile"
"${SERVER_BITS_DIR}"/bin/manage-profile replace-profile \
    --serverRoot "${SERVER_ROOT_DIR}" \
    --profile "${STAGING_DIR}/pd.profile" \
    --useEnvironmentVariables \
    --reimportData never

MANAGE_PROFILE_STATUS=${?}
echo "manage-profile replace-profile status: ${MANAGE_PROFILE_STATUS}"

export UNBOUNDID_JAVA_ARGS="${ORIG_UNBOUNDID_JAVA_ARGS}"

test "${MANAGE_PROFILE_STATUS}" -ne 0 && exit 20

run_hook "185-apply-tools-properties.sh"

# FIXME: replace-profile has a bug where it may wipe out the user root backend configuration and lose user data added
# from another server while enabling replication. This code block may be removed when replace-profile is fixed.
echo "Configuring ${USER_BACKEND_ID} for base DN ${USER_BASE_DN}"
dsconfig --no-prompt --offline set-backend-prop \
  --backend-name "${USER_BACKEND_ID}" \
  --add "base-dn:${USER_BASE_DN}" \
  --set enabled:true \
  --set db-cache-percent:35
CONFIG_STATUS=${?}

echo "Configure base DN ${USER_BASE_DN} update status: ${CONFIG_STATUS}"
test "${CONFIG_STATUS}" -ne 0 && exit ${CONFIG_STATUS}

exit 0