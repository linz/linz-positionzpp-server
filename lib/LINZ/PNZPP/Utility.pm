use strict;

package LINZ::PNZPP::Utility;

use Carp;
use IO::String;
use LINZ::Geodetic::CoordSysList qw/GetCoordSys/;
use POSIX qw/strftime/;

our @ISA=qw(Exporter);
our @EXPORT_OK=qw(TemplateFunctions);

=head1 LINZ::PNZPP::Utility

Provides some functions used for preparing data for the templates.

=head2 Synopsis

 use LINZ::PNZPP::Utility qw/TemplateFunctions/;

 $template->expand(%$data,TemplateFunctions);

=head2 Template syntax

This adds functions available for coordinate conversion as detailed below.

=cut 


=head2 ConvertCoords

Simple (non-epoch) coordinate conversion.  

Implemented in a template as

  newcoord=ConvertCoords( crdsys, x, y, z, crdsys, epoch )

newcoord has elements 

   X,Y,Z (for geocentric coordinate)
   lon,lat,hgt (for geodetic coordinate)
   east,north,hght (for a projection coordinate)

If defined epoch is the conversion epoch.

=cut

sub _coordinate
{
    my ($csf,$x,$y,$z)=@_;
    my $crdf = $csf->type eq LINZ::Geodetic::GEODETIC ? [$y, $x, $z] : [$x, $y, $z];
    $crdf=$csf->coord($crdf);
    return $crdf;
}

sub ConvertCoords
{
    my($csysf,$x,$y,$z,$csyst,$epoch)=@_;
    my $csf=GetCoordSys($csysf);
    my $cst=GetCoordSys($csyst);
    my $crdf=_coordinate($csf,$x,$y,$z);
    $crdf->setepoch($epoch) if $epoch;
    my $crdt=$crdf->as($cst,$epoch);

    my $result={};
    if( $cst->type == LINZ::Geodetic::CARTESIAN ) 
    {
        $result->{X}=$crdt->X;
        $result->{Y}=$crdt->Y;
        $result->{Z}=$crdt->Z;
    }
    elsif( $cst->type == LINZ::Geodetic::GEODETIC ) 
    {
        $result->{lon}=$crdt->lon;
        $result->{lat}=$crdt->lat;
        $result->{hgt}=$crdt->hgt;
    }
    else
    {
        $result->{east}=$crdt->easting;
        $result->{north}=$crdt->northing;
        $result->{hgt}=$crdt->hgt;
    }
    $result->{csname}=$cst->name;
    $result->{cscode}=$cst->code;
    return $result;
}

=head2 CalcOrthHeight( $csysf, $lon, $lat, $hgt, $hgtcrdsys )

Function to calculate the "orthometric height" from an ellipsoidal height and a 
height coordinate system (essentially a geoid).

Returns the height as a scalar.

=cut

sub CalcOrthHeight
{
    my( $csysf, $x, $y, $z, $geoid ) = @_;
    my $cslist=LINZ::Geodetic::CoordSysList->newFromCoordSysDef();
    my $csf=$cslist->coordsys($csysf);
    my $hrf=$cslist->hgtref($geoid);
    my $crd=_coordinate($csf,$x,$y,$z);
    return $hrf->get_orthometric_height($crd);
}

=head2 $version=DefModelVersion( $coordsys )

Returns the version of deformation model associated with the coordinate system,
if it is defined.

=cut

sub DefModelVersion
{
    my($csys)=@_;
    my $result='';
    eval
    {
        my $cs=GetCoordSys($csys);
        $result=$cs->datum->defmodel->version();
    };
    return $result;
}

=head2 $circuits=MeridionalCircuits( $lon, $lat )

Function returns an array of the codes of meridional circuit coords that 
apply at a given location   Locations are defined by a longitude and latitude.

Returns an array ref of meridional circuit coord system codes that apply at the
location.

=cut

sub MeridionalCircuits
{
    my( $lon, $lat )  = @_;
    require LINZ::Geodetic::NZMeridionalCircuits;
    return LINZ::Geodetic::NZMeridionalCircuits::Circuits($lon,$lat);
}

=head2 $time=UTC($timestamp,$format)

Formats a timestamp as a UTC time.  The default format is yyyy-mm-dd HH:MM:SS. Otherwise
the format is an strftime format string.

=cut 

sub UTC
{
    my($timestamp,$format) = @_;
    $format ||= '%Y-%m-%d %H:%M:%S';
    return strftime($format,gmtime($timestamp || time()));
}

=head2 $time=LocalTime($timestamp,$format)

Formats a timestamp as a local time.  Formatting is as for the UTC function.

=cut

sub LocalTime
{
    my($timestamp,$format) = @_;
    $format ||= '%Y-%m-%d %H:%M:%S';
    return strftime($format,localtime($timestamp || time()));
}

=head2 $field = CsvQuote($field)

Encloses a fields in double quotes, and replaces an double quotes in the string with
pairs of double quotes, as used for quoted fields in CSV formatted data.

=cut

sub CsvQuote
{
    my($text)=@_;
    $text =~ s/\"/""/g;
    return '"'.$text.'"';
}

sub TemplateFunctions
{
    return (
        ConvertCoords => \&ConvertCoords,
        CalcOrthHeight => \&CalcOrthHeight,
        MeridionalCircuits => \&MeridionalCircuits,
        DefModelVersion => \&DefModelVersion,
        UTC => \&UTC,
        LocalTime => \&LocalTime,
        CsvQuote => \&CsvQuote,
        );
}

1;
