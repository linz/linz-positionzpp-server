use strict;

=head1 LINZ::PNZPP

Package for managing PositionzPP jobs.

This module provides provides the function LINZ::PNZPP::Run that runs the PositioNZ-PP post processing service.
It first loads the configuration, then uses the functions from the LINZ::PNZPP::PnzJob module to load new jobs,
process existing jobs, and remove expired jobs.  It also provides the 

=cut

package LINZ::PNZPP;

our $VERSION='1.2.0';

use LINZ::PNZPP::PnzServer;
use LINZ::PNZPP::PnzJob;
use LINZ::PNZPP::BernJob;
use LINZ::PNZPP::Config;
use LINZ::GNSS;
use LINZ::BERN::BernUtil;
use Config::General qw/ParseConfig/;
use File::Copy;
use Log::Log4perl qw/:easy/;
use Carp;

our $RefDataDir;
our $GpsRefDataFile;
our $HookScript;

=head2 PNZPP::LoadConfig($filename,$nologging)

Loads the PositioNZ-PP configuration from the specified file, or from the default file
/etc/positionzpp/positionzpp.conf if no filename or an empyt filename is supplied. 

If $nologging evaluates true then the logging system is not initiated.


The configuration information is used to configure the LINZ::PNZPP::PnzJob and LINZ::PNZPP::BernJob
modules, and also to initiallize the logging system (using Log::Log4perl).

=cut

sub LoadConfig
{
    my($filename,$nologging)=@_;
    my $conf=LINZ::PNZPP::Config->new($filename);

    if( ! $nologging )
    {
        if( $conf->has("logsettings"))
        {
            my $logcfg=$conf->get("logsettings");
            my $logfile=$conf->filename("logdir").'/'.$conf->filename("logfile");
            $logcfg =~ s/\[logfilename\]/$logfile/eg;
            Log::Log4perl->init(\$logcfg);
        }
        elsif( exists $ENV{DEBUG_LINZGNSS} )
        {
            Log::Log4perl->easy_init($DEBUG);
        }
        else
        {
            Log::Log4perl->easy_init($WARN);
        }
    }
    $RefDataDir=$conf->filename("RefDataDir") || croak("RefDataDir not defined in configuration\n");
    $GpsRefDataFile=$conf->get("GpsRefDataFile");
    $HookScript=$conf->get("HookScript");
    LINZ::PNZPP::PnzServer::LoadConfig($conf);
    LINZ::PNZPP::PnzJob::LoadConfig($conf);
    LINZ::PNZPP::BernJob::LoadConfig($conf);
}

=head2 LINZ::PNZPP::RunHook($hookname,$parameter)

Runs the PositioNZ-PP hook script.  Hookname must be one of prerun, postupdate, and 
postrefdata. 

=cut

sub RunHook
{
    my($hookname,$parameter)=@_;
    return if ! $HookScript;
    if( ! -x $HookScript )
    {
        carp("Script $HookScript is not an executable file\n");
        return;
    }
    if( $hookname !~ /^(prerun|postupdate|postrefdata)$/ )
    {
        croak("Invalid positionzpp hook \"$hookname\" called\n");
    }
    system($HookScript,$hookname,$parameter);
}

=head2 LINZ::PNZPP::Run($serverid)

Runs a PositioNZ-PP server.  Loads the configuration, checks for an uploads new jobs,
processes existing jobs, and purges expired jobs (jobs that have been archived).

=cut

sub Run
{
    my($serverid)=@_;
    LINZ::GNSS::LoadConfig();
    LoadConfig();
    my $server=LINZ::PNZPP::PnzServer->new($serverid);
    $server->run();
}

=head2 LINZ::PNZPP::UpdateReferenceData()

Update the reference data files used by the PositioNZ-PP application - for example the 
antenna and receiver lists.  These are read from the Bernese directories and reformatted 
for loading into the front end application (as JSON formatted files)

Creates a JSON formatted file containing a data structure of 

 {
   antennae=>[ {name=>ant1, used=>0}, {name=>ant2, used=>0}, ...],
   antennae_alias=>{ from=>to, from=>to },
   receivers=>[ {name=>rec1, used=>0} ]
   receiver_alias=>{ from=>to, from=>to },
 }

The used flag identifies antennae and receivers that have been used in jobs submitted to
the processor, and the alias lists maps from non-standard names to standard names.

=cut

sub UpdateReferenceData
{
    LoadConfig();
    my $logger=Log::Log4perl->get_logger('LINZ.PNZPP');
    eval
    {
        $logger->info("Updating web application reference data\n");
        die("Invalid reference data configuration $RefDataDir\n") if ! -d $RefDataDir;
        if( $GpsRefDataFile )
        {
            my $reffile=$RefDataDir.'/'.$GpsRefDataFile;
            my $reftmp=$reffile.".update";

            my $antlist=LINZ::BERN::BernUtil::AntennaList();
            my @antarr=map { {name=>$_, used=>0} } @$antlist;

            my $reclist=LINZ::BERN::BernUtil::ReceiverList();
            foreach my $r (@$reclist) { $r =~ s/\s+$//; }
            my @recarr=map { {name=>$_, used=>0 } } @$reclist;

            my %antalias=();
            my %recalias=();

            my $refdata={
                antennae=>\@antarr,
                antennae_alias=>\%antalias,
                receivers=>\@recarr,
                receiver_alias=>\%recalias
                };

            my $refjson=JSON::PP->new->pretty->utf8->encode($refdata);
            open(my $f,">$reftmp") || die("Cannot open antennae list file $reftmp\n");
            print $f $refjson;
            close($f);
            move($reftmp,$reffile) || die("Cannot update antennae list file $reffile\n");
            RunHook('postrefdata',$reffile);
        }
    };
    if( $@ )
    {
        $logger->error($@);
        croak($@);
    }
}

=head2 LINZ::PNZPP::PurgeArchive

Removes expired information from the PositioNZ job archive.

=cut

sub PurgeArchive
{
    LoadConfig();
    LINZ::PNZPP::PnzJob::PurgeArchive();
}

1;
