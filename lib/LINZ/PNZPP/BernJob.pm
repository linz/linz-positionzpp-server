
package LINZ::PNZPP::BernJob;


=head1 LINZ::PNZPP::BernJob

Package to manage individual bernese jobs within a PositionzPP job.  

=cut

use strict;

use Archive::Zip qw/:ERROR_CODES/;
use Carp;
use File::Find;
use File::Path qw/make_path remove_tree/;
use LINZ::BERN::BernUtil;
use LINZ::BERN::PcfFile;
use LINZ::GNSS::DataCenter;
use LINZ::GNSS::Time qw/datetime_seconds seconds_datetime/;
use LINZ::GNSS::SinexFile();
use LINZ::PNZPP::Template;
use LINZ::PNZPP::Utility qw/TemplateFunctions/;
use JSON;
use Net::SMTP;

our @LockFiles = ('OUT/GETORB.LCK', 'OUT/GETREF.LCK');
our $StatusFile= 'OUT/STATUS.LCK';
our $SummaryJsonFile= 'OUT/SUMMARY.JSON';
our $KeepBerneseCampaign=0;
our $ArchiveBerneseDir;
our $ArchiveBerneseFile='[bernid]_bernese.zip';
our $ArchiveBernesePending='none';
our $ArchiveBerneseSuccess='none';
our $ArchiveBerneseFail='none';
our $ArchiveBernesePendingDelete='none';
our $ArchiveBerneseSuccessDelete='none';
our $ArchiveBerneseFailDelete='none';
our $LogStatisticsDir;
our $SuccessStatisticsFile;
our $SuccessStatisticsHeader;
our $SuccessStatisticsRow;
our $FailStatisticsFile;
our $FailStatisticsHeader;
our $FailStatisticsRow;
our $CompleteReportTemplate;
our $WaitReportTemplate;
our $FailedReportTemplate;
our $ReportFiles=[];

our $SmtpServer;
our $NotificationEmailFrom='bern_server@linz.govt.nz';
our $NotificationEmailTo='positionz@linz.govt.nz';
our $NotificationEmailTitle='PositioNZ-PP job failure: [bernid]';
our $NotificationEmailTemplate='';

our $TeqcBin='/usr/bin/teqc';
our $TeqcUserParams='+metadata';
our $TeqcRefParams='+metadata';

=head2 LINZ::PNZPP::BernJob::LoadConfig

Loads configuration information used by the Bernese processing module

=cut

sub LoadConfig
{
    my ($conf)=@_;
    if( $conf->has("PcfLockFiles"))
    {
        @LockFiles=split(' ',$conf->get("PcfLockFiles"));
    }
    $SummaryJsonFile=$conf->get("PcfSummaryJasonFile",$SummaryJsonFile);
    $StatusFile=$conf->get("PcfStatusFile",$StatusFile);
    $ArchiveBerneseDir=$conf->filename("ArchiveBerneseDir");
    $ArchiveBerneseFile=$conf->get("ArchiveBerneseFile",$ArchiveBerneseFile);
    $ArchiveBernesePending=$conf->get("ArchiveBernesePending",$ArchiveBernesePending);
    $ArchiveBernesePendingDelete=$conf->get("ArchiveBernesePendingDelete",$ArchiveBernesePendingDelete);
    $ArchiveBerneseSuccess=$conf->get("ArchiveBerneseSuccess",$ArchiveBerneseSuccess);
    $ArchiveBerneseSuccessDelete=$conf->get("ArchiveBerneseSuccessDelete",$ArchiveBerneseSuccessDelete);
    $ArchiveBerneseFail=$conf->get("ArchiveBerneseFail",$ArchiveBerneseFail);
    $ArchiveBerneseFailDelete=$conf->get("ArchiveBerneseFailDelete",$ArchiveBerneseFailDelete);
    $KeepBerneseCampaign=$conf->get("KeepBerneseCampaign",$KeepBerneseCampaign);
    $LogStatisticsDir=$conf->filename("LogStatisticsDir");
    $SuccessStatisticsFile=$conf->filename("SuccessStatisticsFile");
    $SuccessStatisticsHeader=$conf->filename("SuccessStatisticsHeader");
    $SuccessStatisticsRow=$conf->filename("SuccessStatisticsRow");
    $FailStatisticsFile=$conf->filename("FailStatisticsFile");
    $FailStatisticsHeader=$conf->filename("FailStatisticsHeader");
    $FailStatisticsRow=$conf->filename("FailStatisticsRow");
    $CompleteReportTemplate=$conf->filename("CompleteReportTemplate") || croak("Configuration does not define CompleteReportTemplate\n");
    $WaitReportTemplate=$conf->filename("WaitReportTemplate") || croak("Configuration does not define WaitReportTemplate\n");
    $FailedReportTemplate=$conf->filename("FailedReportTemplate") || croak("Configuration does not define FailedReportTemplate\n");

    $SmtpServer=$conf->get("SmtpServer",'');
    $NotificationEmailFrom=$conf->get("NotificationEmailFrom",$NotificationEmailFrom);
    $NotificationEmailTo=$conf->get("NotificationEmailTo",$NotificationEmailTo);
    $NotificationEmailTitle=$conf->get("NotificationEmailTitle",$NotificationEmailTitle);
    $NotificationEmailTemplate=$conf->filename("NotificationEmailTemplate");
    $TeqcBin=$conf->get("TeqcBin",$TeqcBin);
    $TeqcUserParams=$conf->get("TeqcUserParams",$TeqcUserParams);
    $TeqcRefParams=$conf->get("TeqcRefParams",$TeqcRefParams);
    my $rfiles=$conf->get("ReportFiles");
    if( ref($rfiles) eq 'HASH' && exists $rfiles->{reportfile} )
    {
        $ReportFiles=$rfiles->{reportfile};
        $ReportFiles=[$ReportFiles] if ref($ReportFiles) ne 'ARRAY';
    }
}

sub _Logger
{
    my $logger=Log::Log4perl->get_logger('LINZ.PNZPP.BernJob');
    return $logger;
}

=head2  $bernjob=LINZ::PNZPP::BernJob->new($jobid,$subjobid,$filename,$orbittype,$reftype)

Creates a new Bernese processing job as part of a PostioNZ-PP job (LINZ::PNZPP::PnzJob).

Parameters are:

=over

=item $jobid    The PositioNZ job id

=item $subjobid The id of the processing job within the main PositioNZ job

=item $filename The name of the RINEX file to be processed

=item $orbittype The orbit type required, (eg FINAL, RAPID+)

=item $reftype  The type of reference data required (eg DAILY, HOURLY+)

=back

=cut

sub new
{
    my($class,$job,$subjobid,$filename,$orbittype,$reftype,$filemetadata)=@_;

    $filemetadata ||= {};

    my $campid=substr($job->{id}.'_',0,8-length($subjobid)).$subjobid;
    my $serverid='';
    $serverid=$job->server()->id() if $job->server();

    my $self= bless {
        jobid=>$job->{id},
        subjobid=>$subjobid,
        campaignid=>$campid,
        email=>$job->{email},
        filename=>$filename,
        filemetadata=>$filemetadata,
        orbit_type=>$orbittype,
        ref_rinex_type=>$reftype,
        status=>'wait',
        message=>'Not yet started.',
        serverid=>$serverid,
        }, $class;
    return $self;
}

# This is required to allow the JSON::encode function to run - otherwise it 
# complains about blessed hashes.

sub TO_JSON
{
    my($self)=@_;
    return {%$self};
}

=head2 $bernjob=LINZ::PNZJOB::BernJob->reload($hash)

Reblesses a persisted hash reference to this class

=cut

sub reload
{
    my($class,$hash)=@_;
    return bless $hash,$class;
}

sub createCampaign
{
    my($self)=@_;
    my $campid=$self->{campaignid};
    eval
    {
        my $srcfile=$self->{jobdir}.'/'.$self->{filename};

        # Codes that are not valid for user stations...
        my $codes=LINZ::GNSS::DataCenter::AvailableStations();
        my $campaign=LINZ::BERN::BernUtil::CreateCampaign(
            $campid,
            RinexFiles=>[$srcfile],
            # RenameRinex=>'U###',
            RenameCodes=>$codes,
            CrdFile=>'APR$S+0',
            AbbFile=>'ABBREV',
            StaFile=>'STATIONS',
            AddNoneRadome=>1,
            MakeSessionFile=>1,
            SettingsFile=>1,
            CanOverwrite=>1,
        );
        die "Cannot create Bernese job for RINEX file $srcfile\n" if ! $campaign;

        # Copy file metadata to bernese file record
        my $meta=$campaign->{files}->[0];
        foreach my $key (keys %{$self->{filemetadata}})
        {
            $meta->{$key}=$self->{filemetadata}->{$key}
                if ! exists $meta->{$key};
        }

        # Add variables required by bernese software
        my $vars=$campaign->{variables};
        $vars->{V_USRMRK}=$campaign->{marks}->[0];
        $vars->{V_ORBTYP}=$self->{orbit_type};
        $vars->{V_ERPTYP}=$self->{orbit_type};

        $self->{campaign}=$campaign;
        $self->{campaigndir}=$campaign->{campaigndir};
        $self->{status}='wait';
    };
    if( $@ )
    {
        _Logger()->error("Cannot create campaign $campid\n$@\n");
        $self->{status}='fail';
        $self->{message}=$@;
    }
}

=head2 $locksok = $bernjob->checkBerneseLocks()

Check whether the bernese processing lock files have expired.  These are 
set when a download is not expected to be available until a later date.
The file modification time of the lock file is set to when the lock expires.

=cut

sub checkBerneseLocks
{
    my($self)=@_;
    my $campdir=$self->{campaigndir};
    my $now=time();
    foreach my $lf (@LockFiles)
    {
        my $lockfile="$campdir/$lf";
        return 0 if -e $lockfile && (stat($lockfile))[9] > $now;
    }
    return 1;
}

=head2 $bernjob->runBerneseProcessor()

This script runs the Bernese processing job and evaluates the final status of the job.
This uses the LINZ::BERN::BernUtil::RunPcf function to run the PositioNZ-PP PCF file.

The status is read from the status file (STATUS.LCK) generated by the PCF.  

If the job is successfully completed then the results are read from the SUMMARY.JSON file also
created by the PCF.

=cut

sub runBerneseProcessor
{
    my($self,$bernenv)=@_;

    my $campid=$self->{campaignid};
    my $logger=_Logger();
    my $serverid=$self->{serverid};
    $logger->info("$serverid: Running Bernese job  $campid");
    $self->{start_time}=time();
    my $pcffile=$bernenv->{PCF_FILE};
    my $status=LINZ::BERN::BernUtil::RunPcf(
        $self->{campaign},
        $pcffile,
        CLIENT_ENV=>$bernenv->{CLIENT_ENV},
        CPU_FILE=>$bernenv->{CPU_FILE},
    );
    $self->{end_time}=time();
    $self->{bernese_status}=$status;

    # The status file is generated by the PNZSTART script.  The first line consists
    # of a one word status followed optionally by additional information (typically the
    # wait time, and the rest of the file is an optional status message.
    #
    # The status is one of FAIL, WAIT, SUCCESS

    my $campdir=$self->{campaigndir};
    my $stsfile="$campdir/$StatusFile";
    open(my $sf,"<$stsfile") || croak("Cannot open PCF status file $StatusFile\n");
    my $stsline=<$sf>;
    if( $stsline =~ /^\s*(\w+)(?:\s+(.*?))\s*$/)
    {
        my($status,$stsvalue)=($1,$2);
        $self->{status}='complete' if $status eq 'SUCCESS';
        $self->{status}='fail' if $status eq 'FAIL';
        $self->{status}='wait' if $status eq 'WAIT';
        $self->{status_value} = $stsvalue;
        $self->{status_description} = join('',<$sf>);
        $self->{eta_time}=0;
        if( $status eq 'WAIT' )
        {
            eval
            {
                my $eta=datetime_seconds($stsvalue);
                $self->{eta_time}=$eta;
            };
        }
    }
    close($sf);

    # If complete - then get the results

    if( $self->{status} eq 'complete' )
    {
        eval
        {
            my $jsonfile="$campdir/$SummaryJsonFile";
            open(my $jf, $jsonfile) || die "Cannot open summary JSON file $jsonfile\n";
            my $jsondata=join('',<$jf>);
            close($jf);
            my $results=JSON->new->utf8->decode($jsondata);
            $self->{results}=$results;
        };
        if( $@ )
        {
            $self->{status}='fail';
            $self->{status_description}=$@;
        }
    }
    if( $self->{status} eq 'fail' )
    {
        my $runsts=$self->{campaign}->{runstatus} || {};
        my $fail_pid= $runsts->{fail_pid} || '000';
        my $fail_message= $runsts->{fail_message} || $self->{status_description};
        $logger->error("$serverid: Bernese job $campid failed: PID $fail_pid: $fail_message");
    }
    elsif( $self->{status} eq 'wait' )
    {
        $logger->info("$serverid: Bernese job $campid on hold till ".seconds_datetime($self->{eta_time},1));
    }
    else
    {
        $logger->info("$serverid: Bernese job $campid completed");
    }
    return $self->{status};
}

=head2 $bernjob->complete

Returns true if the job is successfully completed

=cut

sub complete
{
    return $_[0]->{status} eq 'complete';
}

=head2 $bernjob->waiting

Returns true if the job is waiting for data

=cut

sub waiting
{
    return $_[0]->{status} eq 'wait';
}

=head2 $bernjob->failed

Returns true if the job completed unsuccessfully

=cut

sub failed
{
    return $_[0]->{status} eq 'fail';
}

=head2 $updated=$bernjob->update($server)

Updates the BernJob.  Returns 1 if the job status is updated, 0 otherwise.

The parameter is the PnzServer that is managing the job, which supplies the Bernese
client environment.

Creates the Bernese campaign if it is not already defined, checks for lock/wait files
that have not yet expired (eg waiting for orbit data), and runs the Bernese PCF if there
are no current locks.

=cut 

sub update
{
    my ($self,$server)=@_;
    return 0 if $self->{status} ne 'wait';

    $self->{serverid}=$server->id();

    # Note that creating the bernese environment also sets the variables
    # in %ENV.
    my $bernenv=$server->berneseClientEnv();
    my $created=0;
    if( ! $self->{campaign} )
    {
        $self->createCampaign();
        $created=1;
    }
    return 0 if ! $self->{campaign};
    return $created if ! $self->checkBerneseLocks();
    $self->runBerneseProcessor($bernenv);
    $self->compileReport();
    $self->writeStats() if $self->{status} ne 'wait';
    $self->sendFailNotification() if $self->{status} eq 'fail';
    $server->deleteBerneseClientEnv();
    return 1;
}

=head2 $bernjob->compileReport()

Generates a user readable report detailing the current status of the job

=cut

sub _filterSinex
{
    my($source,$filtered)=@_;
    my $sf=new LINZ::GNSS::SinexFile( $source );
    $sf->filterStationsOnly($filtered);
}

sub compileReport()
{
    my ($self)=@_;
    my $template=$WaitReportTemplate;
    $template=$CompleteReportTemplate if $self->complete;
    $template=$FailedReportTemplate if $self->failed;
    my $ftemplate=LINZ::PNZPP::Template->new($template,readfile=>1);
    $self->{report}= LINZ::PNZPP::Template->new($template,readfile=>1)->expand(
            %$self,
            TemplateFunctions
            );
    $self->{report_files}=[];

    if( ! $self->waiting() )
    {
        my $files=[];
        my $mark=$self->{campaign}->{marks}->[0];
        my $session=$self->{campaign}->{SES_INFO};
        my $bernid=$self->{campaignid};
        my $jobid=$self->{jobid};
        my $subjobid=$self->{subjobid};
        my $file=$self->{campaign}->{files}->[0]->{orig_filename};
        my $serverid=$self->{serverid};

        foreach my $rfile (@$ReportFiles)
        {
            my $source=$rfile->{source};
            my $target=$rfile->{output};
            my $filter=$rfile->{filter} || 'copy';
            my $description=$rfile->{description};
            foreach my $item ($source,$target,$description)
            {
                $item=~s/\[jobid\]/$jobid/g;
                $item=~s/\[subjob\]/$subjobid/g;
                $item=~s/\[bernid\]/$bernid/g;
                $item=~s/\[file\]/$file/g;
                $item=~s/\[cccc\]/$mark/g;
                $item=~s/\[ssss\]/$session/g;
            }
            if( $source eq 'teqc' )
            {
                eval
                {
                    $source=$self->createTeqcReport($self->{campaigndir});
                };
                if( $@ )
                {
                    _Logger->warn("$serverid: Error creating teqc report: $@");
                }
            }
            my $sourcepath=$self->{campaigndir}.'/'.$source;
            if( ! -f $sourcepath )
            {
                _Logger()->warn("$serverid: Report file $sourcepath is missing") if $self->complete();
            }
            elsif( $target !~ /^[A-Z0-9_.-]+$/i )
            {
                _Logger()->error("$serverid: Invalid report file target name $target defined");
            }
            else
            {
                if( $filter eq 'sinex' )
                {
                    my $filtered=$sourcepath.'.flt';
                    eval
                    {
                        _filterSinex($sourcepath,$filtered);
                        $sourcepath=$filtered;
                    };
                    if( $@ )
                    {
                        _Logger()->warn("$serverid: Error filtering sinex $source: $@");
                    }
                }
                push(@$files,{source=>$sourcepath,target=>$target,description=>$description});
            }
        }
        $self->{report_files}=$files;
    }
}

=head2 $filename=$bernjob->createTeqcReport($campaigndir)

Routine to create a teqc report file for the RINEX files in a campaign.

=cut

sub createTeqcReport
{
    my($self,$campaigndir)=@_;
    my $rnxdir=$campaigndir.'/RAW';
    my $rptname='OUT/TEQCRPT.OUT';
    my $rptfile=$campaigndir.'/'.$rptname;
    my %userfile=();
    my $serverid=$self->{serverid};
    foreach my $uf (@{$self->{campaign}->{files}})
    {
        $userfile{$uf->{filename}}=$uf;
    }

    my $rpt;
    if( ! open( $rpt, ">$rptfile" ) )
    {
        _Logger()->error("$serverid: Cannot create teqc report file $rptfile");
        return $rptname;
    }
    if( ! -x $TeqcBin )
    {
        _Logger()->error("$serverid: Cannot run teqc at $TeqcBin") if $TeqcBin != 'none';
        return $rptname;
    }


    my @userfiles;
    my @reffiles;
    if( opendir(my $dh, $rnxdir))
    {
        while(my $fname=readdir($dh))
        {
            my $fpath=$rnxdir.'/'.$fname;
            next if ! -f $fpath;
            if( exists($userfile{$fname}) )
            {
                push(@userfiles,$fname);
            }
            else
            {
                push(@reffiles,$fname);
            }
        }
        close($dh);
    }

    print $rpt "Summary of rinex data used\n\n";
    foreach my $i (1,2)
    {
        my $list;
        my $params;
        if( $i == 1 )
        {
            $list=\@userfiles;
            $params = $TeqcUserParams;
        }
        else
        {
            my $sess_start=seconds_datetime($self->{campaign}->{session_start});
            my $sess_end=seconds_datetime($self->{campaign}->{session_end});
            print $rpt "\n","="x50,"\nReference data files\n";
            print $rpt "Note: Only using data within the observation window $sess_start to $sess_end.\n\n";

            $list=\@reffiles;
            $params = $TeqcRefParams;
        }
        my $cmd=$TeqcBin.' '.$params;

        my $nfile=0;
        foreach my $f (sort @$list)
        {

            print $rpt "-"x50,"\n" if $nfile++;
            print $rpt "File: $f";
            my $uf=$userfile{$f};
            if( $uf )
            {
                my $userf=$uf->{orig_filename};
                print $rpt " renamed from $userf" if $userf ne $f;
            }
            print $rpt "\n";
            if( $uf )
            {
                if( $uf->{orig_anttype} ne $uf->{anttype} )
                {
                    print $rpt "Note: Antenna type changed from ".
                        $uf->{orig_anttype}.' to '.$uf->{anttype}."\n";
                }
                if( $uf->{orig_rectype} ne $uf->{rectype} )
                {
                    print $rpt "Note: Receiver type changed from ".
                        $uf->{orig_rectype}.' to '.$uf->{rectype}."\n";
                }
            }

            $cmd .= ' "'.$rnxdir.'/'.$f.'"';
            my $output=`$cmd`;
            my $qrnx=quotemeta($rnxdir.'/');
            $output =~ s/$qrnx//g;
            print $rpt $output;
        }
    }

    close($rpt);

    return $rptname
}

=head2 $bernjob->writestats

Write summary statistics to the statistics log files

=cut

sub writeStats
{
    my($self)=@_;
    my $status=$self->{status};
    return if $status ne 'complete' && $status ne 'fail';
    my $file=$status eq 'complete' ? $SuccessStatisticsFile : $FailStatisticsFile;
    my $header=$status eq 'complete' ? $SuccessStatisticsHeader : $FailStatisticsHeader;
    my $row=$status eq 'complete' ? $SuccessStatisticsRow : $FailStatisticsRow;
    return if $file eq '' || $row eq '';
    $file=$LogStatisticsDir.'/'.$file;
    my $serverid=$self->{serverid};
    eval
    {
        if( ! -d $LogStatisticsDir )
        {
            my $error=[];
            make_path($LogStatisticsDir,{error=>\$error});
            if( ! -d $LogStatisticsDir )
            {
                die("Cannot create statistics log directory $LogStatisticsDir\n".
                    join("\n",@$error)."\n");
            }
        }
        my $newfile = ! -f $file;
        open( my $f, ">>$file" ) || die "Cannot open statistics file $file\n";
        LINZ::PNZPP::Template->new($header,readfile=>1)->write($f,%$self,TemplateFunctions) if $newfile && $header ne '';
        LINZ::PNZPP::Template->new($row,readfile=>1)->write($f,%$self,,TemplateFunctions);
        close($f);
    };
    if( $@ )
    {
        _Logger->error($serverid.': '.$@);
    }    
}

=head2 $bernjob->archive()

Archives the job to the specified directory.  The amount archived is based on the 
$ArchiveBernesePending, $ArchiveBerneseSuccess and $ArchiveBerneseFailure configuration, 
and may be one of 'all' (all data archived), or 'output' (BPE and OUT 
directories archived).  Otherwise nothing is archived and the 
file is not created.

The $ArchiveXxxxDelete flag may be used to exclude particulare file names or 
patterns using the * wild card.

=cut

sub archive
{
    my ($self)=@_;
    my $dir=$ArchiveBerneseDir;
    return if ! $dir;
    my $serverid=$self->{serverid};
    if( ! -d $dir )
    {
        my $error;
        make_path($dir,{error=>\$error});
       _Logger()->error("$serverid: Cannot create archive directory $dir\n".
                         join("\n",@$error)."\n") if @$error;
        return;
    }

    my $archzip=$ArchiveBerneseFile;
    my $campid=$self->{campaignid};
    $archzip =~ s/\[bernid\]/$campid/eig;
    $archzip=$dir.'/'.$archzip;

    my $level=$ArchiveBernesePending;
    my $exclude=$ArchiveBernesePendingDelete;
    $level = $ArchiveBerneseSuccess if $self->{status} eq 'complete';
    $exclude = $ArchiveBerneseSuccessDelete if $self->{status} eq 'complete';
    $level = $ArchiveBerneseFail if $self->{status} eq 'fail';
    $exclude = $ArchiveBerneseFailDelete if $self->{status} eq 'fail';

    $level = uc($level);
    if( $level eq 'ALL')
    {
        $level = '\w\w\w';
    }
    elsif( $level eq 'OUTPUT' )
    {
        $level = '(OUT|BPE)';
    }
    elsif( $level =~ /^\w\w\w(?:\/\w\w\w)*$/)
    {
        $level=~ s/\//|/g;
        $level="($level)";
    }
    else
    {
        return;
    }
    $level="\\/$level\$";

    $exclude=uc($exclude);
    if( $exclude eq 'NONE' )
    {
        $exclude='';
    }
    else
    {
        $exclude =~ s/\s*$//;
        $exclude =~ s/^\s*//;
        $exclude =~ s/\s+/\|/g;
        $exclude =~ s/\*/\\w+/g;
        $exclude = "($exclude)";
    }

    my $campdir=$self->{campaigndir};
    eval
    {
        my $zip=Archive::Zip->new();
        my $campdirlen=length($campdir)+1;
        my @archfiles=();

        my $findsub=sub
        {
            return if -d $_;
            return if $File::Find::dir !~ /$level/;
            return if $exclude && $File::Find::name =~ /$exclude/;
            push(@archfiles,$File::Find::name);
        };

        find( {wanted=>$findsub, no_chdir=>1},$campdir);
        return if ! @archfiles;
        foreach my $f (@archfiles)
        {
            my $localname=substr($f,$campdirlen);
            $zip->addFile($f,$localname);
        }
        $zip->writeToFileNamed($archzip)==AZ_OK || die "Cannot create archive zip $archzip\n";
    };
    if( $@ )
    {
        _Logger()->error("$serverid: Failed to archive bernese data $campdir: ".$@);
    }
}

=head2 $bernjob->remove

Deletes the Bernese campaign directories created by the job.

=cut 

sub remove
{
    my ($self)=@_;
    if( $self->{campaigndir} )
    {
        my $error=[];
        remove_tree($self->{campaigndir},{error=>\$error}) if ! $KeepBerneseCampaign;
        if( @$error )
        {
            my $serverid=$self->{serverid};
            _Logger()->error("$serverid: Unable to delete Bernese directories\n".join('',@$error));
        }
        delete $self->{campaign};
        delete $self->{campaigndir};
    }
}

=head2 $bernjob->sendFailNotification

Sends an email to the system administrators advising of a failed job

=cut

sub sendFailNotification
{
    my($self)=@_;


    my $server = $SmtpServer;
    return if $server eq '' || $server eq 'none';

    my $smtp = Net::SMTP->new($server);
    if( ! $smtp )
    {
        my $serverid=$self->{serverid};
        _Logger()->error("$serverid: Cannot connect to SMTP server $server to send fail notification message");
        return;
    }

    my @to = split(/\;/,$NotificationEmailTo);

    my $title=$NotificationEmailTitle;
    $title=~ s/\[bernid\]/$self->{campaignid}/eg;
    
    my $message="PositioNZ-PP processing job ".$self->{campaignid}." failed\n";
    eval
    {
        $message=LINZ::PNZPP::Template->new($NotificationEmailTemplate,readfile=>1)->expand(
            %$self,TemplateFunctions);
    };
    if( $@ )
    {
        my $serverid=$self->{serverid};
        _Logger->error("$serverid: Error creating bern fail mail: $@");
    }

    $smtp->mail($NotificationEmailFrom);
    $smtp->to(@to,{SkipBad=>1});
    $smtp->data();
    $smtp->datasend("To: $NotificationEmailTo\n");
    $smtp->datasend("From: $NotificationEmailFrom\n");
    $smtp->datasend("Subject: $title\n\n");
    $smtp->datasend($message);
    $smtp->dataend();
    $smtp->quit();
}

1;
