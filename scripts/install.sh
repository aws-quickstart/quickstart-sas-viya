#!/bin/bash -e
set -x

# this script is expected to be run by a user with sudo privileges (typically ec2-user)

trap cleanup EXIT

set -o pipefail
set -o errexit
set -o nounset

# This is a mustache template.
# Make sure all the input parms are set
test -n {{LogGroup}}
test -n {{AWSRegion}}
test -n {{KeyPairName}}
test -n {{AnsibleControllerIP}}
test -n {{CloudFormationStack}}
test -n {{CloudWatchLogs}}
test -n {{S3FileRoot}}
test -n {{DeploymentSize}}


VisualServicesIP=
ProgrammingServicesIP=
StatefulServicesIP=
ViyaServicesIP=
CASControllerIP=
DomainName=
FAILMSG=
ControllerNodeSize={{ControllerNodeSize}}

# use triple mustache to avoid url encoding
USERPASS=$(echo -n '{{{SASUserPass}}}' | base64)
ADMINPASS=$(echo -n '{{{SASAdminPass}}}' | base64)

# prepare directories for logs and messages
export LOGDIR=$HOME/deployment-logs
mkdir -p "$LOGDIR"
export MSGDIR=$HOME/deployment-messages
mkdir -p "$MSGDIR"

#
# Create the message file containing the "Starting SAS Viya Deployment" message
#
create_start_message () {
  OUTFILE="$MSGDIR/sns_start_message.txt"

  cat <<EOF > "$OUTFILE"

  Starting SAS Viya Deployment for Stack "{{CloudFormationStack}}".

  Follow the deployment logs at {{CloudWatchLogs}}

  Log into the Ansible Controller VM with the private key for KeyPair "{{KeyPairName}}":

       ssh -i /path/to/private/key.pem ec2-user@{{AnsibleControllerIP}}

  From the ansible controller, you can ssh into these VMs:

EOF

if [ {{DeploymentSize}} = medium ]
then cat <<EOF >> "$OUTFILE"
       Visual Services:
         visual.viya.sas (visual)
       Programming Services:
         prog.viya.sas (prog)
       Stateful Services:
         stateful.viya.sas (stateful)
EOF
  elif [ {{DeploymentSize}} == small ]
  then cat <<EOF >> "$OUTFILE"
       Viya Services:
         services.viya.sas (services)
EOF
  fi

cat <<EOF >> "$OUTFILE"
       CAS Controller:
         controller.viya.sas (controller)
EOF

}

#
# Create the message file containing the "completed successfully" message
#
create_success_message () {
  OUTFILE="$MSGDIR/sns_success_message.txt"

  cat <<EOF > "$OUTFILE"

   SAS Viya Deployment for Stack "{{CloudFormationStack}}" completed successfully.

   Log into SAS Viya at $SASDrive

   Log into SAS Studio at $SASStudio

   For administrative tasks:

     See the deployment and application logs at {{CloudWatchLogs}}

     Log into the Ansible Controller VM with the private key for KeyPair "{{KeyPairName}}":

       ssh -i /path/to/private/key.pem ec2-user@{{AnsibleControllerIP}}

     From the ansible controller, you can ssh into these VMs:
EOF
  if [ {{DeploymentSize}} = medium ]
  then cat <<EOF >> "$OUTFILE"
       Visual Services:
         visual.viya.sas (visual)
       Programming Services:
         prog.viya.sas (prog)
       Stateful Services:
         stateful.viya.sas (stateful)
EOF
  elif [ {{DeploymentSize}} == small ]
  then cat <<EOF >> "$OUTFILE"
       Viya Services:
         services.viya.sas (services)
EOF
  fi

cat <<EOF >> "$OUTFILE"
       CAS Controller:
         controller.viya.sas (controller)
EOF

}

#
# Create the message file containing the "failed" message
#
create_failure_message () {
  STACKID=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stacks --stack-name "{{CloudFormationStack}}" --query Stacks[*].StackId --output text)

  cat <<EOF > "$MSGDIR/sns_failure_message.txt"

   SAS Viya Deployment for Stack "{{CloudFormationStack}}" failed with RC=$1.

   ${FAILMSG}

   Check the Stack Events at https://console.aws.amazon.com/cloudformation/home?region={{AWSRegion}}#/stacks?filter=active&tab=events&stackId=${STACKID}
   and the deployment logs at {{CloudWatchLogs}}.

EOF

  if [ -n "$FAILMSG" ]; then
    echo "$FAILMSG" >> $CMDLOG
  fi
}

#
# make sure the sns message subject does not exceed the maximum 100 chars
#
check_subject_length () {
  if [[ ${#SUBJECT} -gt 100 ]]; then
     SUBJECT=$(printf "%s..." "$(echo -n "$SUBJECT" | cut -c1-97 )" );
  fi
}

#
# Send an email notification re: success or sns_failure_message
#
cleanup () {
  RC=$?

  if [ -n "{{SNSTopic}}" ]; then

    if [[ $RC == 0 ]]; then
      # create and send success email

      create_success_message

      SUBJECT="SAS Viya Deployment completed for Stack {{CloudFormationStack}}"
      check_subject_length

      aws --region "{{AWSRegion}}" sns publish --topic-arn "{{SNSTopic}}" --subject "$SUBJECT" \
          --message "file://$MSGDIR/sns_success_message.txt"
    else
      # create and send failure email

      create_failure_message $RC

      SUBJECT="SAS Viya Deployment failed for Stack {{CloudFormationStack}}"
      check_subject_length

      aws --region "{{AWSRegion}}" sns publish --topic-arn "{{SNSTopic}}" --subject "$SUBJECT" \
          --message "file://$MSGDIR/sns_failure_message.txt"
    fi
  fi
}

#
# seed .ssh/known_hosts file
#
seed_known_hosts_file () {

  # log into each VM once with each ip or hostname.
  # That seeds that hosts ~/.ssh/known_hosts file.
  # All subsequent ssh attempts will then not get the "unkown host" interactive message
  # That is primarily as a convenience for admin tasks later on

  hosts=($(cat /etc/hosts | grep -v localhost ))
  for host in "${hosts[@]}"
  do
    ssh -o StrictHostKeyChecking=no $host exit
  done

}

#
# reconfigure ELB to use self-signed cert
#
configure_self_signed_cert () {
  if ! [ -n "{{SSLCertificateARN}}" ]; then

    echo "$(date) Set self-signed SSL certificate on ELB" >> "$CMDLOG"

    # get ELB name
    ELBNAME=""
    while [[ "$ELBNAME"  == "" ]]; do
      ELBNAME=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ElasticLoadBalancer --query StackResources[*].PhysicalResourceId --output text)
      sleep 3
    done
    ELBDNS=$(aws --no-paginate --region "{{AWSRegion}}" elb describe-load-balancers --load-balancer-name "$ELBNAME" --query LoadBalancerDescriptions[*].DNSName --output text)

    # delete existing http listener
    aws --region "{{AWSRegion}}" elb delete-load-balancer-listeners --load-balancer-name "$ELBNAME" --load-balancer-ports 443

    # create self-signed certificate
cat <<EOF > "ssl.conf"
    [ req ]
    distinguished_name = dn
    x509_extensions = san
    [ dn ]
    [ san ]
    subjectAltName          = DNS:$ELBDNS
EOF
    openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 396 -nodes -config ssl.conf -subj '/CN=*.elb.amazonaws.com'

    # import cert into IAM (this creates an AWS resource that we later need to remove)
    CERTNAME="{{CloudFormationStack}}-selfsigned-cert"
    CERTARN=$(aws --region "{{AWSRegion}}" iam upload-server-certificate --server-certificate-name "$CERTNAME" --certificate-body file://cert.pem --private-key file://key.pem --query ServerCertificateMetadata.Arn --output text)

    #  until [ -n "$(aws --no-paginate --region "{{AWSRegion}}" iam list-server-certificates --query "ServerCertificateMetadataList[?Arn=='$CERTARN'].ServerCertificateId" --output text)" ]; do
    #    sleep 1
    #  done
    #  sleep 5

    # create https listener
    until aws --region "{{AWSRegion}}" elb create-load-balancer-listeners --load-balancer-name "$ELBNAME" --listeners Protocol=HTTPS,LoadBalancerPort=443,InstanceProtocol=HTTPS,InstancePort=443,SSLCertificateId=$CERTARN 2>/dev/null
    do
      sleep 1
    done
    aws --region "{{AWSRegion}}" elb set-load-balancer-policies-of-listener --load-balancer-name "$ELBNAME" --load-balancer-port 443 --policy-names AppCookieStickinessPolicy

    #  aws --region "{{AWSRegion}}" iam delete-server-certificate --server-certificate-name "$CERTNAME"
  fi
}

install_openldap () {

  # list of files created with:
  # find openldap -type f | tail -n+1 | grep -v files.txt > openldap/files.txt

  # pull down openLDAP files
  pushd ~
    while read file; do
      aws s3 cp s3://{{S3FileRoot}}$file $file
    done </tmp/openldapfiles.txt
  popd

  # set up OpenLDAP
  pushd ~/openldap

    # set log file
    export ANSIBLE_LOG_PATH=$LOGDIR/deployment-openldap.log

    # add hosts
    ansible-playbook update.inventory.yml -i /tmp/inventory.head

    # openldap and sssd setup
    ansible-playbook openldapsetup.yml -e "OLCROOTPW='$ADMINPASS' OLCUSERPW='$USERPASS'"
  popd
}

# sometimes there are ssh connection errors (53) during the install
# this function allows to retry N times
function try () {
  # allow up to N attempts of a command
  # syntax: try N [command]
  RC=1; count=1; max_count=$1; shift
  until  [ $count -gt "$max_count" ]
  do
    "$@" && RC=0 && break || let count=count+1
  done
  return $RC
}

#
# before we start make sure the stack is still good. It could have failed in resources that are created post-VM (especially the ELB)
#
check_stack_status () {
  STACK_STATUS=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stacks --stack-name "{{CloudFormationStack}}"  --query Stacks[*].StackStatus --output text)
  # fail script if stack creation failed
  if [ "$(echo "$STACK_STATUS" | grep "CREATE_FAILED")" ]; then exit 1; fi
}

#
# set log file for deployment steps
#
export CMDLOG="$LOGDIR/deployment-commands.log"
touch "$CMDLOG"
echo "SNSTopic: {{SNSTopic}}" >> "$CMDLOG"

if [ -n "{{SNSTopic}}" ]; then

  # create and send start email

  create_start_message
  SUBJECT="Starting SAS Viya Deployment {{CloudFormationStack}}"
  check_subject_length

  aws --region "{{AWSRegion}}" sns publish --topic-arn "{{SNSTopic}}" --subject "$SUBJECT" \
      --message "file://$MSGDIR/sns_start_message.txt"

fi

#
# verify SSL certificate is valid, if specified
#
echo "Verifying SSL Certificate ARN" >> "$CMDLOG"
if [ -n "{{SSLCertificateARN}}" ]; then
  echo " " >> "$CMDLOG"
  echo "$(date) Certificate ARN: {{SSLCertificateARN}}" >> "$CMDLOG"

  # this fails the script if the SSLCertificateARN is invalid
  FAILMSG="ERROR: SSL Certificate {{SSLCertificateARN}} does not exist in the current AWS account."
  # Check the ARN to determine if this is an iam or acm certificate
  CERT_ARN="{{SSLCertificateARN}}"
  if [[ $CERT_ARN = *":iam:"* ]]; then
      # iam certificate uses get-server-certificate
      CERT_NAME=${CERT_ARN##*/}
      aws --no-paginate --region "{{AWSRegion}}" iam get-server-certificate --server-certificate-name "$CERT_NAME"
      FAILMSG=
  else
      # acm certificate uses describe-certificate
      aws --no-paginate --region "{{AWSRegion}}" acm describe-certificate --certificate "$CERT_ARN"
      FAILMSG=
  fi
fi

#
# make sure the Hosted Zone is good
#
echo "Verifying Hosted Zone Id" >> "$CMDLOG"
if [ -n "{{HostedZoneID}}" ]; then
 # this fails the script if the HostedZoneID is invalid
 FAILMSG="ERROR: Hosted Zone {{HostedZoneID}} does not exist in the current AWS account."
 aws --no-paginate --region "{{AWSRegion}}" route53 get-hosted-zone --id {{HostedZoneID}}
 FAILMSG=

 # compare DNS entry used in the hosted zone with the given DNSName
 HZDNS=$(aws --no-paginate --region "{{AWSRegion}}" route53 list-resource-record-sets --hosted-zone-id {{HostedZoneID}} --query 'ResourceRecordSets[?Type==`NS`].Name' --output text)
 # fail the script if the specified DomainName does not match the hosted zone
 FAILMSG="ERROR: Value for DomainName=\"{{DomainName}}\" does not match domain \"${HZDNS:0:-1}\" in Hosted Zone {{HostedZoneID}}"
 [[ "$HZDNS" == "{{DomainName}}." ]]
 FAILMSG=
fi


#
# verify mirror is valid
#

# For s3:// : lowercase initial s, remove trailing slash if it exists
DM=$(echo -n {{DeploymentMirror}} | sed "s/^S/s/" | sed "s+/$++"   )
if [[ $(echo -n "{{DeploymentMirror}}" | cut -c1-2 | tr [:lower:] [:upper:]) == S3 ]]; then
  FAILMSG="ERROR: DeploymentMirror location {{DeploymentMirror}} not valid or not accessible."
  aws s3 ls ${DM}/entitlements.json
  FAILMSG=
elif [[ $(echo -n "{{DeploymentMirror}}" | cut -c1-4 | tr [:lower:] [:upper:]) == HTTP ]]; then
  FAILMSG="ERROR: DeploymentMirror location {{DeploymentMirror}} not valid or not accessible."
  curl -L ${DM}/entitlements.json
  FAILMSG=
fi

#
# pre-deployment steps
#

# create a key and make available via SSM parameter store
echo "Creating key" >> "$CMDLOG"
echo -e y | ssh-keygen -t rsa -q -f ~/.ssh/id_rsa -N ""

KEY=$(cat ~/.ssh/id_rsa.pub)
aws --region "{{AWSRegion}}" ssm put-parameter --name "viya-ansiblekey-{{CloudFormationStack}}" --type String --value "$KEY" --overwrite

#
# make sure the Viya VMs are all up
#
echo "Checking Viya VMs" >> "$CMDLOG"
STATUS="status"
while ! [ -z "$(echo "$STATUS" | grep -q -v "CREATE_COMPLETE" )" ]; do
  sleep 3
  STATUS=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}"  --query 'StackResources[?ResourceType ==`AWS::EC2::Instance`]|[?LogicalResourceId != `AnsibleController`].ResourceStatus' --output text)
  if [ "$(echo "$STATUS" | grep "CREATE_FAILED")" ]; then exit 1; fi
done

#
# make sure all the volume attachments are complete
#
echo "Checking volume attachments" >> "$CMDLOG"
STATUS="status"
until [ $(echo "$STATUS" | wc -w) = $(echo "$STATUS" | sed 's/CREATE_COMPLETE/CREATE_COMPLETE\n/g' | grep -c "CREATE_COMPLETE") ]; do
  sleep 1
  STATUS=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}"  --query 'StackResources[?ResourceType ==`AWS::EC2::VolumeAttachment`].ResourceStatus' --output text)
  [ "$STATUS" = "" ] && STATUS="status"
  if [ "$(echo "$STATUS" | grep "CREATE_FAILED")" ]; then exit 1; fi
  check_stack_status
done

echo "Getting IP addresses" >> "$CMDLOG"
VisualServicesID=$(aws --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id VisualServices --query StackResources[*].PhysicalResourceId --output text)
[ -n "$VisualServicesID" ] && VisualServicesIP=$(aws ec2 --region "{{AWSRegion}}" describe-instances --instance-id "$VisualServicesID" --query Reservations[*].Instances[*].PrivateIpAddress --output text)

ProgrammingServicesID=$(aws --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ProgrammingServices --query StackResources[*].PhysicalResourceId --output text)
[ -n "$ProgrammingServicesID" ] && ProgrammingServicesIP=$(aws --region "{{AWSRegion}}" ec2 describe-instances --instance-id "$ProgrammingServicesID" --query Reservations[*].Instances[*].PrivateIpAddress --output text)

StatefulServicesID=$(aws --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id StatefulServices --query StackResources[*].PhysicalResourceId --output text)
[ -n "$StatefulServicesID" ] && StatefulServicesIP=$(aws --region "{{AWSRegion}}" ec2 describe-instances --instance-id "$StatefulServicesID" --query Reservations[*].Instances[*].PrivateIpAddress --output text)

ViyaServicesID=$(aws --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ViyaServices --query StackResources[*].PhysicalResourceId --output text)
[ -n "$ViyaServicesID" ] && ViyaServicesIP=$(aws ec2 --no-paginate --region "{{AWSRegion}}" describe-instances --instance-id "$ViyaServicesID" --query Reservations[*].Instances[*].PrivateIpAddress --output text)

CASControllerID=$(aws --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id CASController --query StackResources[*].PhysicalResourceId --output text)
CASControllerIP=$(aws --region "{{AWSRegion}}" ec2 describe-instances --instance-id "$CASControllerID" --query Reservations[*].Instances[*].PrivateIpAddress --output text)


# set instances on load balancer
ELBNAME=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ElasticLoadBalancer --query StackResources[*].PhysicalResourceId --output text)

if [ -n "$ViyaServicesID" ];
then
   # if ViyaServices is set, it must be a small deployment
   aws --region "{{AWSRegion}}" elb register-instances-with-load-balancer \
       --load-balancer-name $ELBNAME \
       --instances $ViyaServicesID
else
   # otherwise it is a medium deployment
   aws --region "{{AWSRegion}}" elb register-instances-with-load-balancer \
       --load-balancer-name $ELBNAME \
       --instances $VisualServicesID $ProgrammingServicesID $StatefulServicesID
fi




echo "Generating inventory.ini" >> "$CMDLOG"
# prepare host list for ansible inventory.ini file
{
    if [ -n "$ViyaServicesIP" ];
    then
      # if ViyaServices is set, it must be a small deployment
      echo services ansible_host="$ViyaServicesIP"
    else
      # otherwise it is a medium deployment
      echo visual ansible_host="$VisualServicesIP"
      echo prog ansible_host="$ProgrammingServicesIP"
      echo stateful ansible_host="$StatefulServicesIP"
    fi
    echo controller ansible_host="$CASControllerIP"
    echo

} > /tmp/inventory.head

# add additional hostgroups
# the correct inventory.pre for the deployment size is uploaded by the cf template
cat /tmp/inventory.pre >> /tmp/inventory.head



# prepare host entries for /etc/hosts
{
    if [ -n "$ViyaServicesIP" ];
    then
        # for small deployments, point all aliases to the main services host
        echo "$ViyaServicesIP services.viya.sas services visual.viya.sas visual prog.viya.sas prog stateful.viya.sas stateful"
    else
        # for medium deployments, each host has a separate ip
        echo "$VisualServicesIP visual.viya.sas visual"
        echo "$ProgrammingServicesIP prog.viya.sas prog"
        echo "$StatefulServicesIP stateful.viya.sas stateful"
    fi
    echo "$CASControllerIP controller.viya.sas controller"

} > /tmp/hostnames.txt

# update hosts list on ansible controller
cat /tmp/hostnames.txt | sudo tee -a /etc/hosts

echo "Checking for ELB" >> "$CMDLOG"
# make sure the ELB has been created
ELBNAME=""
while [[ "$ELBNAME"  == "" ]]; do
  ELBNAME=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ElasticLoadBalancer --query StackResources[*].PhysicalResourceId --output text)
  echo "ELBNAME=${ELBNAME}" >> "$CMDLOG"
  check_stack_status
  sleep 3
done

#
# Beging Viya software installation
#
if [ -z "{{DomainName}}" ]; then
  ID=$(aws --no-paginate --region "{{AWSRegion}}" cloudformation describe-stack-resources --stack-name "{{CloudFormationStack}}" --logical-resource-id ElasticLoadBalancer --query StackResources[*].PhysicalResourceId --output text)
  DomainName=$(aws --no-paginate --region "{{AWSRegion}}" elb describe-load-balancers --load-balancer-name "$ID" --query LoadBalancerDescriptions[*].DNSName --output text)
else
  DomainName="{{DomainName}}"
fi

#
# set the SASDrive and SASStudio urls
#
PROTOCOL="https://"
if [ "{{ViyaVersion}}" = "3.4" ];then
    SASDrive="${PROTOCOL}${DomainName}/SASDrive"
    SASStudio="${PROTOCOL}${DomainName}/SASStudioV"
else
    SASDrive="${PROTOCOL}${DomainName}/SASHome"
    SASStudio="${PROTOCOL}${DomainName}/SASStudio"
fi

configure_self_signed_cert

seed_known_hosts_file

#
# pre deployment
#
echo " " >> "$CMDLOG"
echo "$(date) Start Pre-Deployment tasks (see deployment-pre.log)" >> "$CMDLOG"

# set log file for pre deployment steps
export ANSIBLE_LOG_PATH="$LOGDIR/deployment-pre.log"

# set hostnames, mount drives
ansible-playbook /tmp/ansible.pre.deployment.yml -e "AWSRegion='{{AWSRegion}}'" \
                                          -e "RAIDScript='{{RAIDScript}}'" \
                                          -e "CloudFormationStack='{{CloudFormationStack}}'" \
                                          -i /tmp/inventory.head

#
# mirror repository
#
MIRRORURL=
if [[ $(echo -n "{{DeploymentMirror}}" | cut -c1-2 | tr [:lower:] [:upper:]) == S3 ]]; then
  ansible-playbook ~/deployment-scripts/create.mirror.yml -i /tmp/inventory.head
  MIRRORURL=http://stateful.viya.sas:8008/repo_mirror
elif [[ $(echo -n "{{DeploymentMirror}}" | cut -c1-4 | tr [:lower:] [:upper:]) == HTTP ]]; then
  MIRRORURL="{{DeploymentMirror}}"
elif [ ! -z "{{DeploymentMirror}}" ]; then
  echo "ERROR: Mirror repository {{DeploymentMirror}} is not valid." >> "$CMDLOG"
  exit 1
fi

# set mirror repository, if given
MIRROROPT=
if [ -n "$MIRRORURL" ]; then
  MIRROROPT=" --repository-warehouse $MIRRORURL"
  echo "Using mirror repository $MIRRORURL" >> "$CMDLOG"
fi

echo "Deploying Viya Version {{ViyaVersion}}" >> "$CMDLOG"

# get sas-orchestration cli
echo "$(date) Download and extract sas-orchestration cli" >> "$CMDLOG"

VIRK_COMMIT_ID=

if [ "{{ViyaVersion}}" = "3.4" ]; then
#   aws s3 cp s3://mercury-deployment-data/viya3.4/sas-orchestration-cli.rpm sas-orchestration-cli.rpm 2>> "$CMDLOG"
#   sudo yum -y install sas-orchestration-cli.rpm 2>> "$CMDLOG"
#   rm sas-orchestration-cli.rpm
#   ORCHCLIPREFIX=/opt/sas/viya/home/bin

   curl -Os https://support.sas.com/installation/viya/34/sas-orchestration-cli/lax/sas-orchestration-linux.tgz 2>> "$CMDLOG"
   tar xf sas-orchestration-linux.tgz 2>> "$CMDLOG"
   rm sas-orchestration-linux.tgz
   ORCHCLIPREFIX=.
   #
   # Lock the VIRK commitId to the specific commitId used for testing the production Viya 3.4 Quickstart Deployment
   #
   VIRK_COMMIT_ID=fec76e556
else
   curl -Os https://support.sas.com/installation/viya/sas-orchestration-cli/lax/sas-orchestration.tgz 2>> "$CMDLOG"
   tar xf sas-orchestration.tgz 2>> "$CMDLOG"
   rm sas-orchestration.tgz
   ORCHCLIPREFIX=.
   #
   # Lock the VIRK commitId to the specific commitId used for testing the production Viya 3.3 Quickstart Deployment
   #
   VIRK_COMMIT_ID=e210c8d
fi

# get sas license data file
echo " " >> "$CMDLOG"
echo "$(date) Download SAS Deployment Data file" >> "$CMDLOG"
aws s3 cp s3://{{DeploymentDataLocation}} ~/deployment-data/SAS_Viya_deployment_data.zip >> "$CMDLOG"

# build playbook
echo " " >> "$CMDLOG"
echo "$(date) Build ansible playbook tar file" >> "$CMDLOG"
$ORCHCLIPREFIX/sas-orchestration build --input  ~/deployment-data/SAS_Viya_deployment_data.zip $MIRROROPT 2>> "$CMDLOG"

# untar playbook
echo " " >> "$CMDLOG"
echo "$(date) Untar ansible playbook" >> "$CMDLOG"
tar xf SAS_Viya_playbook.tgz 2>> "$CMDLOG"
rm SAS_Viya_playbook.tgz

pushd sas_viya_playbook

  # copy additional playbooks and ansible configuration file
  chmod +w ansible.cfg
  mv /tmp/ansible.* .

  # add hosts to inventory
  ansible-playbook ansible.update.inventory.yml -e "DeploymentSize={{DeploymentSize}}" -i /tmp/inventory.head

  # set prereqs on hosts
  echo " " >> "$CMDLOG"
  echo "$(date) Download and execute Viya Infrastructure Resource Kit (VIRK)" >> "$CMDLOG"
  git clone -q https://github.com/sassoftware/virk.git 2>> "$CMDLOG"

  pushd virk
    git checkout "$VIRK_COMMIT_ID" -b workbranch 2>> "$CMDLOG"
  popd
  ansible-playbook virk/playbooks/pre-install-playbook/viya_pre_install_playbook.yml --skip-tags skipmemfail,skipcoresfail,skipstoragefail,skipnicssfail,bandwidth -e 'use_pause=false'

  if [ -n "$USERPASS" ]; then
    echo " " >> "$CMDLOG"
    echo "$(date) Install and set up OpenLDAP (see deployment-openldap.log)" >> "$CMDLOG"
    install_openldap
  fi

  #
  # main deployment
  #
  echo " " >> "$CMDLOG"
  echo "$(date) Start Main Deployment (see deployment-main.log)" >> "$CMDLOG"

  # get identities configuration from openldap setup
  if [ -n "$USERPASS" ]; then
    cp ../openldap/sitedefault.yml roles/consul/files/
  fi

  # set log file for main deployment
  export ANSIBLE_LOG_PATH="$LOGDIR/deployment-main.log"

  # update vars file
  ansible-playbook ansible.update.config.yml -e "sasboot_pw='$ADMINPASS'" -e "DeploymentSize={{DeploymentSize}}"

  # main deployment
  try 3 ansible-playbook site.yml

  #
  # post deployment
  #
  echo " " >> "$CMDLOG"
  echo "$(date) Post deployment steps (see deployment-post.log)" >> "$CMDLOG"

  # set log file for post deployment steps  # set log file for pre deployment steps
  export ANSIBLE_LOG_PATH="$LOGDIR/deployment-post.log"

  ansible-playbook ansible.post.deployment.yml  -e "cas_virtual_host='$DomainName'" \
                                                -e "AWSRegion='{{AWSRegion}}'" \
                                                --tags "backups, cas"

popd
