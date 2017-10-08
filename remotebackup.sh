#!/bin/bash

# -- remotebackup.sh - rsync rotating rollback and/or incremental backup
#
#    by btd@apario.net 
#    2002 - 2017 (c) apario
#
#    Bash script that uses rsync to create full remote server backup with
#    rollbaks. Features:
#
#    * 14 days and 10 steps (minimum) rollback of all deleted/changed files
#    * unlimited/incremental rollback of selected deleted/changed files/paths
#    * basic exclude and include control by config files on the server being backed up
#    * backup report stored in the server being backed up
#    * rsync on non-standard ssh port, if need be

# -- things you may want to change
#
#    BACKUPROOT is the base target path where your bakcups go
#      the system will make one folder pr server in this directory
#    LOCALEXCLUDELISTFILE is path on local computer to the common exclude list 
#      file. This is a required file and it is strongly suggested that it 
#      includes entries such as lost+found, /proc, /dev, and /sys
#      file should be in rsync exclude format
#    REMOTEEXCLUDELISTFILE is path on the remote server to that servers
#      exclude list file. If this file is not present, backup will not 
#      start, making it a remote control file for wheter backup is active.
#      file should be in rsync exclude format. it can be emtpy
#    REMOTEINCREMENTALLISTFILE is path on the remote server to that servers
#      incremental list file. If this file is present, paths listed in it 
#      (rsync exclude format) will be backed up into incremental rollback dir, 
#      which is kept. This is good for files that should not change too much, 
#      such as archives, documents etc
#    REMOTEBACKUPREPORTFILE is path on the remote server where backup report 
#      for the backup run is stored
#    BWLIMIT is the bandwith limiting parameter sent to rsync, in KBytes

BACKUPROOT="/backup/auto" 
LOCALEXCLUDELISTFILE="/etc/backupexcludelist"
REMOTEEXCLUDELISTFILE="/root/.backup/excludelist"
REMOTEINCREMENTALLISTFILE="/root/.backup/incrementallist"
REMOTEBACKUPREPORTFILE="/root/.backup/backupreport.txt"
BWLIMIT=3000


# -- things you should leave alone, but maybe you want to tweak
#
#    CURRENTBACKUPDIR contains the up-to-date backup of all files 
#    LIMITEDROLLBACKDIR contains rollback kept for 14 days (minimum 10 entries)
#    UNLIMITEDROLLBACKDIR contains rollback kept forever (from incremental list)
#    NOW is used for directories and paths
#    RUNSTART is used for backup report, there is a RUNDEND somewhere in the code
#    CONFIGTEMPPATH is where the system stores temp config files, reports etc
#    LOCKFILEPATH is where to store lock files
#    SSHPORT is the ssh port used by rsync and scp, can be overridden as param 2

CURRENTBACKUPDIR=$BACKUPROOT/$1/current
LIMITEDROLLBACKDIR=$BACKUPROOT/$1/rollback-limited
UNLIMITEDROLLBACKDIR=$BACKUPROOT/$1/rollback-unlimited
NOW=`/bin/date +%Y-%m-%d_%H:%M:%S`
RUNSTART=`/bin/date +%Y-%m-%d\ %H:%M:%S`
CONFIGTEMPPATH=/tmp
LOCKFILEPATH=/var/run/backup
if [ $2 ] ; then SSHPORT=$2 ; else SSHPORT=22 ; fi


# -- basic sanity checks 

if [ ! $1 ] ; then /bin/echo "usage: $0 hostname <port>" >&2 ; exit 1 ; fi
if [ ! -d $BACKUPROOT ] ; then /bin/echo "base target path ($BACKUPROOT) is not a directory" >&2 ; exit 1 ; fi
if [ ! -f $LOCALEXCLUDELISTFILE ] ; then /bin/echo "local exclude list file ($LOCALEXCLUDELISTFILE) does not exist" >&2 ; exit 1 ; fi


# -- start execution

/bin/echo ""
/bin/echo "starting backup proccess for $1... stand by..."
/bin/echo ""


# -- fetch remote excludelist from server

/bin/echo "deleting servers exclude list and fetching new from server"
if [ -f $CONFIGTEMPPATH/$1.backupexcludelist ] ; then 
  /bin/rm $CONFIGTEMPPATH/$1.backupexcludelist
fi
/usr/bin/scp -P $SSHPORT $1:$REMOTEEXCLUDELISTFILE $CONFIGTEMPPATH/$1.backupexcludelist > /dev/null 2>&1
if [ -f $CONFIGTEMPPATH/$1.backupexcludelist ] ; then 
  /bin/echo "fetched remote excludelist file"
else
  /bin/echo "could not fetch remote excludelist file $REMOTEEXCLUDELISTFILE for $1, aborting" >&2
  exit 1
fi


# -- fetch remote incremental list from server

/bin/echo "deleting servers incremental list and fetching new from server"
if [ -f $CONFIGTEMPPATH/$1.incrementallist ] ; then 
  /bin/rm $CONFIGTEMPPATH/$1.incrementallist
fi
/usr/bin/scp -P $SSHPORT $1:$REMOTEINCREMENTALLISTFILE $CONFIGTEMPPATH/$1.incrementallist > /dev/null 2>&1
if [ -f $CONFIGTEMPPATH/$1.incrementallist ] ; then 
  /bin/echo "fetched remote excludelist file"
else
  /bin/echo "no remote incremental file $REMOTEINCREMENTALLISTFILE for $1"
fi


# -- checking for lock file
#    a lock file present would indicate a currently running backup

if [ ! -f "$LOCKFILEPATH/$1.pid" ] ; then
  /bin/echo -n "lock file does not exist, creating..."
  /bin/mkdir -p $LOCKFILEPATH
  /bin/touch "$LOCKFILEPATH/$1.pid"
  /bin/echo "done"
else
  /bin/echo "lock file $LOCKFILEPATH/$1.pid present... aborting" >&2
  exit 0
fi


# -- create required directories 

/bin/mkdir -p "$CURRENTBACKUPDIR"
/bin/mkdir -p "$LIMITEDROLLBACKDIR/$NOW"
if [ -f $CONFIGTEMPPATH/$1.incrementallist ] ; then 
	/bin/mkdir -p "$UNLIMITEDROLLBACKDIR/$NOW"
fi


# -- delete old rotating backup rollbacks
#    loop through rollback basedir and make a list of all content sorted descending by mtime
#    ignore (keep) the newest 10 entries, regardless of age
#    delete everything else that is older than 14 days
#
#    make a list of all the files, add date to beginning of file name line and add to array
#    sort file list alphabetically and return file names without date part in an array
#    loop thru file list array (starting at 11th element) find how many seconds into the past its date is
#    if the date is more than 14 days seconds ago, delete it

if [ ! -d $LIMITEDROLLBACKDIR ] ; then
  /bin/echo "rotating rollback dir ($LIMITEDROLLBACKDIR) is not a directory" >&2
  exit 1
fi

cd $LIMITEDROLLBACKDIR > /dev/null
sortstepfirst=(); for foo in * ; do sortstepfirst+=("$(/usr/bin/stat --printf "%y %n" -- "$foo")"); done; 
sortstepsecond=(); while read -d $'\0' bar; do sortstepsecond+=("${bar:36}"); done < <(printf '%s\0' "${sortstepfirst[@]}" | /usr/bin/sort -r -z)
for baz in "${sortstepsecond[@]:0:10}"; do
  /bin/echo "$baz is recent, leaving it be"
done
for baz in "${sortstepsecond[@]:10}"; do
  if [ $(($(/bin/date +%s) - $(/bin/date +%s -r "$baz"))) -gt 1209600 ]; then
    /bin/echo "$baz is more than 14 days old, deleting"
    if [ -d "$LIMITEDROLLBACKDIR/$baz" ] ; then rm -Rf "$LIMITEDROLLBACKDIR/$baz" ; fi
  else 
    /bin/echo "$baz is less than 14 days old, leaving it be"
  fi
done
/bin/echo ""
cd - > /dev/null


# -- do backup
#
#    If no remote incremental list exists, do a simple backup run. else, 
#    first do an rsync run excluding all exclude files and incremental file
#    with no --delete-excluded by rsync, and rotating rollback backup dir.
#    Then run again, now not excluding incremental file, with --delete-excluded,
#    and incremental rollback backup dir. Then sync any non-incremental files
#    form unlimited dir to limited dir (some might have changed between the 
#    runs), deleting them on the sender side. Then clean up empty dirs.

/bin/echo "making total backup of $1... stand by..."
/bin/echo ""

if [ ! -f $CONFIGTEMPPATH/$1.incrementallist ] ; then 
	/usr/bin/rsync -e "ssh -p $SSHPORT" --bwlimit=$BWLIMIT -aP --sparse --exclude-from=$LOCALEXCLUDELISTFILE --exclude-from=$CONFIGTEMPPATH/$1.backupexcludelist --delete --delete-excluded --backup --backup-dir $LIMITEDROLLBACKDIR/$NOW $1:/* $CURRENTBACKUPDIR
else
	/usr/bin/rsync -e "ssh -p $SSHPORT" --bwlimit=$BWLIMIT -aP --sparse --exclude-from=$LOCALEXCLUDELISTFILE --exclude-from=$CONFIGTEMPPATH/$1.backupexcludelist --exclude-from=$CONFIGTEMPPATH/$1.incrementallist --delete --backup --backup-dir $LIMITEDROLLBACKDIR/$NOW $1:/* $CURRENTBACKUPDIR
	/usr/bin/rsync -e "ssh -p $SSHPORT" --bwlimit=$BWLIMIT -aP --sparse --exclude-from=$LOCALEXCLUDELISTFILE --exclude-from=$CONFIGTEMPPATH/$1.backupexcludelist --delete --delete-excluded --backup --backup-dir $UNLIMITEDROLLBACKDIR/$NOW $1:/* $CURRENTBACKUPDIR
	/usr/bin/rsync -aPvv --sparse --remove-source-files --exclude-from=$CONFIGTEMPPATH/$1.incrementallist $UNLIMITEDROLLBACKDIR/$NOW/* $LIMITEDROLLBACKDIR/$NOW/
	/bin/echo "cleaning up empty dirs"
	/usr/bin/find $UNLIMITEDROLLBACKDIR/$NOW -type d -empty -delete
	/usr/bin/find $LIMITEDROLLBACKDIR/$NOW -type d -empty -delete
fi
/bin/echo ""
RUNEND=`/bin/date +%Y-%m-%d\ %H:%M:%S`


# -- create backup status log
#
#    create backup status log file and upload it to remote server

/bin/echo -n "creating status log and sending to server..."
cd $BACKUPROOT/$1
/bin/echo "server: $1" > $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "run start: $RUNSTART" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "      end: $RUNEND" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "excludes:" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/cat $LOCALEXCLUDELISTFILE >> $CONFIGTEMPPATH/$1.backupstatus.txt
if [ -f $CONFIGTEMPPATH/$1.backupexcludelist ] ; then 
  /bin/cat $CONFIGTEMPPATH/$1.backupexcludelist >> $CONFIGTEMPPATH/$1.backupstatus.txt
fi
/bin/echo "" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "post-rsync file status:" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "" >> $CONFIGTEMPPATH/$1.backupstatus.txt
/usr/bin/tree -afD >> $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/chmod 600 $CONFIGTEMPPATH/$1.backupstatus.txt 
cd - > /dev/null
/usr/bin/scp -P $SSHPORT $CONFIGTEMPPATH/$1.backupstatus.txt $1:$REMOTEBACKUPREPORTFILE > /dev/null 2>&1
rm $CONFIGTEMPPATH/$1.backupstatus.txt
/bin/echo "done"


# -- end execution

/bin/rm $LOCKFILEPATH/$1.pid

/bin/echo ""
/bin/echo "..backup complete"
/bin/echo ""

exit 0
