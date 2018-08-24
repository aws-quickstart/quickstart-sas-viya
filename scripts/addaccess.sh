#!/bin/bash

# add additional cidr ranges to the security groups that allow external access to the application stack
# execute this script from the ansible controller
# invoke to with:
# addaccess.sh <--adminaccess 10.10.10.10/32> <--webaccess 10.10.10.10/32>


# make sure the script stops if there is an error
set -e


help () {
  cat <<END
Usage: $0 parameters

Parameters:

   -a|--adminaccess    CIDR range for admin access (ssh access to the ansible controller VM)
   -w|--webaccess      CIDR range for application access (HTTPS access to the application)

END
}


if [ $# -lt 1 ]; then
  help
  exit 1
fi


while [[ "$1" ]]
do

  case "$1" in
    \?|--help|-h)
      help
      exit 0
      ;;
    -a|--adminaccess)
      shift
      ADMINCIDR="$1"
      ;;
    -w|--webaccess)
      shift
      WEBCIDR="$1"
      ;;
    *)
      help
      exit 1
      ;;
  esac

  shift

done


if [ -n "$ADMINCIDR" ]; then

  # check the value is a valid cidr notation
  ipcalc -c4 "$ADMINCIDR"

  # get the security group id from the stack metadata
  BASTIONSG=$(aws --region {{AWSRegion}} cloudformation describe-stack-resources --stack-name {{StackName}} --query 'StackResources[?LogicalResourceId==`AnsibleControllerSecurityGroup`].PhysicalResourceId' --output text)
  # apply the value (for both port 22 and ICMP, for ping)
  aws --region {{AWSRegion}} ec2 authorize-security-group-ingress --group-id $BASTIONSG --cidr $ADMINCIDR --protocol tcp --port 22
  aws --region {{AWSRegion}} ec2 authorize-security-group-ingress --group-id $BASTIONSG --cidr $ADMINCIDR --protocol icmp --port -1

  echo "Current permitted ingress on port 22 for security group $BASTIONSG (AnsibleControllerSecurityGroup)"
  aws --region {{AWSRegion}} ec2 describe-security-groups --group-id $BASTIONSG --query 'SecurityGroups[].IpPermissions[?FromPort==`22`].IpRanges[][].CidrIp' --output table


fi

if [ -n "$WEBCIDR" ]; then

  # check the value is a valid cidr notation
  ipcalc -c4 "$WEBCIDR"

  # get the security group id from the stack metadata
  ELBSG=$(aws --region {{AWSRegion}} cloudformation describe-stack-resources --stack-name {{StackName}} --query 'StackResources[?LogicalResourceId==`ELBSecurityGroup`].PhysicalResourceId' --output text)
  # apply the value
  aws --region {{AWSRegion}} ec2 authorize-security-group-ingress --group-id $ELBSG --cidr $WEBCIDR --protocol tcp --port 443

  # echo the current settings
  echo "Current permitted ingress on port 443 for security group $ELBSG (ELBSecurityGroup)"
  aws --region {{AWSRegion}} ec2 describe-security-groups --group-id $ELBSG --query 'SecurityGroups[].IpPermissions[?FromPort==`443`].IpRanges[][].CidrIp' --output table


fi