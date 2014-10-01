use strict;

=head1 LINZ::PNZPP::PnzJob

This module manages PositioNZ-PP jobs.  Each job may consist of a number of RINEX files,
which are processed in individual Bernese processing jobs (using LINZ::PNZPP::BernJob).

This module manages compiling the data supplied by a user into a structure for procssing, persisting the job between runs of the PositioNZ-PP server (for example while
waiting for reference data), compiling the results to send back to the user, and 
archiving the job.

See also:

=over

=item LINZ::PNZPP::PnzServer

Manages the server processes that create and run PnzJob instances

=item LINZ::PNZPP::BernJob

Runs individual Bernese processing jobs within a PnzJob (ie one for each RINEX file)

=back

=cut

package LINZ::PNZPP::PnzJob;

use Archive::Zip qw/:ERROR_CODES/;
use File::Copy;
use File::Path qw/make_path remove_tree/;
use JSON::PP;
use LINZ::GNSS::Time qw/seconds_datetime datetime_seconds/;
use LINZ::PNZPP::Template;
use LINZ::PNZPP::Utility qw/TemplateFunctions/;
use Log::Log4perl;
use LWP::Simple qw//;
use Carp;

require LINZ::PNZPP::BernJob;
require LINZ::PNZPP;


our $InputDir;
our $OutputDir;
our $WorkDir;
our $JobDir;
our $ArchiveInputDir;
our $ArchiveJobJsonDir;
our $ArchiveJobJsonFile='[job_id]_status.json';
our $InputJobFile;
our $OutputJobFile;
our $InputControlFile;
our $OutputControlFile;
our $LockFile;
our $LockFileExpiry;
our $SummaryTemplate;
our $StatusFile='status.json';
our $SummaryReports=[];

our $DefaultOrbitType='RAPID+';
our $DefaultRefRinexType='HOURLY+';
our %OrbitLookup=(
    ultra=>'ULTRA+',
    rapid=>'RAPID+',
    final=>'FINAL'
    );
our $BernesePcf='RUN_PNZ';


our $ArchiveInputRetentionDays=30;
our $ArchiveJobJsonRetentionDays=30;
our $ArchiveBerneseRetentionDays=30;

=head2 LINZ::PNZPP::LoadConfig

Loads the PostioNZ-PP configuration information

=cut

sub LoadConfig
{
    my($conf) = @_;

    # Mandatory information

    $InputDir=$conf->filename("InputDir") || croak("Configuration does not define InputDir\n");
    $OutputDir=$conf->filename("OutputDir") || croak("Configuration does not define OutputDir\n");
    $WorkDir=$conf->filename("WorkDir") || croak("Configuration does not define WorkDir\n");
    $JobDir=$conf->filename("JobDir") || croak("Configuration does not define JobDir\n");
    $InputJobFile=$conf->get("InputJobFile") || croak("Configuration does not define InputJobFile\n");
    $OutputJobFile=$conf->get("OutputJobFile") || croak("Configuration does not define OutputJobFile\n");
    $StatusFile=$conf->get("StatusFile", $StatusFile);
    $InputControlFile=$conf->get("InputControlFile") || croak("Configuration does not define InputControlFile\n");
    $OutputControlFile=$conf->get("OutputControlFile") || croak("Configuration does not define OutputControlFile\n");
    $LockFile=$conf->get("LockFile") || croak("Configuration does not define LockFile\n");
    $LockFileExpiry=$conf->get("LockFileExpiry") || croak("Configuration does not define LockFileExpiry\n");

    # Templates

    $SummaryTemplate=$conf->filename("SummaryTemplate") || croak("Configuration does not define SummaryTemplate\n");

    # Optional information

    $ArchiveInputDir=$conf->filename("ArchiveInputDir");
    $ArchiveJobJsonDir=$conf->filename("ArchiveJobJsonDir");
    $ArchiveInputRetentionDays=$conf->get("ArchiveInputRetentionDays",$ArchiveInputRetentionDays)+0;
    $ArchiveBerneseRetentionDays=$conf->get("ArchiveBerneseRetentionDays",$ArchiveBerneseRetentionDays)+0;
    $ArchiveJobJsonRetentionDays=$conf->get("ArchiveJobJsonRetentionDays",$ArchiveJobJsonRetentionDays)+0;
    $ArchiveJobJsonFile=$conf->get("ArchiveJobJsonFile",$ArchiveJobJsonFile);
    
    my $sumrpts=$conf->get("SummaryReports");
    if( ref($sumrpts) eq 'HASH' && exists $sumrpts->{summaryreport} )
    {
        $SummaryReports=[];
        my $reports=$sumrpts->{summaryreport};
        $reports=[$reports] if ref $reports ne 'ARRAY';
        foreach my $rpt (@{$reports})
        {
            my $template=$conf->expand($rpt->{template});
            my $source=$conf->expand($rpt->{source});
            if( $template || $source )
            {
                $rpt->{template}=$template;
                $rpt->{source}=$source;
                push(@$SummaryReports,$rpt);
            }
        }
    }
}

sub _JobDir
{
    my ($jobid) = @_;
    my $jobdir=$JobDir;
    $jobdir=~ s/\[jobid\]/$jobid/g;
    return "$WorkDir/$jobdir";
}

sub _Logger
{
    return Log::Log4perl->get_logger('LINZ.PNZPP.PnzJob');
}

=head2 $job=LINZ::PNZPP::PnzJob->new($server,$zipfile,$idcheck);

This creates a new job PostioNZ-PP job. Each job is saved as a set of files in its own 
directory.  The job status is saved and reloaded in a JSON formatted file in this directory.
The directory also contains the input rinex files, and may also contain results files saved 
from the processing.  

This function creates the job directory, extracts the input data into the directory.
It then creates a BernJob object for each input file, as currently all input files are 
processed separately.

=cut

sub _subjob
{
    my ($nsubjob) = @_;
    my $chars='0123456789ABCDEFGHIJKLMNPQRSTUVWXYZ';
    my $s0=int(($nsubjob)/length($chars));
    my $s1=$nsubjob-length($chars)*$s0;
    my $id=substr($chars,$s1,1);
    $id = substr($chars,$s0-1,1).$id if $s0 > 0;
    return $id;
}


sub new
{
    my( $class, $server, $zipfile, $idcheck, $overwrite ) = @_;
    my $zip=Archive::Zip->new();
    $zip->read($zipfile)==AZ_OK || croak("Cannot read zip file $zipfile\n");
    my $jdm=$zip->memberNamed($InputControlFile)
       || croak("Input job $zipfile does not contain $InputControlFile\n");

    my $jobdir='';
    my $self;
    eval
    {
        my $jobdata=decode_json($jdm->contents());
        $self=bless $jobdata, $class;
        my $jobid=$self->{id};
        if( $idcheck ne '' && $idcheck ne $jobid )
        {
            croak("Zip file name $zipfile doesn't match job id $jobid\n");
        }

        my $files=$jobdata->{files};

        $jobdir=_JobDir($jobid);
        remove_tree($jobdir) if -d $jobdir;
        die "Existing job directory $jobdir cannot be removed\n" if -d $jobdir;

        $self->{jobdir}=$jobdir;
        $self->{resultsid}=0;
        $self->{completed}=0;
        $self->{submitted}=$self->{submitted} ? datetime_seconds($self->{submitted}) : time();
        $self->{start_time}=time();

        my $error;
        make_path($jobdir,{error=>\$error});
        die "Cannot create job directory $jobdir\n" if @$error;

        $self->lock() || die "Cannot lock new job $jobid\n";
        
        my $fileorbtype=$OrbitLookup{$self->{orbit_type}} || $DefaultOrbitType;
        my $filereftype=$DefaultRefRinexType;

        my $nsubjob=0;
        # Convert files to bern jobs

        my $bernjobs=[];
        my $antennae={};
        my $receivers={};
        foreach my $file (@{$self->{files}})
        {
            my $subjobid=_subjob($nsubjob);
            $nsubjob++;
            my $filename=$file->{filename};
            my $filemetadata={
                    orig_anttype=>$file->{orig_antenna_type},
                    orig_rectype=>$file->{orig_receiver_type},
                };
            $receivers->{$file->{orig_receiver_type}}=$file->{receiver_type};
            $antennae->{$file->{orig_antenna_type}}=$file->{antenna_type};

            my $rfm=$zip->memberNamed($filename) ||
                die "Data file $filename missing from $zipfile";
            if( $rfm->extractToFileNamed("$jobdir/$filename") != AZ_OK )
            {
                die "Could not extract $filename\n";
            };
            push(@$bernjobs, new LINZ::PNZPP::BernJob(
                    $self,
                    $subjobid,
                    $filename,
                    $fileorbtype,
                    $filereftype,
                    $filemetadata,
                ));
                    
        }
        $self->{bernjobs}=$bernjobs;
        $self->unlock();
        # Record which antennae and receivers have been used
        LINZ::PNZPP::UpdateGnssUsage($antennae,$receivers);
   };
   if( $@ )
   {
       my $error;
       remove_tree($jobdir,{error=>\$error});
       croak($@);
   }
   $self->{_server} = $server;
   return $self;
}

sub info
{
    my ($self,$message)=@_;
    my $serverid=$self->{_server} ? $self->{_server}->id().': ' : '';
    _Logger($serverid)->info($serverid.$message);
}

sub warn
{
    my ($self,$message)=@_;
    my $serverid=$self->{_server} ? $self->{_server}->id().': ' : '';
    _Logger($serverid)->warn($serverid.$message);
}

sub error
{
    my ($self,$message)=@_;
    my $serverid=$self->{_server} ? $self->{_server}->id().': ' : '';
    _Logger($serverid)->error($serverid.$message);
}

=head2 $job=LINZ::PNZPP::PnzJob->reload($server,$jobdir)

Restores a PnzJob object that was preserved.  Takes the job working directory
name as an argument.

=cut

sub reload
{
    my ($class,$server,$jobdir) = @_;
    my $savefile="$jobdir/$StatusFile";
    open( my $sf, "<$savefile" ) || croak("Cannot open job status $savefile\n");
    my $json = join('',<$sf>);
    close($sf);
    my $self;
    eval
    {
        $self=JSON->new->utf8->decode($json);
    };
    if( $@ )
    {
        # Dispose of invalid status file to avoid trying to reload again..
        unlink($savefile);
        croak("Cannot load job status $savefile - deleting file\n$@");
    }
    $self->{jobdir}=$jobdir;
    foreach my $job (@{$self->{bernjobs}})
    {
        $job=LINZ::PNZPP::BernJob->reload($job);
    }
    $self->{_server}=$server;
    return bless $self, $class;
}

# This is required to allow the JSON::encode function to run - otherwise it 
# complains about blessed hashes.

sub TO_JSON
{
    my($self)=@_;
    return {%$self};
}

=head2 $job->save()

Updates the jobs status file which persists the state of the jov

=cut

sub save
{
    my ($self,$savefile)=@_;
    $savefile=$self->{jobdir}.'/'.$StatusFile if ! $savefile;
    open( my $sf, ">$savefile" ) || croak("Cannot save job status to $savefile\n");

    # Don't include the server in the saved state..
    my $server=$self->{_server};
    delete $self->{_server};
    my $jsondata=JSON::PP->new->pretty->utf8->convert_blessed->encode($self);
    $self->{_server}=$server;

    print $sf $jsondata;
    close($sf);
    if( $self->{eta_time} > 0 )
    {
        my $mtime=$self->{eta_time};
        utime  $mtime, $mtime, $savefile;
    }
}


=head2 $job->locked

Tests if a jobs is currently locked.  Job locking is managed by creating a lock file when
a job is being processed, and deleting it when the processing is done.  The lock file has
an expiry time after which it is ignored.

=cut

sub locked
{
    my($self)=@_;
    my $lockfile=$self->{jobdir}.'/'.$LockFile;
    my $now=time();
    return 1 if -e $lockfile &&
        $now-(stat($lockfile))[9] < $LockFileExpiry;
    return 0;
}

=head2 $job->lock()

Lock the job for processing

=cut 

sub lock
{
    my($self)=@_;
    return 0 if $self->locked();
    my $lockfile=$self->{jobdir}.'/'.$LockFile;
    my $now=time();
    if( -e $lockfile )
    {
        $self->warn("Ignoring expired lock for job ".$self->{id});
    }
    my $lf;
    if( ! open($lf,">$lockfile") )
    {
        $self->error("Cannot create lock file for job ".$self->{id});
        croak("Cannot create lock file for job ".$self->{id});
    }
    print $lf "Lock created at ".seconds_datetime($now,1)." for job ".$self->{id}." in process $$\n";
    close($lf);
    utime($now,$now,$lockfile);
    return 1;
}

=head2 $job->unlock()

Unlock the job when processing is complete

=cut

sub unlock
{
    my($self)=@_;
    my $lockfile=$self->{jobdir}.'/'.$LockFile;
    unlink($lockfile);
}

=head2 $job->server()

Returns the PnzServer that is managing the job

=cut

sub server
{
    my($self)=@_;
    return $self->{_server};
}

=head2 $job->bernjobs()

Returns an array of BernJob (bernese processing jobs) associated with this PositioNZ-PP job.

=cut

sub bernjobs
{
    my ($self)=@_;
    my @jobs=@{$self->{bernjobs}};
    return wantarray ? @jobs : \@jobs;
}

=head2 $job->update()

The main job processing function.  This carries out the following steps

=over

=item Lock the job for processing

=item Run the update function for each BernJob

=item Run the sendResults function

This checks whether the job is complete, and if so sends the results and 
quits

=item If the job is complete, then send notification and remove the job

=back

=cut


sub update
{
    my($self)=@_;
    $self->lock() || return;
    my $updated=0;
    my $server=$self->server;
    
    eval
    {
        foreach my $job ($self->bernjobs())
        {
            last if ! $server->canRun();
            $server->writeStatus("Running Bernese job ".$job->{campaignid});
            eval
            {
                $job->{jobdir}=$self->{jobdir};
                if( $job->update($self->server) )
                {
                    $updated=1;
                    $job->archive();
                    $self->save();
                }
            };
            if( $@ )
            {
                my $errmsg=$@;
                $server->writeStatus("Error: ".$errmsg);
                $self->error($errmsg);
                $updated=1;
            }
            $server->writeStatus("Bernese job finished");
        }
        if( $updated )
        {
            my $complete=$self->sendResults();
            if( $complete )
            {
                $self->notifyComplete();
                $self->remove();
            }
            else
            {
                $self->save();
            }
        }
    };
    if( $@ )
    {
        $self->error("Error processing job ".$self->{id}.': '.$@);
        eval
        {
            $self->remove();
            $self->error("Removing job ".$self->{id});
        };
        if( $@ )
        {
            $self->error("Cannot remove job: ".$@);
        }
    }
    $self->unlock();
}

=head2 $job->notifyComplete

Send notification when the job has been completed. Notification involves accessing
a URL supplied by the front end with the job setup information.

=cut

sub notifyComplete
{
    my($self)=@_;
    if( $self->{completion_url})
    {
        eval
        {
            LWP::Simple::get($self->{completion_url}) ||
               die "Could not connect to ".$self->{completion_url}."\n";
        };
        if( $@ )
        {
            $self->warn("Failed to notify completion of ".$self->{id}.": ".$@);
        }
    }
}

=head2 $job->remove

Archives the bernese campaigns if required.
Removes the job working directory and the component bern jobs from the system.

=cut

sub remove
{
    my($self)=@_;
    $self->info("Removing job ".$self->{id});
    my $error;
    
    my $dir=$ArchiveJobJsonDir;
    if( $dir && ! -d $dir )
    {
        my $error;
        make_path($dir,{error=>\$error});
        $self->error("Cannot create archive directory $dir\n".
                         join("\n",@$error)."\n") if @$error;
    }
    if( $dir && -d $dir )
    {
        my $archfile=$ArchiveJobJsonFile;
        $archfile =~ s/\[jobid\]/$self->{id}/eg;
        $archfile = $dir.'/'.$archfile;
        eval
        {
            $self->save($archfile);
        };
    }
    foreach my $job ($self->bernjobs())
    {
        $job->remove();
    }
    my $jobdir=$self->{jobdir};
    remove_tree($jobdir,{error=>\$error});
    if( @$error )
    {
        $self->warn("Unable to delete job $jobdir");
    }
}

sub _formatTime
{
    my($time)=@_;
    return "" if ! $time;
    my $timestring=seconds_datetime($time);

    $timestring=$1.'T'.$2.'+00:00' if $timestring=~/^(\d\d\d\d\-\d\d\-\d\d)\s(\d\d\:\d\d\:\d\d)/;
}

=head2 $job->sendResults

Compiles the status information from each BernJob into the current results,
creates the results interface file used to update the web front end with the status,
and copies it to the interface directory.

Returns 1 if the job is complete (ie all Bernese jobs have completed or failed),
or 0 otherwise.

=cut

sub sendResults
{
    my($self)=@_;
    my $results={};
    my $eta_time=0;

    # Compile the results from all the files
    # and update the status if necessary

    my $nsuccess=0;
    my $nwait=0;
    my $nfail=0;
    my $njob=0;

    foreach my $job ($self->bernjobs())
    {
        $njob++;

        if( $job->complete )
        {
            $nsuccess++;
        }
        elsif( $job->waiting )
        {
            $nwait++;
            my $eta=$job->{eta_time};
            $eta_time=$eta if $eta_time==0;
            $eta_time=$eta if $eta != 0 && $eta < $eta_time;
        }
        elsif( $job->failed )
        {
            $nfail++;
        }
    }

    # Failed and complete jobs are finished as far as processing 
    # is concerned... only waiting jobs are continued.
    my $complete=$nwait==0;

    $self->{end_time}=time() if $complete && ! $self->{end_time};
    $self->{eta_time}=$eta_time;
    my $etastr=_formatTime($eta_time);

    # Create the summary data required by the PositioNZ-PP front end

    my $status_info='No files were submitted for processing.';
    if( $njob == 1 )
    {
        if( $nsuccess ){ $status_info="Completed successfully"; }
        elsif( $nfail ){ $status_info="Processing failed"; }
        elsif( $nwait ){ $status_info="On hold till $etastr"; }
    }
    else
    {
        $status_info='';
        if( $nsuccess ){ $status_info="$nsuccess files successfully processed. ";}
        if( $nfail ){ $status_info.="$nfail files could not be processed. ";}
        if( $nwait ){ $status_info.="$nwait files waiting for data. On hold till $etastr. ";}
        $status_info =~ s/\s*$//;
    }
    my $substatus=$nwait ? "waiting" : $nfail ? "failed" : "success";

    my $htemplate=LINZ::PNZPP::Template->new($SummaryTemplate,readfile=>1);
    my $summary=$htemplate->expand(%$self,status_info=>$status_info,TemplateFunctions);

    my $resultfiles=[];
    $results=
    {
        status=>$complete ? 'completed' : 'waiting',
        substatus=>$substatus,
        status_info=>$status_info,
        start_time=>_formatTime($self->{start_time}),
        end_time=>_formatTime($self->{end_time}),
        eta_time=>$etastr,
        summary=>$summary,
        results_files=>$resultfiles,
    };


    # Create the output zip file

    my $resid=++($self->{resultsid});
    my $rzipnam=$OutputJobFile;
    $rzipnam =~ s/\[jobid\]/$self->{id}/eg;
    $rzipnam =~ s/\[version\]/$resid/eg;
    my $rzipfile=$OutputDir.'/'.$rzipnam;
    my $rziptmp=$rzipfile.'.tmp';

    unlink($rzipfile,$rziptmp); # Just in case something is already hanging around?
    # Create the zip file.
    my $rzip=Archive::Zip->new();

    # Add summary report files
    foreach my $rpt (@$SummaryReports)
    {
        next if lc($rpt->{require}) eq 'success' && ! $nsuccess;
        next if lc($rpt->{require}) eq 'fail' && ! $nfail;
        my $filename=$rpt->{filename};
        $filename=~ s/\[jobid\]/$self->{id}/eg;
        my $description=$rpt->{description};
        print "Building summary file $filename\n";
        eval
        {
            my $rptfile=$self->{jobdir}.'/'.$filename;

            if( $rpt->{template} )
            {
                my $template=LINZ::PNZPP::Template->new($rpt->{template},readfile=>1);
                open( my $rptf, ">$rptfile" ) || die "Cannot open $rptfile\n";
                $template->write($rptf,%$self,TemplateFunctions);
                close($rptf);
            }
            elsif( $rpt->{source} )
            {
                my $src=$rpt->{source};
                die "Report source file $src is missing\n" if ! -r $src;
                copy($src,$rptfile) || die "Cannot copy report file $rpt\n";
            }
            $rzip->addFile($rptfile,$filename);
            push(@$resultfiles,{
                filename=>$filename,
                description=>$rpt->{description}
                });
        };
        if( $@ )
        {
            $self->warn("Error creating summary report $filename: $@");
        }
    }

    # Add results files from each bern job
    foreach my $job ($self->bernjobs())
    {
        my %zfiles=();
        foreach my $rf (@{$job->{report_files}})
        {
            if( ! -f $rf->{source} )
            {
                $self->warn("Report output file ".$rf->{source}." is missing");
            }
            elsif( exists $zfiles{$rf->{target}})
            {
                $self->warn("Report output target file name ".$rf->{target}.
                    " already used (".$rf->{description}.")");
            }
            else
            {
                $rzip->addFile($rf->{source},$rf->{target});
                push(@$resultfiles,{
                        filename=>$rf->{target},
                        description=>$rf->{description}
                    });
            }
        }
    }

    my $resjson=JSON::PP->new->pretty->utf8->encode($results);
    $rzip->addString($resjson,$OutputControlFile);
    $rzip->writeToFileNamed($rziptmp)==AZ_OK || croak("Cannot create results zip file $rziptmp\n");

    # Move the output zip file to the interface directory

    chmod(0666,$rziptmp);
    move($rziptmp,$rzipfile) || croak("Cannot rename $rziptmp to $rzipfile\n");
    LINZ::PNZPP::RunHook('postupdate',$rzipfile);

    return $complete;
}

1;
