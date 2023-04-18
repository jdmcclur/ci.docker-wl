#!/bin/bash
# (C) Copyright IBM Corporation 2022.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Determine if featureUtility ran in an earlier build step
if /opt/ibm/helpers/build/features-installed.sh; then
  FEATURES_INSTALLED=true
else
  FEATURES_INSTALLED=false
fi

if [ "$VERBOSE" != "true" ]; then
  exec &>/dev/null
fi

set -Eeox pipefail

function main() {
  if [ "$FEATURES_INSTALLED" == "false" ]; then
    # Resolve liberty server symlinks and creation for server name changes
    /opt/ibm/helpers/runtime/configure-liberty.sh
    if [ $? -ne 0 ]; then
      exit
    fi
  fi

  ##Define variables for XML snippets source and target paths
  WLP_INSTALL_DIR=/opt/ibm/wlp
  SHARED_CONFIG_DIR=${WLP_INSTALL_DIR}/usr/shared/config
  SHARED_RESOURCE_DIR=${WLP_INSTALL_DIR}/usr/shared/resources

  SNIPPETS_SOURCE=/opt/ibm/helpers/build/configuration_snippets
  SNIPPETS_TARGET=/config/configDropins/overrides
  SNIPPETS_TARGET_DEFAULTS=/config/configDropins/defaults
  mkdir -p ${SNIPPETS_TARGET}
  mkdir -p ${SNIPPETS_TARGET_DEFAULTS}

  #Check for each Liberty value-add functionality

  # MicroProfile Health
  if [ "$MP_HEALTH_CHECK" == "true" ]; then
    cp $SNIPPETS_SOURCE/mp-health-check.xml $SNIPPETS_TARGET/mp-health-check.xml
  fi

  # MicroProfile Monitoring
  if [ "$MP_MONITORING" == "true" ]; then
    cp $SNIPPETS_SOURCE/mp-monitoring.xml $SNIPPETS_TARGET/mp-monitoring.xml
  fi

  # OpenIdConnect Client
  if [ "$OIDC" == "true" ]  || [ "$OIDC_CONFIG" == "true" ]
  then
    cp $SNIPPETS_SOURCE/oidc.xml $SNIPPETS_TARGET/oidc.xml
  fi

  if [ "$OIDC_CONFIG" == "true" ]; then
    cp $SNIPPETS_SOURCE/oidc-config.xml $SNIPPETS_TARGET/oidc-config.xml
  fi

  # HTTP Endpoint
  if [ "$HTTP_ENDPOINT" == "true" ]; then
    if [ "$SSL" == "true" ] || [ "$TLS" == "true" ]; then
      cp $SNIPPETS_SOURCE/http-ssl-endpoint.xml $SNIPPETS_TARGET/http-ssl-endpoint.xml
    else
      cp $SNIPPETS_SOURCE/http-endpoint.xml $SNIPPETS_TARGET/http-endpoint.xml
    fi
  fi

  # Hazelcast Session Caching
  if [ "${HZ_SESSION_CACHE}" == "client" ] || [ "${HZ_SESSION_CACHE}" == "embedded" ]
  then
  cp ${SNIPPETS_SOURCE}/hazelcast-sessioncache.xml ${SNIPPETS_TARGET}/hazelcast-sessioncache.xml
  mkdir -p ${SHARED_CONFIG_DIR}/hazelcast
  cp ${SNIPPETS_SOURCE}/hazelcast-${HZ_SESSION_CACHE}.xml ${SHARED_CONFIG_DIR}/hazelcast/hazelcast.xml
  fi

  # Infinispan Session Caching
  if [[ -n "$INFINISPAN_SERVICE_NAME" ]]; then
  cp ${SNIPPETS_SOURCE}/infinispan-client-sessioncache.xml ${SNIPPETS_TARGET}/infinispan-client-sessioncache.xml
  chmod g+rw $SNIPPETS_TARGET/infinispan-client-sessioncache.xml
  fi
  # IIOP Endpoint
  if [ "$IIOP_ENDPOINT" == "true" ]; then
    if [ "$SSL" == "true" ] || [ "$TLS" == "true" ]; then
      cp $SNIPPETS_SOURCE/iiop-ssl-endpoint.xml $SNIPPETS_TARGET/iiop-ssl-endpoint.xml
    else
      cp $SNIPPETS_SOURCE/iiop-endpoint.xml $SNIPPETS_TARGET/iiop-endpoint.xml
    fi
  fi

  # JMS Endpoint
  if [ "$JMS_ENDPOINT" == "true" ]; then
    if [ "$SSL" == "true" ] || [ "$TLS" == "true" ]; then
      cp $SNIPPETS_SOURCE/jms-ssl-endpoint.xml $SNIPPETS_TARGET/jms-ssl-endpoint.xml
    else
      cp $SNIPPETS_SOURCE/jms-endpoint.xml $SNIPPETS_TARGET/jms-endpoint.xml
    fi
  fi

  # Key Store
  keystorePath="$SNIPPETS_TARGET_DEFAULTS/keystore.xml"
  if [ "$SSL" == "true" ] || [ "$TLS" == "true" ]
  then
    cp $SNIPPETS_SOURCE/tls.xml $SNIPPETS_TARGET/tls.xml
  fi
  
  if [ "$SSL" != "false" ] && [ "$TLS" != "false" ]
  then
    if [ ! -e $keystorePath ]
    then
      # Generate the keystore.xml
      export KEYSTOREPWD=$(openssl rand -base64 32)
      sed "s|REPLACE|$KEYSTOREPWD|g" $SNIPPETS_SOURCE/keystore.xml > $SNIPPETS_TARGET_DEFAULTS/keystore.xml
      chmod g+w $SNIPPETS_TARGET_DEFAULTS/keystore.xml
    fi
  fi

  # SSO Support
  if [[ -n "$SEC_SSO_PROVIDERS" ]]; then
    cp $SNIPPETS_SOURCE/sso-features.xml $SNIPPETS_TARGET_DEFAULTS
    parseProviders $SEC_SSO_PROVIDERS
  fi

  if [ "$SKIP_FEATURE_INSTALL" != "true" ]; then
    # Install needed features
    if [ "$FEATURE_REPO_URL" ]; then
      curl -k --fail $FEATURE_REPO_URL > /tmp/repo.zip
      installUtility install --acceptLicense defaultServer --from=/tmp/repo.zip || rc=$?; if [ $rc -ne 22 ]; then exit $rc; fi
      rm -rf /tmp/repo.zip
    # Otherwise, if features.sh did not run, install server features.
    elif [ "$FEATURES_INSTALLED" == "false" ]; then
      installUtility install --acceptLicense defaultServer || rc=$?; if [ $rc -ne 22 ]; then exit $rc; fi
    fi
  fi

  # Apply interim fixes found in /opt/ibm/fixes
  # Fixes recommended by IBM, such as to resolve security vulnerabilities, are also included in /opt/ibm/fixes
  # Note: This step should be done once needed features are enabled and installed using installUtility.

  # Do not create a SCC
  if [ -n "${IBM_JAVA_OPTIONS}" ]; then
    IBM_JAVA_OPTIONS="${IBM_JAVA_OPTIONS} -Xshareclasses:none"
  fi

  if [ -n "${OPENJ9_JAVA_OPTIONS}" ]; then
    OPENJ9_JAVA_OPTIONS="${OPENJ9_JAVA_OPTIONS} -Xshareclasses:none"
  fi

  find /opt/ibm/fixes -type f -name "*.jar"  -print0 | sort -z | xargs -0 -n 1 -r -I {} java -jar {} --installLocation $WLP_INSTALL_DIR
  #Make sure that group write permissions are set correctly after installing new features
  find /opt/ibm/wlp ! -perm -g=rw -print0 | xargs -r -0 chmod g+rw

  # Create a new SCC layer
  if [ "$OPENJ9_SCC" == "true" ]; then
    cmd="populate_scc.sh -i 1"
    if [ "$TRIM_SCC" == "false" ]; then
      cmd+=" -d"
    fi
    if [ ! "$SCC_SIZE" = "" ]; then
      cmd+=" -s $SCC_SIZE"
    fi
    eval $cmd
  fi
}

## parse provider list to generate files into configDropins
function parseProviders() {
  while [ $# -gt 0 ]; do
    case "$1" in
    oidc:*)
      parseCommaList oidc "${1#*:}"
      ;;
    oauth2:*)
      parseCommaList oauth2 "${1#*:}"
      ;;
    *)
      if [[ $(ls $SNIPPETS_SOURCE | grep "$1") ]]; then
        cp $SNIPPETS_SOURCE/sso-${1}.xml $SNIPPETS_TARGET_DEFAULTS
      fi
      ;;
    esac
    shift
  done
}

## process the comma delimitted oauth2/oidc source lists
function parseCommaList() {
  local type="$1"
  local list=$(echo "$2" | tr , " ")

  for current in ${list}; do
    if [[ "${type}" = "oidc" ]]; then
      # replace oidc identifiers with custom name
      sed -e 's/=\"oidc/=\"'${current}'/g' -e 's/_OIDC_/_'${current^^}'_/g' $SNIPPETS_SOURCE/sso-oidc.xml > $SNIPPETS_TARGET_DEFAULTS/sso-${current}.xml
    else
      # replace oauth2 identifiers with custom name
      sed -e 's/=\"oauth2/=\"'${current}'/g' -e 's/_OAUTH2_/_'${current^^}'_/g' $SNIPPETS_SOURCE/sso-oauth2.xml > $SNIPPETS_TARGET_DEFAULTS/sso-${current}.xml
    fi
  done
}

main "$@"
