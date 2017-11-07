#!/bin/bash
#
# Backup a server with S3QL.
#
# VERSION       :2.1.1
# DATE          :2017-10-23
# AUTHOR        :Viktor Szépe <viktor@szepe.net>
# URL           :https://github.com/szepeviktor/debian-server-tools
# LICENSE       :The MIT License (MIT)
# BASH-VERSION  :4.2+
# DEPENDS       :apt-get install debconf-utils rsync mariadb-client percona-xtrabackup s3ql
# DOCS          :https://www.percona.com/doc/percona-xtrabackup/2.3/innobackupex/incremental_backups_innobackupex.html
# LOCATION      :/usr/local/sbin/system-backup.sh
# CI            :shellcheck -e SC2086 system-backup.sh
# CONFIG        :/root/.config/system-backup/configuration
# CRON.D        :10 3	* * *	root	/usr/local/sbin/system-backup.sh

# Usage
#
# Create S3QL configuration file
#     mkdir /root/.s3ql; editor /root/.s3ql/authinfo2; chmod 0600 /root/.s3ql/authinfo2
#
# Example S3QL configuration for Swift
#     [provider]
#     storage-url: STORAGE_URL/CONTAINER
#     backend-login: OS_TENANT_NAME:OS_USERNAME
#     backend-password: OS_PASSWORD
#     fs-passphrase: $(apg -m32 -n1)
#
# Create configuration file
#     mkdir /root/.config/system-backup; editor /root/.config/system-backup/configuration
#
# Example configuration
#     #STORAGE_URL="local:///media/backup-server.sshfs"
#     #STORAGE_URL="swiftks://auth.cloud.ovh.net/OS_REGION_NAME:CONTAINER/PREFIX_"
#     STORAGE_URL="s3://REGION/BUCKET/PREFIX_"
#     TARGET="/media/server-backup.s3ql"
#     #MOUNT_OPTIONS="--threads 4 --compress zlib-5"
#     AUTHFILE="/root/.s3ql/authinfo2"
#     DB_EXCLUDE="excluded-db1|excluded-db2"
#     HCHK_UUID="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
#
# Add an [xtrabackup] section to /root/.my.cnf
#     editor /root/.my.cnf
#
# Format storage
#     /usr/bin/mkfs.s3ql "$STORAGE_URL"
#
# Save encryption master key!
#
# Create target directory
#     mkdir "$TARGET"
#
# Excluded path example in /home
#     /user/website/session/
#
# Mount storage manually
#     system-backup.sh -m
#
# Save /root files to "${TARGET}/_root"
#
# Unmount storage
#     system-backup.sh -u
#
# Check incremental status of InnoDB backups
#     grep '^incremental =' innodb/*/xtrabackup_info

CONFIG="/root/.config/system-backup/configuration"
HOME_EXCLUDE_LIST="/root/.config/system-backup/exclude.list"

Onexit() {
    local -i RET="$1"
    local BASH_CMD="$2"

    set +e

    if [ "$RET" -ne 0 ]; then
        #if /usr/bin/s3qlstat ${S3QL_OPT} "$TARGET" &> /dev/null; then
        if [ -e "${TARGET}/.__s3ql__ctrl__" ]; then
            /usr/bin/s3qlctrl ${S3QL_OPT} flushcache "$TARGET"
            /usr/bin/umount.s3ql ${S3QL_OPT} "$TARGET"
        fi

        echo "COMMAND: ${BASH_CMD}" 1>&2
    fi

    exit "$RET"
}

Error() {
    local STATUS="$1"

    set +e

    shift

    echo "ERROR ${STATUS}: $*" 1>&2

    exit "$STATUS"
}

Rotate_weekly() { # Error 9x
    local DIR="$1"
    local -i PREVIOUS

    if [ -z "$DIR" ]; then
        Error 90 "No directory to rotate"
    fi

    if [ ! -d "${TARGET}/${DIR}/6" ]; then
        mkdir "${TARGET}/${DIR}"/{0..6} 1>&2 || Error 91 "Cannot create weekday directories"
    fi

    PREVIOUS="$((CURRENT_DAY - 1))"
    if [ "$PREVIOUS" -lt 0 ]; then
        PREVIOUS="6"
    fi

    /usr/bin/s3qlrm ${S3QL_OPT} "${TARGET}/${DIR}/${CURRENT_DAY}" 1>&2 \
        || Error 92 "Failed to remove current day's directory"
    /usr/bin/s3qlcp ${S3QL_OPT} "${TARGET}/${DIR}/${PREVIOUS}" "${TARGET}/${DIR}/${CURRENT_DAY}" 1>&2 \
        || Error 93 "Cannot duplicate last daily backup"

    # Return current directory
    echo "${TARGET}/${DIR}/${CURRENT_DAY}"
}

Check_paths() { # Error 1x
    test -r "$AUTHFILE" || Error 10 "Authentication file cannot be read"
    test -d "$TARGET" || Error 11 "Target directory does not exist"
}

List_dbs() {
    echo "SHOW DATABASES;" | mysql --skip-column-names \
        | grep -E -v "information_schema|mysql|performance_schema"
}

Backup_system_dbs() { # Error 4x
    if [ ! -d "${TARGET}/db-system" ]; then
        mkdir "${TARGET}/db-system" || Error 40 "Failed to create 'db-system' directory in target"
    fi

    mysqldump --skip-lock-tables mysql > "${TARGET}/db-system/mysql-mysql.sql" \
        || Error 41 "MySQL system databases backup failed"
    mysqldump --skip-lock-tables information_schema > "${TARGET}/db-system/mysql-information_schema.sql" \
        || Error 42 "MySQL system databases backup failed"
    mysqldump --skip-lock-tables performance_schema > "${TARGET}/db-system/mysql-performance_schema.sql" \
        || Error 43 "MySQL system databases backup failed"
}

Check_db_schemas() { # Error 5x
    local DBS
    local DB
    local SCHEMA
    local TEMP_SCHEMA

    TEMP_SCHEMA="$(mktemp)"

    # `return` is not available within a pipe
    DBS="$(List_dbs)"

    if [ ! -d "${TARGET}/db" ]; then
        mkdir "${TARGET}/db" || Error 50 "Failed to create 'db' directory in target"
    fi
    while read -r DB; do
        if [ -n "$DB_EXCLUDE" ] && [[ "$DB" =~ ${DB_EXCLUDE} ]]; then
            continue
        fi

        SCHEMA="${TARGET}/db/db-${DB}.schema.sql"
        # Check schema
        mysqldump --no-data --skip-comments "$DB" \
            | sed 's/ AUTO_INCREMENT=[0-9]\+\b//' \
            > "$TEMP_SCHEMA" || Error 51 "Schema dump failure"

        if [ -r "$SCHEMA" ]; then
            if ! diff "$SCHEMA" "$TEMP_SCHEMA" 1>&2; then
                echo "Database schema CHANGED for ${DB}" 1>&2
            fi
            rm -f "$TEMP_SCHEMA"
        else
            mv "$TEMP_SCHEMA" "$SCHEMA" || Error 52 "New schema saving failed for '${DB}'"
            echo "New schema created for ${DB}"
        fi
    done <<< "$DBS"
}

Get_base_db_backup_dir() {
    local BACKUP_DIRS
    local XTRAINFO

    # shellcheck disable=SC2012
    BACKUP_DIRS="$(ls -tr "${TARGET}/innodb")"
    while read -r BASE; do
        XTRAINFO="${TARGET}/innodb/${BASE}/xtrabackup_info"
        # First non-incremental is the base
        if [ -r "$XTRAINFO" ] && grep -q -F -x "incremental = N" "$XTRAINFO"; then
            echo "$BASE"
            return 0
        fi
    done <<< "$BACKUP_DIRS"
    return 1
}

Backup_innodb() { # Error 6x
    local BASE
    local -i ULIMIT_FD
    local -i MYSQL_TABLES

    ULIMIT_FD="$(ulimit -n)"
    MYSQL_TABLES="$(find /var/lib/mysql/ -type f | wc -l)"
    MYSQL_TABLES+="10"
    if [ "$ULIMIT_FD" -lt "$MYSQL_TABLES" ]; then
        ulimit -n "$MYSQL_TABLES"
    fi
    if [ -d "${TARGET}/innodb" ]; then
        # Get base directory
        # @TODO Use last incremental as base?
        BASE="$(Get_base_db_backup_dir)"
        if [ -z "$BASE" ] || [ ! -d "${TARGET}/innodb/${BASE}" ]; then
            Error 60 "No base InnoDB backup"
        fi
        innobackupex --throttle=100 --incremental --incremental-basedir="${TARGET}/innodb/${BASE}" \
            "${TARGET}/innodb" \
            2>> "${TARGET}/innodb/backupex.log" || Error 61 "Incremental InnoDB backup failed"
    else
        # Create base backup
        echo "Creating base InnoDB backup"
        mkdir "${TARGET}/innodb"
        innobackupex --throttle=100 \
            "${TARGET}/innodb" \
            2>> "${TARGET}/innodb/backupex.log" || Error 62 "Base InnoDB backup failed"
    fi
    # Check OK message
    tail -n 1 "${TARGET}/innodb/backupex.log" | grep -q -F ' completed OK!' \
        || Error 63 "InnoDB backup operation not OK"
}

Backup_files() { # Error 7x
    local WEEKLY_ETC
    local WEEKLY_HOME
    local WEEKLY_MAIL
    local WEEKLY_USR
    declare -a HOME_EXCLUDE

    # /etc
    if [ ! -d "${TARGET}/etc" ]; then
        mkdir "${TARGET}/etc" || Error 70 "Failed to create 'etc' directory in target"
    fi
    WEEKLY_ETC="$(Rotate_weekly etc)"
    if [ -z "$WEEKLY_ETC" ] || [ ! -d "$WEEKLY_ETC" ]; then
        Error 71 "Failed to create weekly directory for 'etc'"
    fi
    tar --exclude=.git -cPf "${WEEKLY_ETC}/etc-backup.tar" /etc/
    # Save debconf data
    debconf-get-selections > "${WEEKLY_ETC}/debconf.selections"
    dpkg --get-selections > "${WEEKLY_ETC}/packages.selections"
    # Make directory tree immutable
    /usr/bin/s3qllock ${S3QL_OPT} "$WEEKLY_ETC"

    # /home
    if [ ! -d "${TARGET}/homes" ]; then
        mkdir "${TARGET}/homes" || Error 72 "Failed to create 'homes' directory in target"
    fi
    WEEKLY_HOME="$(Rotate_weekly homes)"
    #strace $(pgrep rsync|sed 's/^/-p /g') 2>&1|grep -F "open("
    if [ -z "$WEEKLY_HOME" ] || [ ! -d "$WEEKLY_HOME" ]; then
        Error 73 "Failed to create weekly directory for 'home'"
    fi
    # Exclude file
    if [ -r "$HOME_EXCLUDE_LIST" ]; then
        HOME_EXCLUDE=( "--exclude-from=${HOME_EXCLUDE_LIST}" )
    fi
    ionice rsync "${HOME_EXCLUDE[@]}" -a --delete --force /home/ "$WEEKLY_HOME"
    # Make directory tree immutable
    /usr/bin/s3qllock ${S3QL_OPT} "$WEEKLY_HOME"

    # /var/mail
    if [ ! -d "${TARGET}/email" ]; then
        mkdir "${TARGET}/email" || Error 74 "Failed to create 'email' directory in target"
    fi
    WEEKLY_MAIL="$(Rotate_weekly email)"
    if [ -z "$WEEKLY_MAIL" ] || [ ! -d "$WEEKLY_MAIL" ]; then
        Error 75 "Failed to create weekly directory for 'mail'"
    fi
    ionice rsync -a --delete --force /var/mail/ "$WEEKLY_MAIL"
    # Make directory tree immutable
    /usr/bin/s3qllock ${S3QL_OPT} "$WEEKLY_MAIL"

    # /usr/local
    if [ ! -d "${TARGET}/usr" ]; then
        mkdir "${TARGET}/usr" || Error 76 "Failed to create 'usr' directory in target"
    fi
    WEEKLY_USR="$(Rotate_weekly usr)"
    if [ -z "$WEEKLY_USR" ] || [ ! -d "$WEEKLY_USR" ]; then
        Error 77 "Failed to create weekly directory for 'usr'"
    fi
    ionice rsync --exclude="/src/" -a --delete --force /usr/local/ "$WEEKLY_USR"
    # Make directory tree immutable
    /usr/bin/s3qllock ${S3QL_OPT} "$WEEKLY_USR"
}

Mount() { # Error 2x
    test -z "$(find "$TARGET" -mindepth 1 -maxdepth 1)" || Error 20 "Target directory is not empty"

    # "If the file system is marked clean and not due for periodic checking, fsck.s3ql will not do anything."
    /usr/bin/fsck.s3ql ${S3QL_OPT} "$STORAGE_URL" 1>&2 || test $? == 128

    nice /usr/bin/mount.s3ql ${S3QL_OPT} ${MOUNT_OPTIONS} \
        "$STORAGE_URL" "$TARGET" || Error 21 "Cannot mount storage"

    /usr/bin/s3qlstat ${S3QL_OPT} "$TARGET" &> /dev/null || Error 22 "Cannot stat storage"
}

Umount() { # Error 3x
    /usr/bin/s3qlctrl ${S3QL_OPT} flushcache "$TARGET" || Error 30 "Flush failed"
    /usr/bin/umount.s3ql ${S3QL_OPT} "$TARGET" || Error 31 "Umount failed"
}

declare -i CURRENT_DAY

set -e

trap 'Onexit "$?" "$BASH_COMMAND"' EXIT HUP INT QUIT PIPE TERM

CURRENT_DAY="$(date --utc "+%w")"

# On terminal?
if [ -t 1 ]; then
    read -r -s -e -p "Start backup? "
    echo
    S3QL_OPT=""
else
    S3QL_OPT="--quiet"
fi

# Read configuration
test -r "$CONFIG" || Error 100 "Unconfigured"
# shellcheck disable=SC1090
source "$CONFIG"

logger -t "system-backup" "Started. $*"

Check_paths

if [ "$1" == "-u" ]; then
    Umount
    exit 0
fi

Mount

if [ "$1" == "-m" ]; then
    echo "cd ${TARGET}/"
    exit 0
fi

Backup_system_dbs

Check_db_schemas

Backup_innodb

Backup_files

Umount

# Log file: /root/.s3ql/mount.log
logger -t "system-backup" "Finished. $*"

if [ -n "$HCHK_UUID" ]; then
    wget -q -t 3 -O- "https://hchk.io/${HCHK_UUID}" | grep -q -F -x "OK" || Error 101 "hchk.io non-OK response"
fi

exit 0
