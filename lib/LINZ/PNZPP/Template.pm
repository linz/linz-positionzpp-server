use strict;

package LINZ::PNZPP::Template;

use Carp;
use IO::String;
use Log::Log4perl;
use Scalar::Util qw/reftype/;

=head1 LINZ::PNZPP::Template

Very simple template system in which the first character of the line defines how it is used.
This is geared towards fixed format data.

=head2 Synopsis

 $template=new LINZ::PNZPP::Template($text,%options);
 $template->write($handle,name1=>$value1,name2=>$value2, ... );

=head2 Template syntax

The template is defined on a set of lines for which the first character defines the 
usage of the line, and the remainder is either an expression, list of expressions, or template 
text.

The template is defined in blocks starting with +, ?, !, or *.  Within the block the template defines 
template text on lines starting with a blank or | character (but see trim blanks option).  The text
can contain placeholders, which are replaced with variables defined on lines starting with =.  There
is a one for one replacement of placeholders with variables.  Blocks may be nested - variables apply
to the block in which they are defined.

 +          start of block
 ?          start of conditional block
 !          start of negative conditional block
 *          start of repeat block
 \          literal text
 | or blank text with value placeholders
 #          comment
 =          list of values to insert
 -          end of block
 @          replace line with contents of file.  

Placeholders are one of 

 #####      Integer value
 ##.###     Numeric value
 $$$$$      String value
 $$$$>      Right justified string      
 $$$$+      Arbitrary length string

Placeholders must be at least two characters long

=head2 Variable syntax

The +, ?, !, *, and = lines may be followed by a list of variables or expressions.  These are based
on input data that are organised as a hash reference.  Each value in the hash may itself be a hash,
array, or scalar.  Array elements are accessed using the notation [index].  Hash elements are accessed 
using simple . notation (hash.key).  Perl $ variable prefixes are not used.  Values may be preceded by
"key=" in the + and * records to define a new variable, otherwise each key for the variables becomes a
new variable in its own right.

=cut

=head2 $template=new LINZ::PNZPP::Template(text,%options)

Creates a new template based on the input text.  The text can be a string, an array of strings,
or a filename.  Options can include

=over

=item readfile=>1

Use text as the name of a file from which to read the template

=item trimlines=>1

Trim leading space from the lines (requires using | or \ as first character for template text)_

=back

=cut 

our $_logger=0;

sub _Logger
{
    $_logger ||= Log::Log4perl->get_logger('LINZ.PNZPP.Template');
    return $_logger;
}

sub new 
{
    my($class,$text,%options) = @_;
    if( $options{readfile} )
    {
        open(my $f, "<$text") || croak("Cannot open template file $text\n");
        my @lines=<$f>;
        close($f);
        $text=\@lines;
    }
    $text=[$text] if reftype($text) ne 'ARRAY';
    my @lines=();
    foreach my $tline (@$text)
    {
        chomp($tline);
        foreach my $line (split(/\n/,$tline))
        {
            $line =~ s/^\s+// if $options{trimlines};
            next if $line =~ /^\#/;
            $line =~ s/\s+$// if $options{trimlines};
            $line = ' ' if $line eq '';
            $line .= "\n" if $line !~ /\n$/;
            push(@lines,$line);
        }
    }
    return bless \@lines, $class;
}

=head2 $template->write($fh,name1=>value1, ... )

Expand the template and write to a file handle.  Takes parameters name1=$value1 etc which 
are used in the template variables.

=cut

sub write
{
    my ($self, $fh, %data ) = @_;
    my $data = \%data;
    my $start=0;
    $self->_evaluate($fh, $data, $start );
}

=head2 $template->writeToFile($filename,name=>value1,...)

Expand the template and write to a file.

=cut

sub writeToFile
{
    my ($self,$filename,%data) = @_;
    open(my $fh,">$filename") || croak("Cannot open $filename in LINZ::PNZPP::Template::writeToFile\n");
    $self->write($fh,%data);
    close($fh);
}


=head2 $template->expand(name1=>value1, ... )

Expand the template and return a string 

=cut

sub expand
{
    my($self,%data)=@_;
    my $fh = new IO::String();
    $self->write($fh,%data);
    my $value=${$fh->string_ref};
    return $value;
}

sub _splitexpr
{
    my($line)=@_;
    my $expr=$line;
    $expr =~ s/\s*//;
    my $start=1;
    my $end=length($line);
    my @values=();
    _Logger->debug("Splitting $expr");
    while( 1 )
    {
        $expr =~ s/^\s*//;
        last if $expr eq '';
        my $end=0;
        my $blevel=0;
        my $instring=0;
        while($end < length($expr))
        {
            my $c=substr($expr,$end,1);
            $end++;
            if( $instring == 0 )
            {
                last if $c =~ /\s/ && $blevel == 0;
                $instring=1 if $c eq '"';
                $blevel++ if $c eq '(' || $c eq '{' || $c eq '[';
                $blevel-- if $c eq ')' || $c eq '}' || $c eq ']';
            }
            elsif( $instring == 2 )
            {
                $instring--;
            }
            else
            {
                $instring++ if $c eq '\\';
                $instring-- if $c eq '"';
            }
        }
        my $vexpr=substr($expr,0,$end);
        $vexpr=~s/\s*$//;
        $expr=substr($expr,$end);

        push(@values,$vexpr);
        _Logger()->debug("Found $vexpr");
    }
    return @values;
}

sub _expandexpr
{
    my ($string,$data,$next) =@_;
    my @parts=split(/\./,$string);
    if( exists $data->{$parts[0]} )
    {
        $string=~ s/(\w+)/{$1}/g;
        $string=~ s/\./->/g;
        $string= "\$data->".$string;
        $string.= "->" if $next ne '';

    }
    return $string.$next;
}

sub _evalexpr
{
    my( $expr, $data ) = @_;
    my $src=$expr;
    my $__str=[];
    my $nstr=0;
    # Replace literal strings with a string variable
    $expr =~ s/\"((?:[^\\\"]|\\.)*)\"/
        ($__str->[$nstr++]=$1) && "\$__str->[$nstr]"
        /xeg;
    # Remove escapes from string
    foreach my $s (@$__str){ $s =~ s/\\(\.)/$1/g };

    # Expand expressions, starting with a non-alphabetic or new line, then
    # a series of strings separated by dots, then possibly a terminating 
    # [ or (
    $expr=~ s/
                (^|[^\w\.])
                ([a-z_]\w*(?:\.[a-z_]\w*)*)
                ([\[\(])?
            /$1._expandexpr($2,$data,$3)/exsig;
    # Expand pairs of brackets to be separated by ->, ie x[][] becomes x[]->[],
    # assuming that everything is a reference..
    $expr =~ s/\]\[/]->[/g;
    $expr =~ s/\}\{/}->{/g;
    $expr =~ s/\}\(/}->(/g;
    _Logger()->debug("Evaluating $src as $expr");
    my $value = eval $expr;
    if( $@ )
    {
        _Logger()->warn("Error evaluating $src as $expr: $@");
    }
    return $value;
}

sub _evalblock
{
    my($lines,$fh,$data,$l,$ctlchar,$line)=@_;

    $line =~ s/^\s*//;
    $line =~ s/\s*$//;

    _Logger()->debug("Eval block: $l: $ctlchar: $line");

    my $blockre=qr/^[\+\?\!\*]/;
    my $endre=qr/^\-/;

    croak("Invalid line prefix $ctlchar in template\n") if $ctlchar !~ /$blockre/;
    
    # Conditional blocks expect a single expression, so enclose in parentheses to ensure this works
    $line = '( '.$line.' )' if ($ctlchar eq '?' || $ctlchar eq '!') && $line !~ /^\(.*\)$/;

    my @vars=();
    my @values=();
    foreach my $expr (_splitexpr($line))
    {
        my $varname='';
        if( $expr =~ /^([a-z_]\w*)\=([^\=\~].*)$/i )
        {
            $varname=$1;
            $expr=$2;
        }
        push(@vars,$varname);
        push(@values,_evalexpr($expr,$data));
    }
    if( $ctlchar eq '+' )
    {
        my %fdata=%$data;
        foreach my $i (0 .. $#values) 
        {
            if( $vars[$i] )
            {
                $fdata{$vars[$i]}=$values[$i];
            }
            elsif( reftype($values[$i]) eq 'HASH' )
            {
                foreach my $k (keys %{$values[$i]})
                {
                    $fdata{$k}=$values[$i]->{$k};
                }
            }
        }
        _evaluate($lines,$fh,\%fdata,$l);
    }
    elsif( $ctlchar eq '*')
    {
        foreach my $i (0..$#values)
        {
            my @lvalues=();
            my $v=$values[$i];
            if( reftype($v) eq 'ARRAY')
            {
                push(@lvalues,@$v);
            }
            elsif( reftype($v) eq 'HASH')
            {
                foreach my $k (sort keys %$v)
                {
                    push(@lvalues,$v->{$k});
                }
            }
            else
            {
                push(@lvalues,$v) if $v;
            }
            my $varname=$vars[$i];
            foreach $v (@lvalues)
            {
                my %fdata=%$data;
                if( $varname )
                {
                    $fdata{$varname}=$v;
                }
                elsif( reftype($v) eq 'HASH' )
                {
                    foreach my $k (keys %$v)
                    {
                        $fdata{$k}=$v->{$k};
                    }
                }
                _evaluate($lines,$fh,\%fdata,$l);
            }
        }
    }
    elsif( $ctlchar eq '?' && $values[0] )
    {
        _evaluate($lines,$fh,$data,$l);
    }
    elsif( $ctlchar eq '!' && ! $values[0] )
    {
        _evaluate($lines,$fh,$data,$l);
    }

    my $depth=1;
    while( $l < scalar(@$lines) && $depth > 0)
    {
        my $line=$lines->[$l];
        $l++;
        $depth++ if $line =~ /$blockre/;
        $depth-- if $line =~ /$endre/;
    }
    _Logger->debug("Finished eval block $ctlchar: $line at line $l");
    return $l;
}

sub _evaluate 
{
    my($lines,$fh,$data,$start)=@_;
    my $end=$#$lines;
    my $l=$start;
    my $text='';
    my @values;
    while( $l <= $end )
    {
        my $line=$lines->[$l];
        $l++;
        my $ctlchar=substr($line,0,1);
        $line=substr($line,1);
        if( $ctlchar eq '\\' )
        {
            $line =~ s/\%/\%\%/g;
            $text .= $line;
        }
        elsif( $ctlchar eq '@' )
        {
            my $file=_evalexpr($line,$data);
            if( open(my $fh,"<$file"))
            {
                my $value=join('',<$fh>);
                close($fh);
                $text .= "%s";
                push(@values,$value);
            }
        }
        elsif( $ctlchar eq '|' || $ctlchar eq ' ')
        {
            $line =~ s/(\$\$*([\$\>\+]))/
                     '%'.($2 eq '>' ? '' : '-').length($1).($2 eq '+' ? '' : '.'.length($1)).'s'
                     /exsg;
            $line =~ s/(\#(?:\#*\.(\#+)|\#+))/
                     '%'.length($1).($2 eq '' ? 'd' : '.'.length($2).'f')
                     /exsg;
            $text .= $line;
        }
        elsif( $ctlchar eq '=' )
        {
            foreach my $expr (_splitexpr($line))
            {
                push(@values,scalar(_evalexpr($expr,$data)));
            }
        }
        elsif( $ctlchar eq '-' )
        {
            last;
        }
        else
        {
            printf $fh $text,@values;
            $text='';
            @values=();
            $l=_evalblock($lines,$fh,$data,$l,$ctlchar,$line);
        }
    }
    printf $fh $text,@values;
    return $l;
}

1;
