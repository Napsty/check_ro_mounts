#!/usr/bin/perl -w

# check_ro_mounts.pl
# Copyright (c) 2008 Valentin Vidic <vvidic@carnet.hr>
# Copyright (c) 2024 Claudio Kuenzler <ck@claudiokuenzler.com>
#
# Checks the mount table for read-only mounts; these are usually a sign of
# trouble (broken filesystem after a crash, etc.)
#
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# you should have received a copy of the GNU General Public License
# along with this program (or with Nagios);  if not, write to the
# Free Software Foundation, Inc., 59 Temple Place - Suite 330,
# Boston, MA 02111-1307, USA

use strict;
use Getopt::Long;

my $name = 'RO_MOUNTS';
my $mtab = '/proc/mounts';
my $fstab = '/etc/fstab';
my $fstab_check = 0;
my @fstab_mp = ();
my @includes = ();
my @excludes = ();
my @included_types = ();
my @excluded_types = ();
my @ro_mounts = ();
my $want_help = 0;
my $debug = 0;
my %ERRORS=('OK'=>0,'WARNING'=>1,'CRITICAL'=>2,'UNKNOWN'=>3,'DEPENDENT'=>4);

Getopt::Long::Configure(qw(no_ignore_case));
my $res = GetOptions(
    "help|h" => \$want_help,
    "debug|d" => \$debug,
    "mtab|m=s" => \$mtab,
    "fstab-check|F" => \$fstab_check,
    "fstab-path|f=s" => \$fstab,
    "path|p=s" => \@includes,
    "partition=s" => \@includes,
    "exclude|x=s" => \@excludes,
    "include-type|T=s" => \@included_types,
    "exclude-type|X=s" => \@excluded_types,
);

if ($want_help or !$res) {
    print_help();
    exit $ERRORS{$res ? 'OK' : 'UNKNOWN'};
}

my $includes_re       = globs2re(@includes);
my $excludes_re       = globs2re(@excludes);
my $included_types_re = globs2re(@included_types);
my $excluded_types_re = globs2re(@excluded_types);

# Do fstab check if selected
if ($fstab_check) {
  open(FSTAB, $fstab) or nagios_exit(UNKNOWN => "Can't open $fstab: $!");
  FSENTRY: while (<FSTAB>) {
    # parse fstab lines
    next FSENTRY if /^(#|\s)/; # skip commented or empty lines
    next FSENTRY if /,ro,/; # skip mounts which are designed to be read only
    my ($dev, $mp, $type, $opt, $dump, $pass) = split;
    next FSENTRY if $mp eq 'none'; # Skip entries with none mount point (e.g. swap)
    push @fstab_mp, $mp;
    print "Found fstab entry: $mp\n" if $debug;
  }
}

# Open mtab
open(MTAB, $mtab) or nagios_exit(UNKNOWN => "Can't open $mtab: $!");
MOUNT: while (<MTAB>) {
    # parse mtab lines
    my ($dev, $dir, $fs, $opt) = split;
    my @opts = split(',', $opt);
    print "Parsing mount entry: $dev $dir $fs $opt\n" if $debug;

    # check fstab
    if ($fstab_check) {
      next MOUNT unless (grep { $dir eq $_} @fstab_mp);
    } else {
      # check includes/excludes
      if ($includes_re) {
          if ($debug) {print "Ignoring current mount\n" unless $dev =~ qr/$includes_re/ or $dir =~ qr/$includes_re/;}
          next MOUNT unless $dev =~ qr/$includes_re/
                         or $dir =~ qr/$includes_re/;
      }
      if ($excludes_re) {
          if ($debug) {print "Ignoring current mount\n" if $dev =~ qr/$excludes_re/ or $dir =~ qr/$excludes_re/;}
          next MOUNT if $dev =~ qr/$excludes_re/
                     or $dir =~ qr/$excludes_re/;
      }
      if ($included_types_re) {
          if ($debug) {print "Ignoring current mount\n" if not $fs =~ qr/$included_types_re/;}
          next MOUNT if not $fs =~ qr/$included_types_re/;
      }
      if ($excluded_types_re) {
          if ($debug) {print "Ignoring current mount\n" if $fs =~ qr/$excluded_types_re/;}
          next MOUNT if $fs =~ qr/$excluded_types_re/;
      }
    }

    print "Selected current mount for ro check\n" if $debug;

    # check for ro option
    if (grep /^ro$/, @opts) {
        print "DETECTED RO MOUNT!\n" if $debug;
        push @ro_mounts, $dir;
    }
}
nagios_exit(UNKNOWN => "Read failed on $mtab: $!") if $!;
close(MTAB) or nagios_exit(UNKNOWN => "Can't close $mtab: $!");

# report findings
if (@ro_mounts) {
    nagios_exit(CRITICAL => "Found ro mounts: @ro_mounts");
} else {
    nagios_exit(OK => "No ro mounts found");
}

# convert glob patterns to a RE (undef if no patterns)
sub globs2re {
    my(@patterns) = @_;

    @patterns or return undef;
    foreach (@patterns) {
        s/ \\(.)       / sprintf('\x%02X', ord($1)) /egx;
        s/ ([^\\*?\w]) / sprintf('\x%02X', ord($1)) /egx;
        s/\*/.*/g;
        s/\?/./g;
    }
    return '\A(?:' . join('|', @patterns) . ')\z';
}

# output the result and exit plugin style
sub nagios_exit {
    my ($result, $msg) = @_;

    print "$name $result: $msg\n";
    exit $ERRORS{$result};
}

sub print_help {
    print <<EOH;
check_ro_mounts 0.2
Copyright (c) 2008 Valentin Vidic <vvidic\@carnet.hr>
Copyright (c) 2024 Claudio Kuenzler <ck\@claudiokuenzler.com>

This plugin checks the mount table for read-only mounts.


Usage:
  check_ro_mounts [-m mtab] [-p path] [-x path] [-X type]

Options:
 -h, --help
    Print detailed help screen
 -d
    Debug mode
 -m, --mtab=FILE
    Use this mtab instead (default is /proc/mounts)
 -p, --path=PATH, --partition=PARTITION
    Glob pattern of path or partition to check (may be repeated)
 -x, --exclude=PATH <STRING>
    Glob pattern of path or partition to ignore (only works if -p specified)
 -X, --exclude-type=TYPE <STRING>
    Ignore all filesystems of indicated type (may be repeated)
 -T, --include-type=TYPE <STRING>
    Specifically check all filesystems of indicated type (may be repeated)
 -F, --fstab-check
    Check only for filesystems which are active in fstab file (default is /etc/fstab)
 -f, --fstab-path
    Specify a different path for fstab (default is /etc/fstab)

EOH
}

# vim:sw=4:ts=4:et
