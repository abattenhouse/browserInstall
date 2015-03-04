#!/bin/bash

# script to install/setup dependencies for the UCSC genome browser CGIs
# call it like this as root from a command line: bash browserInstall.sh

# you can easily debug this script with 'bash -x browserInstall.sh', it 
# will show all commands then

set -u -e -o pipefail # fail on unset vars and all errors, also in pipes

APACHEDIR=/usr/local/apache
APACHECONFURL=https://raw.githubusercontent.com/maximilianh/browserInstall/master/apache.conf
HGCONFURL=https://raw.githubusercontent.com/maximilianh/browserInstall/master/hg.conf
MYSQLDIR=/var/lib/mysql

if [ "$EUID" -ne 0 ]
  then echo "This script must be run as root"
  exit 1
fi

# detect the OS version
unameStr=`uname`
DIST=none
if [[ "$unameStr" == "Darwin" ]]; then
    echo Sorry OSX is not supported
    exit 1
elif [[ "$(expr substr $(uname -s) 1 10)" == "MINGW32_NT" ]] ; then
    echo Sorry CYGWIN is not supported
    exit 1
fi

if [[ "$(expr substr $(uname -s) 1 5)" == "Linux" ]] ; then
    OS=linux
    if [ -f /etc/debian_version ] ; then
        DIST=debian  # Ubuntu, etc
        VER=$(cat /etc/debian_version)
        APACHECONF=/etc/apache2/sites-available/001-browser.conf
        APACHEUSER=www-data
    elif [[ -f /etc/redhat-release ]] ; then
        DIST=redhat
        VER=$(cat /etc/redhat-release)
        APACHECONF=/etc/httpd/conf.d/001-browser.conf
        APACHEUSER=apache
    fi
fi

if [ "$DIST" == "none" ]; then
    echo Sorry, unable to detect your linux distribution. 
    echo Currently only Debian/Redhat-like distributions are supported.
    exit 3
fi

echo UCSC Genome Browser installation script
echo Detected OS: $OS/$DIST, $VER

# UPDATE MODE, parameter "update": This is not for the initial install, but
# later, when the user wants to update the browser. This can be used from
# cronjobs.

if [ "${1:-}" == "update" ]; then
   # update the CGIs
   rsync -avzP --delete --exclude hg.conf hgdownload.cse.ucsc.edu::cgi-bin/ $APACHEDIR/cgi-bin/
   # update the html docs
   rsync -avzP --delete --exclude trash hgdownload.cse.ucsc.edu::htdocs/ $APACHEDIR/htdocs/ 
   # assign all downloaded files to a valid user. 
   chown -R $APACHEUSER.$APACHEUSER $APACHEDIR/*
   echo update finished
   exit 10
fi

# Start with apache/mysql setup if the script is run without a parameter

if [[ "$#" == "0" ]]; then
    echo This script will now install/configure mysql and apache if not yet installed. 
    echo It will also open port 80/http.
    echo Please press any key...
    read -n 1 -s
    
    # -----  DEBIAN / UBUNTU - SPECIFIC part
    if [[ "$DIST" == "debian" ]]; then
       # get repo lists
       apt-get update
       # apache and mysql are absolutely required
       apt-get install apache2
       apt-get install mysql-server
       # ghostscript is required for PDF output
       apt-get install ghostscript

       # gmt is not required. install fails if /etc/apt/sources.list does not contain
       # a 'universe' repository mirror. Can be safely commented out. Only used
       # for world maps of alleles on the dbSNP page.
       apt-get install gmt
    
       # activate required modules
       a2enmod include # we need SSI and CGIs
       a2enmod cgid
       a2enmod authz_core # see $APACHECONF why this is necessary
       #a2dismod deflate # allows to partial page rendering in firefox during page load

       # install the apache config for the browser
       if [ ! -f $APACHECONF ]; then
          echo Creating $APACHECONF
          wget -q $APACHECONFURL -O $APACHECONF
          a2ensite 001-browser
          a2dissite 000-default
       fi
       # restart
       service apache2 restart
       # ----- END OF DEBIAN SPECIFIC PART
    
    # ----- REDHAT / FEDORA / CENTOS specific part
    elif [[ "$DIST" == "redhat" ]]; then
        # make sure we have wget and EPEL
        yum -y install wget epel-release

        # install apache if not installed yet
        if [ ! -f /usr/sbin/httpd ]; then
            echo Installing Apache
            yum -y install httpd
            # start apache on boot
            chkconfig --level 2345 httpd on
        else
            echo Apache already installed
        fi
    
        # download the apache config
        if [ ! -f $APACHECONF ]; then
            echo Creating $APACHECONF
            wget -q $APACHECONFURL -O $APACHECONF
        fi
        service httpd restart

        # centos provides only a package called mariadb-server
        if yum list mysql-server 2> /dev/null ; then
            MYSQLPKG=mysql-server
        elif yum list mariadb-server 2> /dev/null ; then
            MYSQLPKG=mariadb-server
        else
            echo Cannot find a mysql-server package in the current yum repos
            exit 100
        fi

        if [ ! -f /usr/bin/mysqld_safe ]; then
            echo Installing Mysql
            yum -y install $MYSQLPKG

            # Fedora 20 has the package mysql-server but it contains mariadb
            MYSQLD=mysqld
            MYSQLVER=`mysql --version`
            if [[ $MYSQLVER =~ "MariaDB" ]]; then
                MYSQLD=mariadb
            fi
                
            # start mysql on boot
            chkconfig --level 2345 $MYSQLD on 
            # start mysql now
            /sbin/service $MYSQLD start
            # redhat distros do not secure mysql by default
            # so define root password, remove test accounts, etc
            mysql_secure_installation
        else
            echo Mysql already installed
        fi
    
        # centos 7 and fedora 20 do not provide libpng by default
        if ldconfig -p | grep libpng12.so > /dev/null; then
            echo libpng12 found
        else
            yum -y install libpng12
        fi

        yum -y install ghostscript

        # this triggers an error if rpmforge is not installed
        # but if rpmforge is installed, we need the option
        # psxy is not that important, we just skip it for now
        #yum -y install GMT hdf5 --disablerepo=rpmforge

        if [ -f /etc/init.d/iptables ]; then
           echo Opening port 80 for incoming connections
           iptables -I INPUT 1 -i eth0 -p tcp --dport 80 -m state --state NEW,ESTABLISHED -j ACCEPT
           service iptables save
        fi
        # ---- END OF REDHAT SPECIFIC PART
    fi

    # DETECT AND DEACTIVATE SELINUX
    if [ -f /sbin/selinuxenabled ]; then
        if /sbin/selinuxenabled; then
           echo
           echo The Genome Browser requires that SELINUX is deactivated.
           echo Deactivating it now.
           echo Please press any key...
           read -n 1 -s
           setenforce 0
           sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/sysconfig/selinux
        fi
    fi

    # create a little basic .my.cnf for the current root user
    # so the mysql root password setup is easier
    if [ ! -f ~/.my.cnf ]; then
       echo '[client]' >> ~/.my.cnf
       echo user=root >> ~/.my.cnf
       echo password=YOURPASSWORD >> ~/.my.cnf
       chmod 600 ~/.my.cnf

       echo
       echo A file ${HOME}/.my.cnf was created with default values
       echo Edit the file ${HOME}/.my.cnf and replace YOURPASSWORD with the mysql root
       echo password that you defined for your mysql installation.
    else
       echo
       echo A file ${HOME}/.my.cnf already exists
       echo Edit the file ${HOME}/.my.cnf and make sure there is a '[client]' section
       echo and under it at least two lines with 'user=root' and 'password=YOURPASSWORD'.
    fi

    echo "Then run this script again with the parameter download (bash $0 download) to continue."
    exit 0
fi

# MYSQL CONFIGURATION and CGI DOWNLOAD

if [ "${1:-}" == "download" ]; then
    # test if we can connect to the mysql server
    # need to temporarilydeactivate error abort mode, in case mysql cannot connect
    set +e 
    mysql -e "show tables;" mysql > /dev/null 2>&1
    if [ "$?" -ne 0 ]; then
            echo "Cannot connect to mysql database server."
            echo "Edit ${HOME}/.my.cnf and run this script again with the 'mysql' parameter"
            exit 255
    fi
    set -e

    # -------------------
    # Mysql setup
    # -------------------
    echo Creating Mysql databases customTrash and hgcentral
    echo Please press any key...
    read -n 1 -s
    mysql -e 'create database if not exists customTrash; create database if not exists hgcentral;'
    wget -q http://hgdownload.cse.ucsc.edu/admin/hgcentral.sql -O - | mysql hgcentral

    echo
    echo "Will now grant permissions to browser database access users:"
    echo "User: 'browser', password: 'genome' - full database access permissions"
    echo "User: 'readonly', password: 'access' - read only access for CGI binaries"
    echo "User: 'readwrite', password: 'update' - readwrite access for hgcentral DB"
    echo Please press any key...
    read -n 1 -s
    
    #  Full access to all databases for the user 'browser'
    #       This would be for browser developers that need read/write access
    #       to all database tables.  
    mysql -e "GRANT SELECT, INSERT, UPDATE, DELETE, FILE, "\
"CREATE, DROP, ALTER, CREATE TEMPORARY TABLES on *.* TO browser@localhost "\
"IDENTIFIED BY 'genome';"

    # FILE permission for this user to all databases to allow DB table loading with
    #       statements such as: "LOAD DATA INFILE file.tab"
    # For security details please read:
    #       http://dev.mysql.com/doc/refman/5.1/en/load-data.html
    #       http://dev.mysql.com/doc/refman/5.1/en/load-data-local.html
    mysql -e "GRANT FILE on *.* TO browser@localhost IDENTIFIED BY 'genome';" 

    #   Read only access to genome databases for the browser CGI binaries
    mysql -e "GRANT SELECT, CREATE TEMPORARY TABLES on "\
"*.* TO readonly@localhost IDENTIFIED BY 'access';"

    # Readwrite access to hgcentral for browser CGI binaries to maintain session state
    mysql -e "GRANT SELECT, INSERT, UPDATE, "\
"DELETE, CREATE, DROP, ALTER on hgcentral.* TO readwrite@localhost "\
"IDENTIFIED BY 'update';"

    # the custom track database needs it own user and permissions
    mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,DROP,ALTER,INDEX "\
"on customTrash.* TO ctdbuser@localhost IDENTIFIED by 'ctdbpassword';"

    # by default hgGateway needs an empty hg19 database
    mysql -e 'CREATE DATABASE IF NOT EXISTS hg19'

    mysql -e "FLUSH PRIVILEGES;"

   # -------------------
   # CGI installation
   # -------------------
   echo
   echo Now creating /usr/local/apache and downloading its files from UCSC via rsync
   echo Please press any key...
   read -n 1 -s
   # create apache directories: HTML files, CGIs, temporary and custom track files
   mkdir -p $APACHEDIR/htdocs $APACHEDIR/cgi-bin $APACHEDIR/trash $APACHEDIR/trash/customTrash

   # the CGIs create links to images in /trash which need to be accessible from htdocs
   cd $APACHEDIR/htdocs 
   ln -fs ../trash

   # download the sample hg.conf into the cgi-bin directory
   wget $HGCONFURL -O $APACHEDIR/cgi-bin/hg.conf

   # redhat distros have the same default socket location set in mysql as
   # in our binaries. To allow mysql to connect, we have to remove the socket path.
   # Also change the psxy path to the correct path for redhat, /usr/bin/
   if [ "$DIST" == "redhat" ]; then
        sed -i "/socket=/s/^/#/" $APACHEDIR/cgi-bin/hg.conf
        sed -i "/^hgc\./s/.usr.lib.gmt.bin/\/usr\/bin/" $APACHEDIR/cgi-bin/hg.conf
   fi

   # download the CGIs
   rsync -avzP hgdownload.cse.ucsc.edu::cgi-bin/ $APACHEDIR/cgi-bin/

   # download the html docs
   rsync -avzP hgdownload.cse.ucsc.edu::htdocs/ $APACHEDIR/htdocs/ 

   # assign all files just downloaded to a valid user. 
   # This also allows apache to write into the trash dir
   chown -R $APACHEUSER.$APACHEUSER $APACHEDIR/*

   echo
   echo Install complete. You should now be able to point your web browser to this machine
   echo and use your UCSC Genome Browser mirror.
   echo Notice that this mirror is still configured to use Mysql and data files loaded
   echo through the internet from UCSC. From most locations on the world, this is very slow.
   echo
   echo If you want to download a genome and all its files now, call this script with
   echo the parameters "get <name>", e.g. "bash browserInstall.sh get mm10"
   echo 
   echo Also note that by the installation assumes that emails cannot be sent from
   echo this machine. New browser user accounts will not receive confirmation emails.
   echo To change this, edit the file $APACHEDIR/cgi-bin/hg.conf and modify the settings
   echo 'that start with "login.", mainly "login.mailReturnAddr"'.
   echo
   echo Please send any other questions to the mailing list, genome-mirror@soe.ucsc.edu .
fi

# GENOME DOWNLOAD

if [ "${1:-}" == "get" ]; then
   DBS=${*:2}
   echo
   echo Now downloading these databases plus hgFixed and proteome from the UCSC download server: $DBS
   echo Press any key...
   read -n 1 -s

   for db in $DBS; do
      echo Downloading Mysql files for DB $db
      rsync -avzp hgdownload.cse.ucsc.edu::mysql/$db/ $MYSQLDIR/$db/
      chown -R mysql.mysql $MYSQLDIR/$db

      echo Downloading /gbdb files for DB $db
      mkdir -p /gbdb
      rsync -avzp hgdownload.cse.ucsc.edu::gbdb/$db/ /gbdb/$db/
      chown -R $APACHEUSER.$APACHEUSER /gbdb/$db
   done

   echo Now downloading species-independent mysql databases...
   for db in proteome uniProt go hgFixed; do
      echo Downloading Mysql files for DB $db
      rsync -avzp hgdownload.cse.ucsc.edu::mysql/$db/ $MYSQLDIR/$db/
      chown -R mysql.mysql $MYSQLDIR/$db
   done
fi
