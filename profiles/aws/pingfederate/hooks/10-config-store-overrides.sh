#!/usr/bin/env sh
#
# Script Return Code:
#
#  0: Success
#  1: Non-fatal error, all requests processed before aborting (show all errors) 
#  2: Fatal error, something totally unexpected occured, exit immediately.
#
${VERBOSE} && set -x

. "${HOOKS_DIR}/pingcommon.lib.sh"
. "${HOOKS_DIR}/utils.lib.sh"

#---------------------------------------------------------------------------------------------
# Main Script
#---------------------------------------------------------------------------------------------

#
# Run Pingfederate on localhost interface to complete configuration prior to exposing the
# admin server to the external environment. This also takes care of cases where a restart
# is necessary following a change.
#
wd=$(pwd)
cd /opt/out/instance/bin
cp run.properties run.properties.bak
sed -i -e 's/pf.console.bind.address=0.0.0.0/pf.console.bind.address=127.0.0.1/' run.properties
./run.sh &
wait_for_admin_api_endpoint 
#
# Restore run properties now we've started the server.
#
cp run.properties.bak run.properties
#
# Apply config store overrides to server. the script is expected to run from the hooks 
# directory and the config-store overrides directory is expected to be a sibling of hooks
#
cd $(dirname $(dirname $0))/config-store

if [ $(ls *.json | wc -l) -gt 0 ]; then
   #
   # Overrides exist, process directroy contents in lexicographical order              
   #
   echo "==========================  Applying config store static overrides ==========================="
   #
   # Assume Success, we will attempt to process everything to catch all errors in one pass
   #
   rc=0
   for file in $(ls *.json |sort |tr '$\n' ' '); do
      #
      # Only process files
      #
      if [ -f "${file}" ]; then
         #
         # Load file for processing
         #
         bundle=$(cat ./${file})
         #
         # Extract data from file
         #
         target=$(echo "${bundle}" | jq -r '.bundle')
         method=$(echo "${bundle}" | jq -r '.method'| tr "abcdefghijklmnopqrstuvwxyz" "ABCDEFGHIJKLMNOPQRSTUVWZYZ")
         payload=$(echo "${bundle}" | jq -r '.payload')
         id=$(echo "${payload}" | jq -r '.id')
         #
         # Validate Method, only PUT, DEL(ETE) allowed
         #
         if [ "${method}" = "PUT" ] || [ "${method}" = "DEL" ] || [ "${method}" = "DELETE" ]; then
            #
            # Construct API Call to get current value
            #
            oldValue=$(curl -s -k \
                -H 'X-Xsrf-Header: PingFederate' \
                -H 'Accept: application/json' \
                -u "Administrator:${PF_ADMIN_USER_PASSWORD}" \
                -w '%{http_code}' \
                -X GET \
                "https://localhost:9999/pf-admin-api/v1/configStore/${target}/${id}")
            result=$(echo "${oldValue:$(echo "${#oldValue} -3" |bc)}" | tr -d '$\n')
            oldValue=$(echo "${oldValue:0:-3}" | tr -d '$\n' )
            #
            # An http response of 404 means the item wasn't found, this may or may not
            # be an error in the request, there is no way to tell. If this is a delete
            # operation then we may have already delted it on a prior start. If this is
            # a put operation then the value could be new, for example overriding an 
            # undefined default value. 
            #
            if [ "${result}" != "200" ] && [ "${result}" != "404" ]; then
               #
               # Something Unexpected Happened 
               #
               oldValue="Unexpected Error occurred, HTTP Status: ${result}"
               newValue=""
               rc=2
            else   
               if [ "${result}" = "404" ]; then
                  oldValue="Item not found in configuration store"
               fi
               #
               #  Construct API call to Change/delete value
               #
               case ${method} in
                  DEL | DELETE)
                     #
                     # Process delete request
                     #
                     if [ "${result}" = "404" ]; then
                        #
                        # Non-existent entity, ignore request.
                        #
                        newValue=""
                     else
                        result=$(curl -s -k \
                                 -H 'X-Xsrf-Header: PingFederate' \
                                 -H 'Accept: application/json' \
                                 -u "Administrator:${PF_ADMIN_USER_PASSWORD}" \
                                 -w '%{http_code}' \
                                 -o /dev/null \
                                 -X DELETE \
                                 "https://localhost:9999/pf-admin-api/v1/configStore/${target}/${id}")
                        case ${result} in
                           404)
                              newValue="Entity disappeared between read and delete!"
                              rc=1
                              ;;
                           403)
                              newValue="Bundle not available - unable to process request!"
                              rc=1
                              ;;
                           204)
                              newValue="Entity deleted!"
                              ;;
                           *)
                              newValue="Unexpected Error occurred HTTP status: ${result}"
                              rc=2
                              ;;
                        esac
                     fi
                     ;;
                
                  PUT)
                     #
                     # Process put request
                     #
                     newValue=$(curl -s -k \
                                 -H 'X-Xsrf-Header: PingFederate' \
                                 -H 'Accept: application/json' \
                                 -H "Content-Type: application/json" \
                                 -u "Administrator:${PF_ADMIN_USER_PASSWORD}" \
                                 -w '%{http_code}' \
                                 -d "${payload}" \
                                 -X PUT \
                                 "https://localhost:9999/pf-admin-api/v1/configStore/${target}/${id}")
                     result="${newValue##*\}}"
                     newValue=$(echo "${newValue:0:-3}" | tr -d '$\n')
                     case ${result} in
                        422)
                           newValue="Validation Error occurred: ${newValue}"
                           rc=1
                           ;;
                        403)
                           newValue="Bundle not available - unable to process request!"
                           rc=1
                           ;;
                        200)
                           ;;
                        *)
                           newValue="Unexpected Error occurred HTTP status: ${result}"
                           rc=2
                           ;;
                     esac
                     ;;
                  *)
                     rc=2
                     ;;
               esac
               
               echo "${separator}"
               echo "Processing Override: ${file}"
               echo "Bundle:              ${target}"
               echo "Id:                  ${id}"
               echo "Operation:           ${method}"
               echo "Payload:             $(echo "${payload}" | tr '$\n' ' ')"
               echo ""
               echo "HTTP Response code:  ${result}"
               echo "Old Value:           ${oldValue}"
               echo "New Value:           ${newValue}"
               separator="----------------------------------------------------------------------------------------------"
           fi
         fi
      fi
      if [ "${rc}" = "2" ]; then
         break
      fi
   done
   echo "===========================  Config store static overrides applied ==========================="
fi
#
# Shut down temporary PingFederate instance
#
cd /opt/out/instance/bin
pid=$(cat pingfederate.pid)
kill ${pid}
echo "Waiting for PingFederate to shutdown" 
while [  "$(netstat -lntp|grep 9999|grep "${pid}/java" >/dev/null 2>&1;echo $?)" = "0" ]; do
   sleep 1
done   
cd ${wd}
exit ${rc}
