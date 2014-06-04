
use strict;

=head1 LINZ::PNZPP::Config

Package for PositioNZ configuration information.  Uses Config::General and adds
expansion of filenames.

=cut

package LINZ::PNZPP::Config;

use Config::General qw/ParseConfig/;
use Sys::Hostname;
use Carp;

our $DefaultFileName='/etc/positionzpp/positionzpp.conf';

=head2 my $conf=PNZPP::Config->new($filename)

Loads the PositioNZ-PP configuration from the specified file, or from the default file
${POSITIONZPP_HOME}/positionzpp.conf if no filename is supplied. 

=cut

sub new
{
    my($class, $filename)=@_;

    $filename ||= $DefaultFileName;
    croak("PositioNZ-PP configuration file $filename not defined\n") if ! -e $filename;

    my %config=ParseConfig(-ConfigFile=>$filename, -LowerCaseNames=>1 );

    my $localcfg=$filename.'.'.hostname();
    if( -f $localcfg )
    {
        my %local=ParseConfig(-ConfigFile=>$localcfg, -LowerCaseNames=>1 );
        foreach my $k (keys %local)
        {
            $config{$k} = $local{$k} if exists $config{$k};
        }

    }
    return bless \%config, $class;
}

=head2 $conf->has($key)

Tests that the key is defined in the configuration.

=cut

sub has
{
    my($self,$key)=@_;
    return exists $self->{lc($key)};
}

=head2 $conf->get($key,$default)

Retrieves the configuration value for the filename, using the $default value
if it is not defined

=cut

sub get
{
    my($self,$key,$default)=@_;
    return $self->has($key) ? $self->{lc($key)} : $default;
}

=head2 $expanded=$conf->expand($string)

Expands strings formatted as ${xxx}, where xxx can be one of 

=over

=item an item in the configuration file

=item an environment variable

=item a component of the local time, one of year, month, day, hour, minute, or second

=back

=cut

sub expand
{
    my($self,$filename,%used)=@_;
    my ($sec,$min,$hour,$day,$mon,$year)=localtime();
    my %timehash=
    (
        second=>sprintf("%02d",$sec),
        minute=>sprintf("%02d",$min),
        hour=>sprintf("%02d",$hour),
        day=>sprintf("%02d",$day),
        month=>sprintf("%02d",$mon+1),
        year=>sprintf("%04d",$year+1900),
    );

    my $maxexpand=10;
    while( $maxexpand-- && $filename=~ /\$\{\w+\}/ )
    {
        $filename =~ s/\$\{(\w+)\}/
                    $self->has($1) ? $self->get($1) : 
                    exists $ENV{$1} ? $ENV{$1} :
                    exists $timehash{$1} ? $timehash{$1} :
                    $1/exg;
    }
    return $filename;
}

=head2 $conf->filename($key,$default)

Similar to $conf->get() except that it substitues ${xxx} for the corresponding environment
variable or date value (using xxx = year, month, day, hour, minute, second.

=cut

sub filename
{
    my($self,$key,$default)=@_;
    my $maxexpand=10;
    my $filename=$self->get($key);
    $filename=$self->expand($filename);
    return $filename;
}

1;
