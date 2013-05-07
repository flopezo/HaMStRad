#!/usr/bin/perl
=head1 NAME

hamstr-fix-reftaxon.pl

=head1 SYNOPSIS

perl hamstr-fix-reftaxon.pl --inputdir INPUTDIR --outputdir OUTPUTDIR

=head1 DESCRIPTION

hamstr-fix-reftaxon attempts to fix the reference taxon assignment that HaMStR messed up. It does so by generating a pairwise clustalw alignment and selecting the reference taxon sequence with the highest score. It then rewrites the output files using the correct header.

=head1 OPTIONS

=head2 --inputdir DIR

Input directory. Is expected to contain HaMStR output files (*.aa.fa). Mandatory option.

=head2 --outputdir DIR

Output directory. Where the rewritten files should be placed. It is recommended not to use the same dir that you read from, but instead overwrite the affected files with their corrected copies afterwards. Mandatory option.

=head2 --clustalw /path/to/clustalw

Path to clustalw executable. On some systems, this is called clustalw2, or is not in $PATH, or something else.

=head1 AUTHOR

Malte Petersen <mptrsen@uni-bonn.de>

=cut

use strict;
use warnings;
use autodie;

use File::Spec;
use File::Temp;
use File::Basename;
use Getopt::Long;
use IO::Dir;
use IO::File;
use List::Util qw(first);

my $clustalw = 'clustalw';
my $outdir = undef;
my $indir = undef;

GetOptions(
	'clustalw=s' => \$clustalw,
	'outputdir=s' => \$outdir,
	'inputdir=s' => \$indir,
);

unless ($indir and $outdir) {
	print "Usage: $0 --inputdir INPUTDIR --outputdir OUTPUTDIR [--clustalw /path/to/clustalw]\n";
	exit;
}

# get list of input files
my @infiles = get_files($indir);

foreach my $inf (@infiles) {
	# read sequences into memory
	my $seq_of = slurp_fasta($inf);

	# the taxon header
	my $header = first { /.*\|.*\|.*\|.*/ } keys %$seq_of;
	my ($geneid, $coretaxon, $taxon, $id) = split /\|/, $header;

	# did it get the correct reftaxon? if so, just exit
	if ($coretaxon =~ /\Q$taxon\E/) {
		print "$inf is ok\n";
		next;
	}
	printf "%s: seems strange, reformatting...\n", basename($inf);

	# take it out of the sequence pool
	my $sequence = delete $seq_of->{$header};

	# determine the correct reftaxon and take that out of the pool as well
	my ($hiscoretaxon, $hiscoreheader) = get_real_coretaxon($seq_of, $header, $sequence);
	my $hiscoresequence = delete $seq_of->{$hiscoreheader};
	# the hash now contains only all sequences without the refspec sequence and the taxon sequence
	# this is so we can write those back in order

	# format the header
	$header = sprintf "%s|%s|%s|%s", $geneid, $hiscoretaxon, $taxon, $id;

	# output
	my $outf = File::Spec->catfile($outdir, basename($inf));
	my $outfh = IO::File->new($outf, 'w') or die "Fatal: could not open $outf for writing: $!\n";
	printf $outfh ">%s\n%s\n", $_, $seq_of->{$_} foreach keys %$seq_of;
	printf $outfh ">%s\n%s\n", $hiscoreheader, $hiscoresequence;
	printf $outfh ">%s\n%s\n", $header, $sequence;
	undef $outfh;
	
	# report
	printf "%s: corrected reftaxon for %s to %s (was: %s)\n", basename($outf), $taxon, $hiscoretaxon, $coretaxon;
}


# get a list of (*.aa.fa) files in the the dir
# call: get_files($dirname)
# returns: list of scalar string filenames
sub get_files {
	my $dirn = shift @_;
	my $aadirh = IO::Dir->new($dirn);
	die "Fatal: could not open dir $dirn\: $!\n" unless defined $aadirh;
	my @files = ();
	while (my $f = $aadirh->read) {
		# skip stuff starting with a dot
		next if $f =~ /^\./;
		if (-f File::Spec->catfile($dirn, $f)) {
			push @files, File::Spec->catfile($dirn, $f);
		}
	}
	undef $aadirh;
	@files = grep { /aa\.fa$/ } @files;
	return @files;
}

sub get_real_coretaxon {
	my $sequences = shift @_;
	my $header = shift @_;
	my $sequence = shift @_;
	my $hiscore = 0;
	my $hiscoretaxon = '';
	my $hiscoreheader = '';

	foreach (keys %$sequences) {
		my ($geneid, $taxon, $id) = split /\|/;
		my $fh = File::Temp->new();
		printf $fh ">%s\n%s\n", $_, $sequences->{$_};
		printf $fh ">%s\n%s\n", $header, $sequence;
		close $fh;
		my $outfh = File::Temp->new();
		my $result = [ `$clustalw -infile=$fh -outfile=$outfh` ];
		chomp @$result;
		my $score = first { $_ =~ /Alignment Score/ } @$result;
		$score =~ /Score\s*(\d+)/ and $score = $1;
		if ($score > $hiscore) {
			$hiscore = $score;
			$hiscoretaxon = $taxon;
			$hiscoreheader = $_;
		}
	}

	return ($hiscoretaxon, $hiscoreheader);
}

#mp sub: slurp_fasta
#mp reads the content of a Fasta file into a hashref
sub slurp_fasta {
	my $fastafile = shift @_;
	my $data = { };
	my $fastafh = Seqload::Fasta->open($fastafile);
	while (my ($h, $s) = $fastafh->next_seq()) {
		$data->{$h} = $s;
	}
	return $data;
}


####################
# 
# Seqload::Fasta package
# for simple and error-free loading of fasta sequence data
# 
####################

package Seqload::Fasta;
use strict;
use warnings;
use Carp;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw( fasta2csv check_if_fasta );

# Constructor. Returns a sequence database object.
sub open {
  my ($class, $filename) = @_;
  open (my $fh, '<', $filename)
    or confess "Fatal: Could not open $filename\: $!\n";
  my $self = {
    'filename' => $filename,
    'fh'       => $fh
  };
  bless($self, $class);
  return $self;
}

# Returns the next sequence as an array (hdr, seq). 
# Useful for looping through a seq database.
sub next_seq {
  my $self = shift;
  my $fh = $self->{'fh'};
	# this is the trick that makes this work
  local $/ = "\n>"; # change the line separator
  return unless defined(my $item = readline($fh));  # read the line(s)
  chomp $item;
  
  if ($. == 1 and $item !~ /^>/) {  # first line is not a header
    croak "Fatal: " . $self->{'filename'} . "is not a FASTA file: Missing descriptor line\n";
  }

	# remove the '>'
  $item =~ s/^>//;

	# split to a maximum of two items (header, sequence)
  my ($hdr, $seq) = split(/\n/, $item, 2);
	$hdr =~ s/\s+$//;	# remove all trailing whitespace
  $seq =~ s/>//g if defined $seq;
  $seq =~ s/\s+//g if defined $seq; # remove all whitespace, including newlines

  return($hdr, $seq);
}

# Closes the file and undefs the database object.
sub close {
  my $self = shift;
  my $fh = $self->{'fh'};
  my $filename = $self->{'filename'};
  close($fh) or carp("Warning: Could not close $filename\: $!\n");
  undef($self);
}

# Destructor. This is called when you undef() an object
sub DESTROY {
  my $self = shift;
  $self->close;
}

# Convert a fasta file to a csv file the easy way
# Usage: Seqload::Fasta::fasta2csv($fastafile, $csvfile);
sub fasta2csv {
  my $fastafile = shift;
  my $csvfile = shift;

  my $fastafh = Seqload::Fasta->open($fastafile);
  CORE::open(my $outfh, '>', $csvfile)
    or confess "Fatal: Could not open $csvfile\: $!\n";
  while (my ($hdr, $seq) = $fastafh->next_seq) {
		$hdr =~ s/,/_/g;	# remove commas from header, they mess up a csv file
    print $outfh $hdr . ',' . $seq . "\n"
			or confess "Fatal: Could not write to $csvfile\: $!\n";
  }
  CORE::close $outfh;
  $fastafh->close;

  return 1;
}

# validates a fasta file by looking at the FIRST (header, sequence) pair
# arguments: scalar string path to file
# returns: true on validation, false otherwise
sub check_if_fasta {
	my $infile = shift;
	my $infh = Seqload::Fasta->open($infile);
	my ($h, $s) = $infh->next_seq() or return 0;
	return 1;
}
