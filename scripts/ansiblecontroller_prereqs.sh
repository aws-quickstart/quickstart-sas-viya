#!/bin/bash -e

# make sure we have at least java8 and ansible 2.3.2.0

install_java () {
   echo Install java 1.8
   sudo yum -y install java-1.8.0
}

if type -p java; then
    echo found java executable in PATH
    _java=java
elif [[ -n "$JAVA_HOME" ]] && [[ -x "$JAVA_HOME/bin/java" ]];  then
    echo found java executable in JAVA_HOME
    _java="$JAVA_HOME/bin/java"
else
    install_java
fi


if [[ "$_java" ]]; then
    version=$("$_java" -version 2>&1 | awk -F '"' '/version/ {print $2}')
    echo version "$version"
    if [[ "$version" < "1.8" ]]; then
        sudo yum -y remove java
        install_java
    else
        echo version 1.8 or greater
    fi
fi


if ! type -p ansible;  then
   # install Ansible
   pip install 'ansible==2.4.3'
fi

if ! type -p git; then
   # install git
   sudo yum install -y git
fi


## make log accessible as web page
## has been replaced by cloudwatch log configuration
#yum -y install httpd
#service httpd start
#sudo mkdir -p /var/www/html/status
#ln /var/log/cfn-init-cmd.log /var/www/html/status/cfn-init-cmd.log
#ln /var/log/cfn-init.log /var/www/html/status/cfn-init.log




