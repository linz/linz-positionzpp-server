use strict;

=head1 LINZ::PNZPP::PnzServer

This module creates the PnzServer object, which is run to process any
outstanding PositioNZ-PP jobs.  

Several servers may be run, each identified by an ID.

The server carries out the following main steps when it is run


1) Checks that this server is not already running, and if so stops
2) Creates its own copy of the server Bernese environment
3) Runs each outstanding job in turn

It uses three status files to manage its state and prevent conflicts

1) A lock file.  This is created when it starts and destroyed when it
   finishes.  This prevents other servers with the same id from starting

2) A running status file.  This is deleted on completion, but provides
   information on the current status of the server

3) A last started file, which records the last attempt to start the
   server if it failed to start.

It also watches for the presence of a stop file which if created and 
current will cause it to stop after finishing the current job and will
block it from restarting.

=cut

package LINZ::PNZPP::PnzServer;

use LINZ::PNZPP::PnzJob;
use LINZ::GNSS::Time qw/seconds_datetime/;
use LINZ::BERN::BernUtil;
use File::Path qw/make_path remove_tree/;
use File::Copy;
use File::Copy::Recursive qw/dircopy/;

use Log::Log4perl;
use Carp;


our $LockDir;
our $StatusDir;
our $TemplateDir;
our $BernDataDir;
our $BernUserDir;

our $LockFile='pnzserver-[serverid].lock';
our $RunFile='pnzserver-[serverid].run';
our $LastRunFile='pnzserver-[serverid].lastrun';
our $RunStartFile='pnzserver-[serverid].start';
our $StopFile='pnzserver.stop';

our $LockTimeout=3600;
our $LockTimeoutMin=60;

# Unpacking should be quick - so if an unpacking file is hanging around more
# than $UnpackRetryTime try again.  

our $UnpackRetryTime=300;

sub _Logger
{
    my $logger=Log::Log4perl->get_logger('LINZ.PNZPP.PnzServer');
    return $logger;
}

=head2 LINZ::PNZPP::PnzServer::LoadConfig

Loads the PostioNZ-PP configuration information

=cut

sub LoadConfig
{
    my($conf) = @_;

    # Mandatory information

    $StatusDir=$conf->filename("ServerStatusDir") || croak("Configuration does not define ServerStatusDir\n");
    $LockDir=$conf->filename("ServerLockDir") || croak("Configuration does not define ServerLockDir\n");
    $TemplateDir=$conf->filename("BernUserTemplate") || croak("Configuration does not define BernUserTemplate\n");
    $BernDataDir=$conf->filename("BernDataDir") || croak("Configuration does not define BernDataDir\n");
    $BernUserDir=$conf->filename("BernUserDir") || croak("Configuration does not define BernUserDir\n");

    $LockFile=$conf->get("ServerLockFile",$LockFile);
    $RunFile=$conf->get("ServerRunFile",$RunFile);
    $LastRunFile=$conf->get("ServerLastRunFile",$LastRunFile);
    $RunStartFile=$conf->get("ServerRunStartFile",$RunStartFile);
    $StopFile=$conf->get("ServerStopFile",$StopFile);
    $LockTimeout=$conf->get("LockTimeout",$LockTimeout)+0;
    $LockTimeout=$LockTimeoutMin if $LockTimeout < $LockTimeoutMin;
}

=head2 $status=LINZ::PNZPP::PNZServer::Status()

Returns the status of server(s). Collect information from the various server status files
and returns the list of server start info, running server info, and recent server run info.

Returns a hash with elements:

=over

=item starts

One line information from the last time the server was initiated

=item running

Status information from currently running servers

=item recent

Status information from recently finished servers (the last status information 
from each server.

=back

Each list is a hash with keys id, the server id, and info, the text of the message.

=cut

sub Status
{
    my( $startre, $runre, $lastre, $lockre ) = 
        map { my $x=quotemeta($_); $x=~ s/\\\[serverid\\\]/(\\w+)/; '^'.$x.'$' } 
        ($RunStartFile,$RunFile,$LastRunFile,$LockFile);
    my @lockdata=();
    my @startdata=();
    my @rundata=();
    my @lastdata=();
    foreach my $testdir ($StatusDir,$LockDir)
    {
        if( opendir(my $dh,$testdir) )
        {
            foreach my $f (readdir($dh))
            {
                my $list;
                my $id;
                if( $testdir eq $StatusDir )
                {
                    if( $f =~ /$startre/ ) { $list=\@startdata; $id=$1; }
                    elsif( $f =~ /$runre/ ) { $list=\@rundata; $id=$1; }
                    elsif( $f =~ /$lastre/ ) { $list=\@lastdata; $id=$1; }
                }
                elsif(  $testdir eq $LockDir )
                {
                    if( $f =~ /$lockre/ ) { $list=\@lockdata; $id=$1; }
                }
                next if ! $list;
                my $file="$testdir/$f";
                if( open(my $fh,"<$file"))
                {
                    my $info = join('',<$fh>);
                    close($fh);
                    push(@$list,{id=>$id,info=>$info});
                }
            }
            close($dh);
        }
    }
    return { starts=>\@startdata, running=>\@rundata, recent=>\@lastdata, locks=>\@lockdata };
}

=head2 $text=LINZ::PNZPP::PnzServer::StatusString()

Returns the server status information from Status() as a text string

=cut

sub StatusString
{
    my $statusdata=Status();
    my $separator="="x70;
    my $separator2="-"x70;
    my $text="PositioNZ-PP server status information\n\n";

    $text.= "\n$separator\n\nCurrent server locks\n\n";
    my $locks=$statusdata->{locks};
    my $sep='';
    foreach my $s (sort {$a->{id} cmp $b->{id}} @$locks)
    {
        $text .= "    ".$s->{id}.": ".$s->{info};
    }

    $text .= "Recent server start information\n";
    my $starts=$statusdata->{starts};
    foreach my $s (sort {$a->{id} cmp $b->{id}} @$starts)
    {
        $text .= '    '.$s->{info};
    }

    $text.= "\n$separator\n\nCurrently running server status\n\n";
    my $running=$statusdata->{running};
    my $sep='';
    foreach my $s (sort {$a->{id} cmp $b->{id}} @$running)
    {
        $text .= $sep.$s->{info}."\n";
        $sep="\n$separator2\n\n";
    }

    $text.= "\n$separator\n\nStatus from last run of server\n\n";
    my $recent=$statusdata->{recent};
    $sep='';
    foreach my $s (sort {$a->{id} cmp $b->{id}} @$recent)
    {
        $text .= $sep.$s->{info}."\n";
        $sep="\n$separator2\n\n";
    }
    $text .= "\n";
    return $text;
}


=head2 $server=LINZ::PNZPP::PnzServer::Pause($pausetime,$waittime)

Pauses the servers.  This creates a "stop file" that the servers periodically check
for.  If it exists and is current (mtime is future dated) then they exit.  This 
creates the stop file, then waits the specified time, checking periodically to see
whether there are any jobs still running.  Returns either when all jobs have stopped
or when $waittime expires.  At that time it resets the stop file to ensure that it
continues for at least $pausetime.

Parameters:

=over

=item $pausetime The time to pause the processors for.

=item $waittime The time to wait for processors to finish.

=back

Returns 1 if the processors are stopped, or 0 if the wait time expires.

If the wait time is 0 then the stop file is created and the script returns 1.

If the pause time is 0 then the script just waits for all processes to to stop.

If both are 0 then the stop file is deleted if it exists.

=cut

# Checks if any servers are currently running
sub _running
{
    my $lockre=$LockFile;
    $lockre = quotemeta($lockre);
    $lockre =~ s/\\\[serverid\\\]/(\\w+)/; 
    $lockre = '^'.$lockre.'$';
    my $running = 0;
    if( opendir(my $dir, $LockDir))
    {
        foreach my $f (readdir($dir))
        {
            $running++ if $f =~ $lockre;
        }
        closedir($dir);
    }
    return $running;
}

sub Pause
{
    my($pause,$wait)=@_;
    $pause += 0;
    $wait += 0;

    my $stopfile = "$StatusDir/$StopFile";

    if( $pause == 0 && $wait == 0 )
    {
        unlink($stopfile);
    }


    return 0 if $pause == 0 && $wait == 0;
    open(my $lf,">$stopfile") || croak("Cannot create stop file $stopfile\n");
    close($lf);

    my $sleep=10;
    my $now=time();
    my $end=$now+$wait;
    my $mtime=$now+$pause+$wait+$sleep*2;
    utime $mtime,$mtime,$stopfile;

    if( $wait )
    {
        while( _running() && (time() < $end) ) { sleep($sleep); }
    }
    if($pause) 
    {
        $mtime=time()+$pause;
        utime $mtime, $mtime, $stopfile;
    }
    else
    {
        unlink($stopfile);
    }
    return _running() ? 0 : 1;
}

=head2 $server=LINZ::PNZPP::PnzServer->new(id)

Creates a server object.  This just creates the objects with its settings. It does
not run the server. Once it is created use $server->run() to process outstanding jobs.

=cut

sub new
{
    my($class,$id)=@_;
    croak("Invalid serverid \"$id\" - must be 1-10 alpha chars\n") if $id !~ /^\w{1,10}$/;
    my $lockfile=$LockFile;
    my $runfile=$RunFile;
    my $runstartfile=$RunStartFile;
    my $lastrunfile=$LastRunFile;
    my $berndatadir=$BernDataDir;
    my $bernuserdir=$BernUserDir;

    foreach my $fn ($lockfile,$runfile,$lastrunfile,$runstartfile,$bernuserdir)
    {
        $fn =~ s/\[serverid\]/$id/eg || croak("Server variable \"$fn\" must include [serverid]\n");
    }

    make_path($StatusDir) if ! -d $StatusDir;
    croak("Server status directory $StatusDir doesn't exist\n") if ! -d $StatusDir;
    make_path($LockDir) if ! -d $LockDir;
    croak("Server lock directory $StatusDir doesn't exist\n") if ! -d $LockDir;
    
    return bless {
        id=>$id,
        lockfile=>"$LockDir/$lockfile",
        havelock=>0,
        runfile=>"$StatusDir/$runfile",
        runstartfile=>"$StatusDir/$runstartfile",
        lastrunfile=>"$StatusDir/$lastrunfile",
        stopfile=>"$StatusDir/$StopFile",
        berndatadir=>$berndatadir,
        bernuserdir=>$bernuserdir,
        bernclientenv=>0,
        logger=>_Logger(),
        }, $class;
}

sub DESTROY
{
    my($self)=@_;
    $self->unlock();
}

sub logger 
{
    my($self)=@_;
    return $self->{logger};
}

=head2 $ok=$server->canRun()

Tests whether a stop file has been set which prevents the server from
running.  Stop files are created with a future mtime.  They expire when that
is passed.

=cut

sub canRun
{
    my($self)=@_;
    my $stopfile=$self->{stopfile};
    return 0 if -e $stopfile && -M $stopfile < 0.0;
    return 1;
}

=head2 $locked=$server->lock()

Attempts to acquire a server lock, and returns false if it fails

=cut

sub lock
{
    my($self)=@_;
    my $now=seconds_datetime(time(),1);
    my $pid=$$;
    my $id=$self->{id};
    my $lockfile=$self->{lockfile};
    my $stopfile=$self->{stopfile};
    my $runstartfile=$self->{runstartfile};
    my $timeoutdays=$LockTimeout/(60*60*24.0);
    my $lastrunmsg="";
    my $locked=0;
    if( ! $self->canRun() )
    {
        $lastrunmsg="Not started as stop file present";
    }
    elsif( -e $lockfile && -M $lockfile < $timeoutdays )
    {
        my $lockinfo='';
        if( open(my $lf,"<$lockfile") )
        {
            my $lockdata=<$lf>;
            close($lf);
            $lockinfo.=" $1" 
                if $lockdata=~/\:\s+(\d\d\d\d\-\d\d\-\d\d\s\d\d\:\d\d\:\d\d)\s*\:/;
            $lockinfo.=" PID $1" if $lockdata=~ /\:\s+PID\s+(\w+)/
        }
        $lockinfo =~ s/^\s+/ (/;
        $lockinfo .= ')' if $lockinfo;
        $lastrunmsg="Server already running - lock file present$lockinfo";
    }
    else
    {
        my $lockdata="PnzServer lock for server $id: $now: PID $pid\n";
        if( open(my $lf,">$lockfile"))
        {
            print $lf $lockdata;
            close $lf;

            # Confirm that we really did get the lock
            $lastrunmsg="Lock file corrupted";
            if( open($lf,"<$lockfile") )
            {
                my $check=<$lf>;
                close($lf);
                if( $check eq $lockdata )
                {
                    $lastrunmsg="Server started with PID $pid";
                    $locked=1;
                    $self->writeStatus("Server started with PID $pid",1);
                }
            }
        }
        else
        {
            $lastrunmsg="Failed to create lock file\n";
        }
    }
    if( open(my $lrf,">$runstartfile") )
    {
        print $lrf "Server $id: $now: $lastrunmsg\n";
        close($lrf);
    }
    $self->{havelock} = $locked;
    return $locked;
}

=head2 $server->unlock()

Release the lock file held by the server.

=cut

sub unlock
{
    my($self)=@_;
    if( $self->{havelock} )
    {
        $self->writeStatus("Server finished");
        rename($self->{runfile},$self->{lastrunfile});
        unlink($self->{lockfile});
        $self->{havelock}=0;
    }
}

=head2 $server->writeStatus($message,$start)

Write a message to the server run status file.  

=cut

sub writeStatus
{
    my($self,$message,$start)=@_;
    $message=~ s/\s*$//;
    my $mode=$start ? ">" : ">>";
    my $now = seconds_datetime(time(),1);
    my $id = $self->{id};
    if( open(my $sf, $mode.$self->{runfile}) )
    {
        print $sf "Server $id run status\n" if $start;
        print $sf "$now: $message\n";
        close($sf);
    }
}

=head2 $envdata=$server->berneseClientEnv( $rebuild )

Create the bernese client environment if it is not already built, and returns
a hash containing the following elements:

=over

=item CLIENT_ENV

The file containing the Bernese client environment settings

=item CPU_FILE

The name of the CPU file that should be used

=back

The optional parameter $rebuild will cause the environment to be deleted
and recreated.

=cut

sub berneseClientEnv
{
    my ($self,$rebuild)=@_;
    return $self->{bernclientenv} if $self->{bernclientenv} && ! $rebuild;

    # If there is a environment already there, then get rid of it so we know
    # we have a correct current environment
    $self->deleteBerneseClientEnv();

    my $bernuserdir=$self->{bernuserdir};
    my $berndatadir=$self->{berndatadir};

    #  Create the user and data environments if they don't already exist
    make_path($bernuserdir);
    make_path($berndatadir) if ! -d $berndatadir;

    my $bernenv=LINZ::BERN::BernUtil::SetBerneseEnv('',
        U=>$bernuserdir,
        P=>$berndatadir
    );

    -d $TemplateDir || croak("Bern user template $TemplateDir not defined\n");
    dircopy($TemplateDir,$bernuserdir);
    -f "$bernuserdir/settings" 
        || croak("Bern user template $TemplateDir doesn't include \"settings\" file\n");

    my $env=
    {
        CLIENT_ENV=>"$bernuserdir/PNZPP.setvar",
        CPU_FILE=>"PNZPP",
        PCF_FILE=>"RUN_PNZ",
    };

    # Process the settings file

    open( my $sf, "<$bernuserdir/settings") || croak("Cannot open $bernuserdir/settings file\n");
    while(my $line=<$sf>)
    {
        next if $line =~ /^\s*(#|$)/;
        $line =~ s/\s*$//;
        my ($key,@values)=split(' ',$line);
        foreach my $v (@values)
        {
            $v =~ s/\$\{(\w+)\}/$ENV{$1}/eg;
        }
        if( $key =~ /^(CLIENT_ENV|CPU_FILE|PCF_FILE)$/ && @values == 1)
        {
            $env->{$key}=$values[0];
        }
        elsif( $key eq 'makedir' && @values == 1 )
        {
            make_path($values[0]);
        }
        elsif( $key eq 'symlink' && @values == 2 )
        {
            croak("Bernese environment symlink target $values[0] doesn't exist\n")
               if ! -e $values[0];
            symlink($values[0],$values[1]) ||
               croak("Cannot create symbolic link from $values[0] to $values[1]\n");
        }
        else
        {
            croak("Invalid setting in $TemplateDir/settings: $line\n");
        }
    }

    # Check the CPU file exists
    
    my $cpufile=$env->{CPU_FILE};
    croak("CPU file $cpufile is missing\n")
       if ! -f "$bernuserdir/PAN/$cpufile.CPU";

    # Create the settings file

    my $settingsfile=$env->{CLIENT_ENV};
    open(my $svf,">$settingsfile") 
        || croak("Cannot create Bernese environment file $settingsfile\n");
    print $svf "# PositioNZ-PP Bernese client settings\n";
    foreach my $key (sort keys %$bernenv)
    {
        printf $svf "export %s=\"%s\"\n",$key,$bernenv->{$key};
    }
    close($svf);

    $self->{bernclientenv}=$env;
    return $env;
}

=head2 $server->deleteBerneseClientEnv

Remove a client environment if it has been defined

=cut


sub deleteBerneseClientEnv
{
    my ($self)=@_;
    my $bernuserdir=$self->{bernuserdir};
    remove_tree($bernuserdir) if -d $bernuserdir;
    $self->{bernclientenv}=0;
}

    
=head2 $server->loadNewJobs()

Checks for new input files in the interface directory shared with the front end.  Any files found are
used to create new PnzJob jobs, and then either deleted or archived for future reference.

=cut 

sub loadNewJobs
{
    my($self)=@_;
    return if ! $self->{havelock};

    my $inputdir=$LINZ::PNZPP::PnzJob::InputDir;

    my $ifre=$LINZ::PNZPP::PnzJob::InputJobFile;
    
    $ifre=~ s/\[jobid\]/(\\w+)/;
    $ifre='^('.$ifre.')(?:\.\w+\.(\d+))?$';

    opendir(my $dir,$inputdir) || croak("Cannot open interface directory $inputdir");
    my @jobfiles=();
    foreach my $ipf (readdir($dir))
    {
        push(@jobfiles,$ipf) if $ipf =~ /$ifre/;
    }
    closedir($dir);

    foreach my $ipf (@jobfiles)
    {
        $ipf =~ /$ifre/;
        my $ipfn = $1;
        my $jobid = $2;
        my $lasttry=$3;
        # Checking for a previous attempt to unpack that didn't finish

        next if $lasttry && time()-$lasttry < $UnpackRetryTime;
        my $inputfile="$inputdir/$ipf";
        next if ! -f $inputfile;
        eval
        {
            if( $lasttry )
            {
                $self->logger->warn("Retry unpacking $ipfn");
                $self->writeStatus("Retrying unpacking $ipfn");
            }
        
            $self->writeStatus("Creating job $jobid");
            $self->logger()->info("Creating job $jobid");

            my $suffix='.'.$self->{id}.'.'.time();

            # First rename the file with a suffix.  This claims ownership of it
            # - other processes won't grab it for at least $UnpackRetryTime

            my $movefile="$inputdir/$ipfn$suffix";
            rename($inputfile,$movefile);
            if( ! -f $movefile )
            {
                $self->logger->warn("Cannot claim file - taken by another server?");
                $self->writeStatus("Cannot claim file - taken by another server?");
            }
            next if ! -f $movefile;
            my $inputfile=$movefile;

            my $job=LINZ::PNZPP::PnzJob->new($self,$inputfile,$jobid,$lasttry);
            $job->save();
            $self->archiveInputFile($inputfile,$ipfn);
            unlink($inputfile);
        };
        if( $@ )
        {
            my $errmsg=$@;
            $self->writeStatus("Error: $errmsg");
            $self->logger()->error($errmsg);
        }
        if( $lasttry && -f $inputfile )
        {
            $self->logger()->error("Giving up on job $ipfn after second try at unpacking");
            $self->writeStatus("Error: Failed to unpack $ipfn on second try - deleting");
            $self->archiveInputFile($inputfile,$ipfn);
            unlink($inputfile);
        }
    }
}

=head2 $server->archiveInputFile($inputfile,$origfilename)

Based on the settings for archiving, saves the input file in the job archive

=cut

sub archiveInputFile
{
    my ($self,$inputfile,$origname) = @_;
    my $archivedir=$LINZ::PNZPP::PnzJob::ArchiveInputDir;
    if( $archivedir )
    {
        if( ! -d $archivedir )
        {
            my $error=[];
            make_path($archivedir,{error=>\$error});
            if( @$error )
            {
                $self->logger()->error("Failed to create archive directory $archivedir\n".
                    join("\n",@$error)."\n");
            }
        }
        if( -d $archivedir )
        {
            my $archfile=$archivedir.'/'.$origname;
            if( move($inputfile,$archfile) )
            {
                my $now=time();
                utime $now, $now, $archfile;
            }
            else
            {
                $self->logger()->error("Failed to archive input job to $archfile\n");
            }
        }
    }
}


=head2 $server->processJobs();

Reloads and updates every job currently defined.  The update is applied using the PnzJob::update
function.

=cut

sub processJobs
{
    my($self)=@_;
    return if ! $self->{havelock};

    my $workdir=$LINZ::PNZPP::PnzJob::WorkDir;
    my $statusfile=$LINZ::PNZPP::PnzJob::StatusFile;

    opendir(my $dir,$workdir) || croak("Cannot open interface directory $workdir");
    my @jobdirs=();
    foreach my $jbf (readdir($dir))
    {
        next if $jbf !~ /^\w+$/;
        my $jobdir="$workdir/$jbf";
        next if ! -d $jobdir;
        next if ! -e "$jobdir/$statusfile";
        push(@jobdirs,$jobdir);
    }
    closedir($dir);

    foreach my $jobdir (@jobdirs)
    {
        eval
        {
            my $job=LINZ::PNZPP::PnzJob->reload($self,$jobdir);
            my $jobid=$job->{id};
            $self->writeStatus("Processing job $jobid");
            $job->update();
            $self->writeStatus("Finished job $jobid");
        };
        if( $@ )
        {
            my $errmsg=$@;
            $self->writeStatus("Error: $errmsg");
            $self->logger()->error($errmsg);
        }
    }
}

=head2 $server->run();

Run the server

=cut

sub run
{
    my ($self)=@_;
    if( $self->lock())
    {
        $self->loadNewJobs();
        $self->processJobs();
        $self->unlock();
    }
}

1;
