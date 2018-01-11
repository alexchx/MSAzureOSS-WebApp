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
  --storage_account_name|-sn       [Required]: Azure storage account name
  --storage_account_key|-sk        [Required]: Azure storage account key
  --resourcegroup|-rg              [Required]: Azure resource group for the components
  --webapp|-w                      [Required]: Azure web app name
  --repository|-rr                 [Required]: Repository targeted by the build
  --agent_port|-p                            : Jenkins agent port
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
job_short_name="BuildWebApp"
credential_sp_id='mySP'
credential_sp_description='Azure Service Principal'
credential_storage_id='myStorage'
credential_storage_description='Microsoft Azure Storage	'
aci_container_name='ACI-container'
aci_container_image='cloudbees/jnlp-slave-with-java-build-tools'
artifacts_location="https://raw.githubusercontent.com/Azure/azure-devops-utils/master/"
agent_port=5378

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
    --storage_account_name|-sn)
      storage_account_name="$1"
      shift
      ;;
    --storage_account_key|-sk)
      storage_account_key="$1"
      shift
      ;;
    --resourcegroup|-rg)
      resourcegroup="$1"
      shift
      ;;
    --webapp|-w)
      webapp="$1"
      shift
      ;;
    --repository|-rr)
      repository="$1"
      shift
      ;;
    --agent_port|-p)
      agent_port="$1"
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
throw_if_empty --storage_account_name $storage_account_name
throw_if_empty --storage_account_key $storage_account_key
throw_if_empty --resourcegroup $resourcegroup
throw_if_empty --webapp $webapp
throw_if_empty --repository $repository
throw_if_empty --custom_artifacts_location $custom_artifacts_location

# install the required plugins
plugins=(credentials envinject)
for plugin in "${plugins[@]}"; do
  run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "install-plugin $plugin -deploy"
done

# open a fixed port for JNLP
inter_jenkins_config=$(sed -zr -e"s|<slaveAgentPort.*</slaveAgentPort>|<slaveAgentPort>{slave-agent-port}</slaveAgentPort>|" /var/lib/jenkins/config.xml)
final_jenkins_config=${inter_jenkins_config//'{slave-agent-port}'/${jenkins_agent_port}}
echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null

# restart jenkins
sudo service jenkins restart

# wait for instance to be back online
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "version"

# configure Azure Container Instance
aci_agent_conf=$(cat <<EOF
<clouds>
    <com.microsoft.jenkins.containeragents.aci.AciCloud plugin="azure-container-agents@0.4.1">
      <name>Aci</name>
      <credentialsId>${credential_sp_id}</credentialsId>
      <resourceGroup>${resourcegroup}</resourceGroup>
      <templates>
        <com.microsoft.jenkins.containeragents.aci.AciContainerTemplate>
          <name>${aci_container_name}</name>
          <label>${aci_container_name}</label>
          <image>${aci_container_image}</image>
          <osType>Linux</osType>
          <command>jenkins-slave -url ${rootUrl} ${secret} ${nodeName}</command>
          <rootFs>/home/jenkins</rootFs>
          <timeout>10</timeout>
          <ports/>
          <cpu>1</cpu>
          <memory>1.5</memory>
          <retentionStrategy class="com.microsoft.jenkins.containeragents.strategy.ContainerIdleRetentionStrategy">
            <idleMinutes>10</idleMinutes>
            <idleMinutes defined-in="com.microsoft.jenkins.containeragents.strategy.ContainerIdleRetentionStrategy">10</idleMinutes>
          </retentionStrategy>
          <envVars/>
          <privateRegistryCredentials/>
          <volumes/>
          <launchMethodType>jnlp</launchMethodType>
          <isAvailable>true</isAvailable>
        </com.microsoft.jenkins.containeragents.aci.AciContainerTemplate>
      </templates>
    </com.microsoft.jenkins.containeragents.aci.AciCloud>
  </clouds>
EOF
)

inter_jenkins_config=$(sed -zr -e"s|<clouds/>|{clouds}|" /var/lib/jenkins/config.xml)
final_jenkins_config=${inter_jenkins_config//'{clouds}'/${aci_agent_conf}}
echo "${final_jenkins_config}" | sudo tee /var/lib/jenkins/config.xml > /dev/null

# reload configuration
run_util_script "jenkins/run-cli-command.sh" -c "reload-configuration"

# download dependencies
job_xml=$(curl -s ${custom_artifacts_location}/jenkins/jobs-build-webapp.xml${custom_artifacts_location_sas_token})
credentials_sp_xml=$(curl -s ${custom_artifacts_location}/jenkins/credentials-sp.xml${custom_artifacts_location_sas_token})
credentials_storage_xml=$(curl -s ${custom_artifacts_location}/jenkins/credentials-storage.xml${custom_artifacts_location_sas_token})

# prepare job.xml
job_xml=${job_xml//'{insert-repository-url}'/${repository}}
job_xml=${job_xml//'{insert-aci-container}'/${aci_container_name}}
job_xml=${job_xml//'{insert-credentials-storage-id}'/${credential_storage_id}}
job_xml=${job_xml//'{insert-credentials-sp-id}'/${credential_sp_id}}
job_xml=${job_xml//'{insert-resourcegroup-name}'/${resourcegroup}}
job_xml=${job_xml//'{insert-webapp-name}'/${webapp}}

# prepare credentials_sp.xml (service principal)
credentials_sp_xml=${credentials_sp_xml//'{insert-credentials-id}'/${credential_sp_id}}
credentials_sp_xml=${credentials_sp_xml//'{insert-credentials-description}'/${credential_sp_description}}
credentials_sp_xml=${credentials_sp_xml//'{insert-subscription-id}'/${subscription}}
credentials_sp_xml=${credentials_sp_xml//'{insert-client-id}'/${clientid}}
credentials_sp_xml=${credentials_sp_xml//'{insert-client-secret}'/${clientsecret}}
credentials_sp_xml=${credentials_sp_xml//'{insert-tenant-id}'/${tenant}}

# prepare credentials_storage.xml (storage account)
credentials_storage_xml=${credentials_storage_xml//'{insert-credentials-id}'/${credential_storage_id}}
credentials_storage_xml=${credentials_storage_xml//'{insert-credentials-description}'/${credential_storage_description}}
credentials_storage_xml=${credentials_storage_xml//'{insert-credentials-account-name}'/${storage_account_name}}
credentials_storage_xml=${credentials_storage_xml//'{insert-credentials-account-key}'/${storage_account_key}}

# add job
echo "${job_xml}" > job.xml
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-job ${job_short_name}" -cif "job.xml"

# add credentials
echo "${credentials_sp_xml}" > credentials_sp.xml
echo "${credentials_storage_xml}" > credentials_storage.xml
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-credentials-by-xml system::system::jenkins _" -cif "credentials_sp.xml"
run_util_script "jenkins/run-cli-command.sh" -j "$jenkins_url" -ju "$jenkins_username" -jp "$jenkins_password" -c "create-credentials-by-xml system::system::jenkins _" -cif "credentials_storage.xml"

# cleanup
rm job.xml
rm credentials_sp.xml
rm credentials_storage.xml
rm jenkins-cli.jar
