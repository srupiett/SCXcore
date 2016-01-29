#!/bin/sh

#
# Shell Bundle installer package for the SCX project
#

set -e
PATH=/usr/bin:/usr/sbin:/bin:/sbin
umask 022

# Can't use something like 'readlink -e $0' because that doesn't work everywhere
# And HP doesn't define $PWD in a sudo environment, so we define our own
case $0 in
    /*|~*)
        SCRIPT_INDIRECT="`dirname $0`"
        ;;
    *)
        PWD="`pwd`"
        SCRIPT_INDIRECT="`dirname $PWD/$0`"
        ;;
esac

SCRIPT_DIR="`(cd \"$SCRIPT_INDIRECT\"; pwd -P)`"
SCRIPT="$SCRIPT_DIR/`basename $0`"
EXTRACT_DIR="`pwd -P`/scxbundle.$$"
DPKG_CONF_QUALS="--force-confold --force-confdef"

# These symbols will get replaced during the bundle creation process.
#
# The PLATFORM symbol should contain ONE of the following:
#       Linux, HPUX, AIX, SunOS
#
# The OM_PKG symbol should contain something like:
#       scx-1.5.1-115.rhel.6.x64 (script adds .rpm or .deb, as appropriate)
# Note that for non-Linux platforms, this symbol should contain full filename.
#
# PROVIDER_ONLY is normally set to '0'. Set to non-zero if you wish to build a
# version of SCX that is only the provider (no OMI, no bundled packages). This
# essentially provides a "scx-cimprov" type package if just the provider alone
# must be included as part of some other package.

PLATFORM=<PLATFORM_TYPE>
TAR_FILE=<TAR_FILE>
OM_PKG=<OM_PKG>
OMI_PKG=<OMI_PKG>
PROVIDER_ONLY=0

SCRIPT_LEN=<SCRIPT_LEN>
SCRIPT_LEN_PLUS_ONE=<SCRIPT_LEN+1>


usage()
{
    echo "usage: $1 [OPTIONS]"
    echo "Options:"
    echo "  --extract              Extract contents and exit."
    echo "  --force                Force upgrade (override version checks)."
    echo "  --install              Install the package from the system."
    echo "  --purge                Uninstall the package and remove all related data."
    echo "  --remove               Uninstall the package from the system."
    echo "  --restart-deps         Reconfigure and restart dependent service"
    echo "  --source-references    Show source code reference hashes."
    echo "  --upgrade              Upgrade the package in the system."
    echo "  --debug                use shell debug mode."
    echo "  -? | --help            shows this usage text."
}

source_references()
{
    cat <<EOF
-- Source code references --
EOF
}

cleanup_and_exit()
{
    # $1: Exit status
    # $2: Non-blank (if we're not to delete bundles), otherwise empty

    if [ "$PLATFORM" = "SunOS" ]; then
        rm -f scx-admin scx-admin-upgrade
        rm -f /tmp/.ai.pkg.zone.lock*
    fi

    if [ -z "$2" -a -d "$EXTRACT_DIR" ]; then
        cd $EXTRACT_DIR/..
        rm -rf $EXTRACT_DIR
    fi

    if [ -n "$1" ]; then
        exit $1
    else
        exit 0
    fi
}


verifyNoInstallationOption()
{
    if [ -n "${installMode}" ]; then
        echo "$0: Conflicting qualifiers, exiting" >&2
        cleanup_and_exit 1
    fi

    return;
}

ulinux_detect_openssl_version() {
    TMPBINDIR=
    # the system OpenSSL version is 0.9.8.  Likewise with OPENSSL_SYSTEM_VERSION_100
    OPENSSL_SYSTEM_VERSION_FULL=`openssl version | awk '{print $2}'`
    OPENSSL_SYSTEM_VERSION_098=`echo $OPENSSL_SYSTEM_VERSION_FULL | grep -Eq '^0.9.8'; echo $?`
    OPENSSL_SYSTEM_VERSION_100=`echo $OPENSSL_SYSTEM_VERSION_FULL | grep -Eq '^1.0.'; echo $?`
    if [ $OPENSSL_SYSTEM_VERSION_098 = 0 ]; then
        TMPBINDIR=098
    elif [ $OPENSSL_SYSTEM_VERSION_100 = 0 ]; then
        TMPBINDIR=100
    else
        echo "Error: This system does not have a supported version of OpenSSL installed."
        echo "This system's OpenSSL version: $OPENSSL_SYSTEM_VERSION_FULL"
        echo "Supported versions: 0.9.8*, 1.0.*"
        cleanup_and_exit 60
    fi
}

# Only Solaris doesn't allow the -n qualifier in 'tail' command
[ "$PLATFORM" != "SunOS" ] && TAIL_CQUAL="-n"

while [ $# -ne 0 ]
do
    case "$1" in
        --extract-script)
            # hidden option, not part of usage
            # echo "  --extract-script FILE  extract the script to FILE."
            head -${SCRIPT_LEN} "${SCRIPT}" > "$2"
            local shouldexit=true
            shift 2
            ;;

        --extract-binary)
            # hidden option, not part of usage
            # echo "  --extract-binary FILE  extract the binary to FILE."
            tail $TAIL_CQUAL +${SCRIPT_LEN_PLUS_ONE} "${SCRIPT}" > "$2"
            local shouldexit=true
            shift 2
            ;;

        --extract)
            verifyNoInstallationOption
            installMode=E
            shift 1
            ;;

        --force)
            forceFlag=true
            shift 1
            ;;

        --install)
            verifyNoInstallationOption
            installMode=I
            shift 1
            ;;

        --purge)
            verifyNoInstallationOption
            installMode=P
            shouldexit=true
            shift 1
            ;;

        --remove)
            verifyNoInstallationOption
            installMode=R
            shouldexit=true
            shift 1
            ;;

        --restart-deps)
            restartDependencies=--restart-deps
            shift 1
            ;;

        --source-references)
            source_references
            cleanup_and_exit 0
            ;;

        --upgrade)
            verifyNoInstallationOption
            installMode=U
            shift 1
            ;;

        --debug)
            echo "Starting shell debug mode." >&2
            echo "" >&2
            echo "SCRIPT_INDIRECT: $SCRIPT_INDIRECT" >&2
            echo "SCRIPT_DIR:      $SCRIPT_DIR" >&2
            echo "EXTRACT DIR:     $EXTRACT_DIR" >&2
            echo "SCRIPT:          $SCRIPT" >&2
            echo >&2
            set -x
            shift 1
            ;;

        -? | --help)
            usage `basename $0` >&2
            cleanup_and_exit 0
            ;;

        *)
            usage `basename $0` >&2
            cleanup_and_exit 1
            ;;
    esac
done

ulinux_detect_installer()
{
    INSTALLER=

    # If DPKG lives here, assume we use that. Otherwise we use RPM.
    type dpkg > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        INSTALLER=DPKG
    else
        INSTALLER=RPM
    fi
}

# $1 - The name of the package to check as to whether it's installed
check_if_pkg_is_installed() {
    case "$PLATFORM" in
        Linux)
	    ulinux_detect_installer

            if [ "$INSTALLER" = "DPKG" ]; then
                dpkg -s $1 | grep Status | grep " installed" 2> /dev/null 1> /dev/null
            else
                rpm -q $1 2> /dev/null 1> /dev/null
            fi
            ;;

        AIX)
            lslpp $1 2> /dev/null 1> /dev/null
            ;;

        HPUX)
            swlist $1 2> /dev/null 1> /dev/null
            ;;

        SunOS)
            /usr/bin/pkginfo MSFT$1 2> /dev/null 1> /dev/null
            ;;
    esac
    return $?
}

# $1 - The filename of the package to be installed
# $2 - The package name of the package to be installed
pkg_add() {
    pkg_filename=$1
    pkg_name=$2

    echo "----- Installing package: $pkg_name ($pkg_filename) -----"

    case "$PLATFORM" in
        Linux)
	    ulinux_detect_openssl_version
	    pkg_filename=$TMPBINDIR/$pkg_filename

            ulinux_detect_installer

            if [ "$INSTALLER" = "DPKG" ]; then
                dpkg ${DPKG_CONF_QUALS} --install --refuse-downgrade ${pkg_filename}.deb
            else
                rpm --install ${pkg_filename}.rpm
            fi
            ;;

        AIX)
            /usr/sbin/installp -a -X -d $pkg_filename ${pkg_name}.rte
            ;;
        
        HPUX)
            /usr/sbin/swinstall -s $PWD/$pkg_filename $pkg_name
            ;;
        
        SunOS)
            /usr/sbin/pkgadd -a scx-admin -n -d $pkg_filename MSFT$pkg_name
            ;;
    esac
}

# $1 - The package name of the package to be uninstalled
# $2 - Optional parameter. Only used when forcibly removing omi on SunOS
pkg_rm() {
    echo "----- Removing package: $1 -----"
    case "$PLATFORM" in
        Linux)
            ulinux_detect_installer
            if [ "$INSTALLER" = "DPKG" ]; then
                if [ "$installMode" = "P" ]; then
                    dpkg --purge ${1}
                else
                    dpkg --remove ${1}
                fi
            else
                rpm --erase ${1}
            fi
            ;;

        AIX)
            /usr/sbin/installp -u $1.rte # 1> /dev/null 2> /dev/null
            ;;

        HPUX)
            /usr/sbin/swremove $1 # 1> /dev/null 2> /dev/null
            ;;

        SunOS)
            if [ "$2" = "force" ]; then
                /usr/sbin/pkgrm -a scx-admin-upgrade -n MSFT$1 # 1> /dev/null 2> /dev/null
            else
                /usr/sbin/pkgrm -a scx-admin -n MSFT$1 # 1> /dev/null 2> /dev/null
            fi
            ;;
    esac
}


# $1 - The filename of the package to be installed
# $2 - The package name of the package to be installed
pkg_upd() {
    pkg_filename=$1
    pkg_name=$2

    case "$PLATFORM" in
        Linux)
            ulinux_detect_openssl_version
            pkg_filename=$TMPBINDIR/$pkg_filename

            ulinux_detect_installer

            if [ "$INSTALLER" = "DPKG" ]; then
                [ -z "${forceFlag}" -o "${pkg_name}" = "omi" ] && FORCE="--refuse-downgrade" || FORCE=""
                dpkg ${DPKG_CONF_QUALS} --install $FORCE ${pkg_filename}.deb

                export PATH=/usr/local/sbin:/usr/sbin:/sbin:$PATH
            else
                [ -n "${forceFlag}" -o "${pkg_name}" = "omi" ] && FORCE="--force" || FORCE=""
                rpm --upgrade $FORCE ${pkg_filename}.rpm
            fi
            ;;

        AIX)
            [ -n "${forceFlag}" -o "${pkg_name}" = "omi" ] && FORCE="-F" || FORCE=""
            /usr/sbin/installp -a -X $FORCE -d $1 $pkg_name.rte
            ;;

        HPUX)
            [ -n "${forceFlag}" -o "${pkg_name}" = "omi" ] && FORCE="-x allow_downdate=true -x reinstall=true" || FORCE=""

            /usr/sbin/swinstall $FORCE -s $PWD/$1 $pkg_name
            ;;

        SunOS)
            # No notion of "--force" since Sun package has no notion of update
            check_if_pkg_is_installed ${pkg_name}
            if [ $? -eq 0 ]; then
                # Check version numbers of this package, both installed and the new file
                INSTALLED_VERSION=`pkginfo -l MSFT${pkg_name} | grep VERSION | awk '{ print $2 }'`
                FILE_VERSION=`pkginfo -l -d $1 | grep VERSION | awk '{ print $2 }'`
                IV_1=`echo $INSTALLED_VERSION | awk -F. '{ print $1 }'`
                IV_2=`echo $INSTALLED_VERSION | awk -F. '{ print $2 }'`
                IV_3=`echo $INSTALLED_VERSION | awk -F. '{ print $3 }' | awk -F- '{ print $1 }'`
                IV_4=`echo $INSTALLED_VERSION | awk -F. '{ print $3 }' | awk -F- '{ print $2 }'`
                FV_1=`echo $FILE_VERSION | awk -F. '{ print $1 }'`
                FV_2=`echo $FILE_VERSION | awk -F. '{ print $2 }'`
                FV_3=`echo $FILE_VERSION | awk -F. '{ print $3 }' | awk -F- '{ print $1 }'`
                FV_4=`echo $FILE_VERSION | awk -F. '{ print $3 }' | awk -F- '{ print $2 }'`

                # If the new version is greater than the previous, upgrade it. We expect at least 3 tokens in the version.
                UPGRADE_PACKAGE=0
                if [ $FV_1 -gt $IV_1 -o $FV_2 -gt $IV_2 -o  $FV_3 -gt $IV_3 ]; then
                    UPGRADE_PACKAGE=1
                elif [ -n "$FV_4" -a -n "$IV_4" ]; then
                    if [ $FV_4 -gt $IV_4 ]; then
                        UPGRADE_PACKAGE=1
                    fi
                fi

                if [ $UPGRADE_PACKAGE -eq 1 ]; then
                    pkg_rm $pkg_name force
                    pkg_add $1 $pkg_name
                fi
            else
                pkg_add $1 $pkg_name
            fi
            ;;
    esac
}

case "$PLATFORM" in
    Linux|AIX|HPUX|SunOS)
        ;;

    *)
        echo "Invalid platform encoded in variable \$PACKAGE; aborting" >&2
        cleanup_and_exit 2
esac

if [ -z "${installMode}" ]; then
    echo "$0: No options specified, specify --help for help" >&2
    cleanup_and_exit 3
fi

#
# Note: From this point, we're in a temporary directory. This aids in cleanup
# from bundled packages in our package (we just remove the diretory when done).
#

mkdir -p $EXTRACT_DIR
cd $EXTRACT_DIR

# Create installation administrative file for Solaris platform if needed
if [ "$PLATFORM" = "SunOS" ]; then
    echo "mail=" > scx-admin
    echo "instance=overwrite" >> scx-admin
    echo "partial=nocheck" >> scx-admin
    echo "idepend=quit" >> scx-admin
    echo "rdepend=quit" >> scx-admin
    echo "conflict=nocheck" >> scx-admin
    echo "action=nocheck" >> scx-admin
    echo "basedir=default" >> scx-admin

    echo "mail=" > scx-admin-upgrade
    echo "instance=overwrite" >> scx-admin-upgrade
    echo "partial=nocheck" >> scx-admin-upgrade
    echo "idepend=quit" >> scx-admin-upgrade
    echo "rdepend=nocheck" >> scx-admin-upgrade
    echo "conflict=nocheck" >> scx-admin-upgrade
    echo "action=nocheck" >> scx-admin-upgrade
    echo "basedir=default" >> scx-admin-upgrade
fi

# Do we need to remove the package?
set +e
if [ "$installMode" = "R" -o "$installMode" = "P" ]
then
    if [ -f /opt/microsoft/scx/bin/uninstall ]; then
        /opt/microsoft/scx/bin/uninstall $installMode
    else
        # This is an old kit.  Let's remove each separate provider package
        for i in /opt/microsoft/*-cimprov; do
            PKG_NAME=`basename $i`
            if [ "$PKG_NAME" != "*-cimprov" ]; then
                echo "Removing ${PKG_NAME} ..."
                pkg_rm ${PKG_NAME}
            fi
        done

        # Now just simply pkg_rm scx (and omi if it has no dependencies)
        pkg_rm scx
	pkg_rm omi
    fi

    if [ "$installMode" = "P" ]
    then
        echo "Purging all files in cross-platform agent ..."
        rm -rf /etc/opt/microsoft/*-cimprov /etc/opt/microsoft/scx /opt/microsoft/*-cimprov /opt/microsoft/scx /var/opt/microsoft/*-cimprov /var/opt/microsoft/scx
	rmdir /etc/opt/microsoft /opt/microsoft /var/opt/microsoft 1>/dev/null 2>/dev/null

        # If OMI is not installed, purge its directories as well.
        check_if_pkg_is_installed omi
        if [ $? -ne 0 ]; then
            rm -rf /etc/opt/omi /opt/omi /var/opt/omi
        fi
    fi
fi

if [ -n "${shouldexit}" ]
then
    # when extracting script/tarball don't also install
    cleanup_and_exit 0
fi

#
# Do stuff before extracting the binary here, for example test [ `id -u` -eq 0 ],
# validate space, platform, uninstall a previous version, backup config data, etc...
#

#
# Extract the binary here.
#

echo "Extracting..."

case "$PLATFORM" in
    Linux)
        tail -n +${SCRIPT_LEN_PLUS_ONE} "${SCRIPT}" | tar xzf -
        ;;

    AIX)
        tail -n +${SCRIPT_LEN_PLUS_ONE} "${SCRIPT}" | gunzip -c | tar xf -
        ;;

    HPUX|SunOS)
        tail $TAIL_CQUAL +${SCRIPT_LEN_PLUS_ONE} "${SCRIPT}" | zcat - | tar xf -
        ;;

    *)
        echo "Invalid platform encoded in variable \$PACKAGE; aborting" >&2
        cleanup_and_exit 2
esac

STATUS=$?
if [ ${STATUS} -ne 0 ]
then
    echo "Failed: could not extract the install bundle."
    cleanup_and_exit ${STATUS}
fi

#
# Do stuff after extracting the binary here, such as actually installing the package.
#

EXIT_STATUS=0
SCX_EXIT_STATUS=0
OMI_EXIT_STATUS=0
BUNDLE_EXIT_STATUS=0

case "$installMode" in
    E)
        # Files are extracted, so just exit
        cleanup_and_exit 0 "SAVE"
        ;;

    I)
        echo "Installing cross-platform agent ..."
        if [ "$PLATFORM" = "SunOS" ]; then
            check_if_pkg_is_installed scx
            if [ $? -eq 0 ]; then
                echo "ERROR: SCX package is already installed"
                cleanup_and_exit 2
            fi
        fi

        if [ $PROVIDER_ONLY -eq 0 ]; then
            check_if_pkg_is_installed omi
            if [ $? -eq 0 ]; then
                pkg_upd $OMI_PKG omi
                # It is acceptable that this fails due to the new omi being 
                # the same version (or less) than the one currently installed.
                OMI_EXIT_STATUS=0
            else
                pkg_add $OMI_PKG omi
                OMI_EXIT_STATUS=$?
            fi
        fi

        pkg_add $OM_PKG scx
        SCX_EXIT_STATUS=$?

        if [ $PROVIDER_ONLY -eq 0 ]; then
            # Install bundled providers
            [ -n "${forceFlag}" ] && FORCE="--force" || FORCE=""
            for i in *-oss-test.sh; do
                # If filespec didn't expand, break out of loop
                [ ! -f $i ] && break
                ./$i
                if [ $? -eq 0 ]; then
                    OSS_BUNDLE=`basename $i -oss-test.sh`
                    ./${OSS_BUNDLE}-cimprov-*.sh --install $FORCE $restartDependencies
                    TEMP_STATUS=$?
                    [ $TEMP_STATUS -ne 0 ] && BUNDLE_EXIT_STATUS="$TEMP_STATUS"
                fi
            done
        fi
        ;;

    U)
        echo "Updating cross-platform agent ..."
        if [ $PROVIDER_ONLY -eq 0 ]; then
            check_if_pkg_is_installed omi
            if [ $? -eq 0 ]; then
                pkg_upd $OMI_PKG omi
                # It is acceptable that this fails due to the new omi being 
                # the same version (or less) than the one currently installed.
                OMI_EXIT_STATUS=0
            else
                pkg_add $OMI_PKG omi
                OMI_EXIT_STATUS=$?  
            fi
        fi

        pkg_upd $OM_PKG scx
        SCX_EXIT_STATUS=$?

        if [ $PROVIDER_ONLY -eq 0 ]; then
            # Upgrade bundled providers
            #   Temporarily force upgrades via --force; this will unblock the test team
            #   This change may or may not be permanent; we'll see
            # [ -n "${forceFlag}" ] && FORCE="--force" || FORCE=""
            FORCE="--force"
            for i in *-oss-test.sh; do
                # If filespec didn't expand, break out of loop
                [ ! -f $i ] && break
                ./$i
                if [ $? -eq 0 ]; then
                    OSS_BUNDLE=`basename $i -oss-test.sh`
                    ./${OSS_BUNDLE}-cimprov-*.sh --upgrade $FORCE $restartDependencies
                    TEMP_STATUS=$?
                    [ $TEMP_STATUS -ne 0 ] && BUNDLE_EXIT_STATUS="$TEMP_STATUS"
                fi
            done
        fi
        ;;

    *)
        echo "$0: Invalid setting of variable \$installMode, exiting" >&2
        cleanup_and_exit 2
esac

# Remove temporary files (now part of cleanup_and_exit) and exit

if [ "$SCX_EXIT_STATUS" -ne 0 -o "$OMI_EXIT_STATUS" -ne 0 -o "$BUNDLE_EXIT_STATUS" -ne 0 ]; then
    cleanup_and_exit 1
else
    cleanup_and_exit 0
fi

#####>>- This must be the last line of this script, followed by a single empty line. -<<#####
