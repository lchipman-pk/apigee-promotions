#!/bin/bash
# Set the following parameters below to configure this script for a specific deployment. Positional parameters override these settings.
oauth_ep="https://login.apigee.com/oauth/token"
username="USERNAME"
password="PASSWORD"
default_api="APINAME"
default_source_organization="SOURCEORG"
default_target_organization="TARGETORG"
management_ep_base="https://api.enterprise.apigee.com/v1/"
default_source_env="test"
default_target_env="prod"
delay="10"

help ()
{
    cat <<!!!!!
    This utility will deploy a proxy from one Apigee environment and optionally organization to another. It only promotes the most recent revision of the proxy.

    Syntax:
        proxy-promotion.sh [--help|api] [source_env] [target_env] [source_org] [target_org]
    
    Parameters:
        --help - Returns this help message.
        api - The name of the proxy to promote.
        source_env - The source environment in which the proxy exists.
        target_env - The target environment into which the proxy should be deployed.
        source_org - The source organization in which the proxy exists.
        target_org - The target organization into which the proxy should be deployed.

    Instead of providing the parameters on the command line, they can be provided in this script itself. Partial parameters can be provided, but as all parameters
    are positional, you can only leave out the right-most parameters.
!!!!!

    exit 1
}

# Parameter setup
if [ -n "${1}" -a "${1}" == "--help" ]
then
    help
fi

echo "Apigee Proxy Promotion Script v1.0.0"

api=${1:-$default_api}
source_env=${2:-$default_source_env}
target_env=${3:-$default_target_env}
source_organization=${4:-$default_source_organization}
target_organization=${5:-$default_target_organization}

echo "Promoting '${api}' from environment '${source_env}' in org '${source_organization}' to env '${target_env}' in org '${target_organization}'."

echo "Authenticating user..."
#1.	Call Apigee OAuth server
token_response=$(curl -s -f -H "Content-Type:application/x-www-form-urlencoded;charset=utf-8" -H "Accept: application/json;charset=utf-8" -H "Authorization: Basic ZWRnZWNsaTplZGdlY2xpc2VjcmV0" -X POST -d "username=${username}&password=${password}&grant_type=password" https://login.apigee.com/oauth/token)
if [ -z "${token_response}" -o "$?" -gt 0 ]
then
    echo "No token response received (incorrect username or password?)"
    exit 1
fi

#2. Extract token
access_token=$(echo "${token_response}" | jq -r ".access_token")
if [ -z "${access_token}" ]
then
    echo "Couldn't parse the response from Apigee's token service."
    exit 1
fi

echo "Getting the latest revision of the proxy from the source..."
#3. Get latest revision in source environment/org
current_revision=$(curl -f -s -H "Authorization: Bearer ${access_token}" ${management_ep_base}organizations/${source_organization}/apis/${api}/revisions | jq ". | map(tonumber) | max")
if [ -z "${current_revision}" -o "$?" -gt 0 ]
then
    echo "Couldn't determine the current revision of the proxy (incorrect organization or API name?)."
    exit 1
fi

echo "Revision '${current_revision}' found."
#3b. Export latest revision from source environment/org
# We don't need to do the export/import if the source and target organizations are the same. In that case, we just deploy the current revision to the new environment.
if [ "${source_organization}" != "${target_organization}" ]
then
    echo "Source and target organizations differ, exporting and importing proxy."
    echo "Exporting proxy from ${source_organization}..."
    export_filename="${api}-rev_${current_revision}.zip"
    curl -f -s -H "Authorization: Bearer ${access_token}" "${management_ep_base}organizations/${source_organization}/apis/${api}/revisions/${current_revision}?format=bundle" -o "${export_filename}"
    if [ -e ${export_filename} -o "$?" -eq 0 ]
    then
        echo "Proxy exported. You can find a copy at '${export_filename}'."
    else
        echo "Couldn't export the current version of the proxy (insufficient permissions or out of disk space?)."
        exit 1
    fi

    echo "Importing proxy to ${target_organization}..."
    #3c. Import revision in target environment/org and get revision ID
    targetorg_import_output=$(curl -f -s -H "Authorization: Bearer ${access_token}" -X POST "${management_ep_base}organizations/${target_organization}/apis?action=import&name=${api}&validate=true" -F "file=@${export_filename}")
    if [ -z "${targetorg_import_output}" -o "$?" -gt 0 ]
    then
        echo "Couldn't import the new revision of the proxy (insufficient permissions?)."
        exit 1
    else
        targetorg_revision=$(echo "${targetorg_import_output}" | jq -r ".revision")
        if [ -z "${targetorg_revision}" ]
        then
            echo "Couldn't determine the imported revision of the proxy."
            exit 1
        fi
    fi
else
    echo "Source and target organizations are the same, skipping export and just deploying the latest revision to the new environment."
    targetorg_revision="${current_revision}"
fi

echo "Deploying proxy to ${target_env}..."
#4. Deploy latest revision to target environment using seamless
deploy_output=$(curl -f -s -H "Authorization: Bearer ${access_token}" -X POST "${management_ep_base}organizations/${target_organization}/environments/${target_env}/apis/${api}/revisions/${targetorg_revision}/deployments?delay=${delay}&override=true")
if [ "$?" -gt 0 ]
then
    if [ "${source_organization}" != "${target_organization}" ]
    then
        echo "Deployment failed in seamless mode. The proxy was imported to \"${target_organization}\" at revision ${targetorg_revision}, but it couldn't deploy to \"${target_env}\" (is the revision already deployed?)."
        exit 1
    else
        echo "Deployment failed in seamless mode. The proxy couldn't deploy to \"${target_env}\" (is the revision already deployed?)."
        exit 1
    fi
else
    deploy_state=$(echo "${deploy_output}" | jq -r ".state")
    echo "Deployment to \"${target_organization}\" environment \"${target_env}\" at revision ${targetorg_revision}: ${deploy_state}"
    exit 0
fi

