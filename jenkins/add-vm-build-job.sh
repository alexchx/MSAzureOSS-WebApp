#!/bin/bash

function print_usage() {
  cat <<EOF
Command
  $0
Arguments
  --subscription|-su               [Required]: Azure subscription id
  --tenant|-t                      [Required]: Azure tenant id
  --clientid|-i                    [Required]: Azure service principal client id
  --clientsecret|-s                [Required]: Azure service principal client secret
  --resourcegroup|-rg              [Required]: Azure resource group for the components
  --location|-l                    [Required]: Azure resource group location for the components
  --image_resourcegroup|-irg       [Required]: Azure resource group for the VM image
  --image|-im                                : VM image name
  --username|-u                    [Required]: Username for the Virtual Machine
  --password|-p                    [Required]: Password for the Virtual Machine
  --repository|-rr                 [Required]: Repository targeted by the build
  --artifacts_location|-al                   : Url used to reference other scripts/artifacts.
  --sas_token|-st                            : A sas token needed if the artifacts location is private.
  --custom_artifacts_location|-cal [Required]: Url used to reference custom scripts/artifacts.
  --custom_sas_token|-cst                    : A sas token needed if the custom artifacts location is private.
EOF
}

function throw_if_empty() {
  local name="$1"
  local value="$2"
  if [ -z "$value" ]; then
    >&2 echo "Parameter '$name' cannot be empty."
    print_usage
    exit -1
  fi
}

function run_util_script() {
  local script_path="$1"
  shift
  curl --silent "${artifacts_location}${script_path}${artifacts_location_sas_token}" | sudo bash -s -- "$@"
  local return_value=$?
  if [ $return_value -ne 0 ]; then
    >&2 echo "Failed while executing script '$script_path'."
    exit $return_value
  fi
}

# set defaults
jenkins_url="http://localhost:8080/"
jenkins_username="admin"
jenkins_password=""
image="myPackerLinuxImage"
job_short_name="BuildVM"
scm_poll_schedule='* * * * *' # every 1 min
scm_poll_ignore_commit_hooks_bool='false'
credential_id='2e2dbb59-60e1-453a-8943-fef38e76ebc6'
credential_description='VM credential'
artifacts_location="https://raw.githubusercontent.com/Azure/azure-devops-utils/master/"

while [[ $# > 0 ]]
do
  key="$1"
  shift
  case $key in
    --subscription|-su)
      subscription="$1"
      shift
      ;;
    --tenant|-t)
      tenant="$1"
      shift
      ;;
    --clientid|-i)
      clientid="$1"
      shift
      ;;
    --clientsecret|-s)
      clientsecret="$1"
      shift
      ;;
    --resourcegroup|-rg)
      resourcegroup="$1"
      shift
      ;;
    --location|-l)
      location="$1"
      shift
      ;;
    --image_resourcegroup|-irg)
      image_resourcegroup="$1"
      shift
      ;;
    --image|-im)
      image="$1"
      shift
      ;;
    --username|-u)
      username="$1"
      shift
      ;;
    --password|-p)
      password="$1"
      shift
      ;;
    --repository|-rr)
      repository="$1"
      shift
      ;;
    --artifacts_location|-al)
      artifacts_location="$1"
      shift
      ;;
    --sas_token|-st)
      artifacts_location_sas_token="$1"
      shift
      ;;
    --custom_artifacts_location|-cal)
      custom_artifacts_location="$1"
      shift
      ;;
    --custom_sas_token|-cst)
      custom_artifacts_location_sas_token="$1"
      shift
      ;;
    --help|-help|-h)
      print_usage
      exit 13
      ;;
    *)
      >&2 echo "ERROR: Unknown argument '$key' to script '$0'"
      exit -1
  esac
done

throw_if_empty jenkins_username $jenkins_username
if [ "$jenkins_username" != "admin" ]; then
  throw_if_empty jenkins_password $jenkins_password
fi
throw_if_empty --subscription $subscription
throw_if_empty --tenant $tenant
throw_if_empty --clientid $clientid
throw_if_empty --clientsecret $clientsecret
throw_if_empty --resourcegroup $resourcegroup
throw_if_empty --location $location
throw_if_empty --image_resourcegroup $image_resourcegroup
throw_if_empty --repository $repository

# install the required plugins
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "install-plugin credentials -deploy"
plugins=(envinject)
for plugin in "${plugins[@]}"; do
  run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "install-plugin $plugin -restart"
done

# wait for instance to be back online
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "version"

# download dependencies
job_xml=$(curl -s ${custom_artifacts_location}/jenkins/vm-build-job.xml${custom_artifacts_location_sas_token})
credentials_xml=$(curl -s ${custom_artifacts_location}/jenkins/vm-credential.xml${custom_artifacts_location_sas_token})

# prepare job.xml
job_xml=${job_xml//'{insert-repository-url}'/${repository}}
job_xml=${job_xml//'{insert-subscription-id}'/${subscription}}
job_xml=${job_xml//'{insert-tenant-id}'/${tenant}}
job_xml=${job_xml//'{insert-client-id}'/${clientid}}
job_xml=${job_xml//'{insert-client-secret}'/${clientsecret}}
job_xml=${job_xml//'{insert-resource-group}'/${resourcegroup}}
job_xml=${job_xml//'{insert-location}'/${location}}
job_xml=${job_xml//'{insert-image-resource-group}'/${image_resourcegroup}}
job_xml=${job_xml//'{insert-image-name}'/${image}}
job_xml=${job_xml//'{insert-credentials-id}'/${credential_id}}

# set SCM poll schedule
triggers_xml_node=$(cat <<EOF
<triggers>
  <hudson.triggers.SCMTrigger>
    <spec>${scm_poll_schedule}</spec>
    <ignorePostCommitHooks>${scm_poll_ignore_commit_hooks_bool}</ignorePostCommitHooks>
  </hudson.triggers.SCMTrigger>
</triggers>
EOF
)
job_xml=${job_xml//'<triggers/>'/${triggers_xml_node}}

# prepare credentials.xml
credentials_xml=${credentials_xml//'{insert-credentials-id}'/${credential_id}}
credentials_xml=${credentials_xml//'{insert-credentials-description}'/${credential_description}}
credentials_xml=${credentials_xml//'{insert-user-name}'/${username}}
credentials_xml=${credentials_xml//'{insert-user-password}'/${password}}

# add job
echo "${job_xml}" > job.xml
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-job ${job_short_name}" -cif "job.xml"

# add credential
echo "${credentials_xml}" > credentials.xml
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-credentials-by-xml system::system::jenkins _" -cif "credentials.xml"

# install tools
sudo apt-get install unzip --yes

wget https://releases.hashicorp.com/packer/1.1.3/packer_1.1.3_linux_amd64.zip
unzip packer_1.1.3_linux_amd64.zip -d /usr/bin

wget https://releases.hashicorp.com/terraform/0.11.1/terraform_0.11.1_linux_amd64.zip
unzip terraform_0.11.1_linux_amd64.zip -d /usr/bin

# cleanup
rm job.xml
rm credentials.xml
rm jenkins-cli.jar
rm packer_1.1.3_linux_amd64.zip
rm terraform_0.11.1_linux_amd64.zip
