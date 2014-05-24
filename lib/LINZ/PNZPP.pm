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
our $GnssRefDataFile;
our $GnssUsageDataFile;
our $GpsUsageFile;
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
    $GnssRefDataFile=$conf->filename("GnssRefDataFile");
    $GnssUsageDataFile=$conf->filename("GnssUsageDataFile");
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
   antennae_alias=>[ { from=>to, from=>to }, ... ],
   receivers=>[ {name=>rec1, used=>0} ],
   receiver_alias=>[ { from=>to, from=>to }, ... ],
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
        if( $GnssRefDataFile )
        {
            my $usage=_getUsageData($logger);
            my $reffile=$GnssRefDataFile;
            my $reftmp=$reffile.".update.$$";

            my $used=$usage->{antennae}->{used};
            my $aliases=$usage->{antennae}->{alias};
            my $antlist=LINZ::BERN::BernUtil::AntennaList();
            my @antarr=map { {name=>$_, used=>(exists($used->{$_}) ? 1 : 0) } } @$antlist;

            my @antalias=();
            foreach my $key (keys %$aliases)
            {
                push(@antalias,{ from=>$key, to=>_preferredAlias($aliases->{$key}) });
            }

            $used=$usage->{receivers}->{used};
            $aliases=$usage->{receivers}->{alias};
            my $reclist=LINZ::BERN::BernUtil::ReceiverList();
            foreach my $r (@$reclist) { $r =~ s/\s+$//; }
            my @recarr=map { {name=>$_, used=>(exists($used->{$_}) ? 1 : 0) } } @$reclist;

            my @recalias=();
            foreach my $key (keys %$aliases)
            {
                push(@recalias,{ from=>$key, to=>_preferredAlias($aliases->{$key}) });
            }

            my $refdata={
                antennae=>\@antarr,
                antennae_alias=>\@antalias,
                receivers=>\@recarr,
                receiver_alias=>\@recalias
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

=head2 LINZ::PNZPP::UpdateGnssUsage( $antennae, $receivers )

Update the usage statistics of antennae and receivers.  This is used to maintain keep the 
reference data more useful, but keeping track of aliases used for antennae/receivers, and 
which ones are actually used.  The input lists are dictionaries with the input name as the 
key and the standardised name as the value, ie
    orig_value=>std_value

The script maintains data structure formatted as 

{
   antennae=>{
      used=>{code=>{count=>n, lastused=>timestamp},...}
      alias=>{from=>{ to=>{count=>n,lastused=>timestamp }, ... }, ... }
      }
   receivers=>{
      ...
      }
}

This is stored in JSON format in the GnssUsageData file

=cut

sub UpdateGnssUsage
{
    my ($antennae,$receivers)=@_;
    LoadConfig();
    my $reffile=$GnssUsageDataFile;
    my $logger=Log::Log4perl->get_logger('LINZ.PNZPP');

    my $usage=_getUsageData($logger);
    my $usagechanged=0;
    my $now=time();
    foreach my $dataset (['antennae',$antennae],['receivers',$receivers])
    {
        my $type=$usage->{$dataset->[0]};
        my $source=$dataset->[1];
        foreach my $alias (keys %$source)
        {
            my $std=$source->{$alias};
            # Have a mapping from $alias in the original users file to the 
            # standardised version $std (for either receiver or antennae)
            
            # Check the usage record for the standard type, and record 
            # or increment.  If it is a new type then the usage data is 
            # updated

            if( ! exists $type->{used}->{$std} )
            {
                $usagechanged=1;
                $type->{used}->{$std}={count=>1,lastused=>$now};
            }
            else
            {
                $type->{used}->{$std}->{count}++;
                $type->{used}->{$std}->{lastused}=$now;
            }

            # If this is not an alias (original and standardised are the same,
            # then nothing more to do
            next if $std eq $alias;

            # If this alias has not been used before then just record it.
            if( ! exists $type->{alias}->{$alias} )
            {
                $usagechanged=1;
                $type->{alias}->{$alias}->{$std}={count=>1,lastused=>$now};
                next
            }
            # Find the current preferred alias for the mark.


            my $aliases=$type->{alias}->{$alias};
            my $curalias=_preferredAlias($aliases);
            if( ! exists $aliases->{$std} )
            {
                $aliases->{$std}={count=>1,lastused=>$now};
            }
            else
            {
                $aliases->{$std}->{count}++;
                $aliases->{$std}->{lastused}=$now;
            }
            my $newalias=_preferredAlias($aliases);
            $usagechanged if $newalias ne $curalias;
        }
    }

    # Now update the usage file

    my $reftmp=$reffile.".update.$$";
    eval
    {
        my $rfdata=JSON::PP->new->pretty->encode($usage);
        open( my $rft,">$reftmp") || die "Cannot open $reftmp\n";
        print $rft $rfdata;
        close($rft);
        rename($reftmp,$reffile);
    };
    if( $@ )
    {
        $logger->warn("Update of GNSS usage $reffile failed: $@\n");
        unlink($reftmp);
        $usagechanged=0;
    }

    if( $usagechanged )
    {
        UpdateReferenceData();
    }
}


sub _getUsageData
{
    my($logger)=@_;
    my $reffile=$GnssUsageDataFile;
    my $usage={ 
        antennae=>{used=>{},alias=>{}},
        receivers=>{used=>{},alias=>{}},
        };
    if( -f $reffile && open(my $rff,"<$reffile") )
    {
        eval
        {
            my $data=join('',<$rff>);
            my $dusage=JSON::PP->new->decode($data);
            die "Usage data is not valid\n" if
               ref($dusage) ne 'HASH' ||
                ref($dusage->{antennae}) ne 'HASH' ||
                ref($dusage->{antennae}->{used}) ne 'HASH' ||
                ref($dusage->{antennae}->{alias}) ne 'HASH' ||
                ref($dusage->{receivers}) ne 'HASH' ||
                ref($dusage->{receivers}->{used}) ne 'HASH' ||
                ref($dusage->{receivers}->{alias}) ne 'HASH';
            $usage=$dusage;
        };
        if( $@ )
        {
            $logger->warn("Error reading GnssUsageDataFile $reffile: $@\n") if $logger;
        }
    }
    return $usage;
}

sub _preferredAlias
{
    my ($aliases)=@_;
    my $curalias='';
    my $curcount=0;
    my $curtime=0;
    foreach my $std (sort keys %$aliases)
    {
        my $alias=$aliases->{$std};
        next if $alias->{count} < $curcount ||
           ($alias->{count} == $curcount && $alias->{lastused} < $curtime);
        $curalias=$std;
        $curcount=$alias->{count};
        $curtime=$alias->{curtime};
    }
    return $curalias;
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
