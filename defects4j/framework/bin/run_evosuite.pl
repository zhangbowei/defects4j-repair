#!/usr/bin/env perl
#
#-------------------------------------------------------------------------------
# Copyright (c) 2014 René Just, Darioush Jalali, and Defects4J contributors.
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#-------------------------------------------------------------------------------

=pod

=head1 NAME

run_evosuite.pl -- Run evosuite for a particular project and version_id. Tests are
generated for all modified classes (i.e., all classes that were modified to fix 
the bug).

=head1 SYNOPSIS

run_evosuite.pl -p project_id -v version_id -n test_id -o out_dir -c criterion [-b search_budget] [-a assertion_timeout] [-t tmp_dir] [-D]

=head1 OPTIONS

=over 4

=item B<-p C<project_id>> 

The id of the project for which test suites are generated.

=item B<-v C<version_id>> 

Generate tests for this version id. B<Format: \d+[bf]>.

=item B<-n C<test_id>> 

The test_id of the generated test suite (i.e., which run of the same configuration)

=item B<-o F<out_dir>> 

The root output directory for the generated tests. All tests and logs for a given 
project and version id are written to:
F<"out_dir"/"project_id"/"vid">

=item B<-c F<criterion>>  

Generate tests for this criterion using the default search budget. 
See below for supported test criteria.

=item B<-b F<search_budget>> 

Set a specific search budget (optional). See below for defaults.

=item B<-a F<assertion_timeout>> 

Set a specific timeout for assertion generation (optional).
The default is 300sec.

=item B<-t F<tmp_dir>> 

The temporary root directory to be used to check out revisions (optional). 
The default is F</tmp>.

=item B<-D> 

Debug: Enable verbose logging and do not delete the temporary check-out directory
(optional).

=back

=head2 Supported test criteria and default search budgets:

B<branch> => 100s, B<weakmutation> => 100s, B<strongmutation> => 200s

=cut
my %criteria = ( branch         => 100, 
                 weakmutation   => 100,
                 strongmutation => 200
               );

=pod 

=head2 EvoSuite Configuration File

The filename of an optional EvoSuite configuration file can be provided with the
environment variable EVO_CONFIG_FILE. The default configuration file of EvoSuite 
is: F<framework/util/evo.config>.

=head1 DESCRIPTION

This script performs the following three tasks:

=over 4

=item 1) Checkout project version to F<tmp_dir>.

=item 3) Compile project classes.

=item 4) Run EvoSuite and generate tests for all modified classes.

=back

=cut
use strict;
use warnings;

use FindBin;
use File::Basename;                                                              
use Cwd qw(abs_path);                                                            
use Getopt::Std;
use Pod::Usage;
                               
use lib abs_path("$FindBin::Bin/../core");
use Constants;
use Utils;
use Project;
use Log;


#
# Process arguments and issue usage message if necessary.
#
my %cmd_opts;
getopts('p:v:o:n:t:c:b:a:D', \%cmd_opts) or pod2usage(1);

pod2usage(1) unless defined $cmd_opts{p} and 
                    defined $cmd_opts{v} and
                    defined $cmd_opts{n} and
                    defined $cmd_opts{o} and 
                    defined $cmd_opts{c}; 
my $PID = $cmd_opts{p};
my $VID = $cmd_opts{v};
$VID =~ /^(\d+)[bf]$/ or die "Wrong version_id format (\\d+[bf]): $VID!";
# Remove suffix to obtain bug id
my $BID = $1;
my $TID = $cmd_opts{n};
$TID =~ /^\d+$/ or die "Wrong test_id format (\\d+): $TID!";
my $OUT_DIR = $cmd_opts{o};
my $CRITERION = $cmd_opts{c};
my $BUDGET = $cmd_opts{b};
my $TIMEOUT = $cmd_opts{a} // 300;

# Validate criterion and set search budget
my $default = $criteria{$CRITERION};
unless (defined $default) {
    die "Unknown criterion: $CRITERION!";
}    
$BUDGET = $BUDGET // $default;
# Enable debugging if flag is set
$DEBUG = 1 if defined $cmd_opts{D};

# Instantiate project and set working directory
my $project = Project::create_project($PID);

# List of modified classes
my $MOD_CLASSES = "$SCRIPT_DIR/projects/$PID/modified_classes/$BID.src";

# Temporary directory for project checkout
my $TMP_DIR = Utils::get_tmp_dir($cmd_opts{t}); 
system("mkdir -p $TMP_DIR");

$project->{prog_root} = $TMP_DIR;

=pod

=head2 Logging

By default, the script logs all errors and warnings to run_evosuite.log in
the temporary project root.

Upon success, the log file of this script is appended to:
F<"out_dir"/"project_id"/"vid"/logs/"project_id"."version_id".log>.
    
=cut
# Log file in output directory
my $LOG_DIR = "$OUT_DIR/logs";
my $LOG_FILE = "$LOG_DIR/$PID.$VID.log";
system("mkdir -p $LOG_DIR");

# Checkout and compile project
$project->checkout_id($VID) == 0 or die "Cannot checkout!";
$project->compile() == 0 or die "Cannot compile!";

# Open temporary log file
my $LOG = Log::create_log("$TMP_DIR/run_evosuite.log");

$LOG->log_time("Start test generation");

open(LIST, "<$MOD_CLASSES") or die "Could not open list of classes $MOD_CLASSES: $!";
my @classes = <LIST>;
close(LIST);
# Iterate over all modified classes
my $log = "$TMP_DIR/$PID.$VID.$CRITERION.$TID.log";
foreach my $class (@classes) {
    chomp $class;
    $LOG->log_msg("Generate tests for: $class : $CRITERION : ${BUDGET}s");
    # Call evosuite with criterion, time, and class name
    my $config = "$UTIL_DIR/evo.config";
    # Set config to environment variable if defined
    $config = $ENV{EVO_CONFIG_FILE} // $config;

    $project->run_evosuite($CRITERION, $BUDGET, $class, $TIMEOUT, $config, $log) == 0 or die "Failed to generate tests!";
}
# Copy log file for this version id and test criterion to output directory
system("mv $log $LOG_DIR") == 0 or die "Cannot copy log file!";
# Compress generated tests and copy archive to output directory
my $archive = "$PID-$VID-evosuite-$CRITERION.$TID.tar.bz2";
if (system("tar -cjf $TMP_DIR/$archive -C $TMP_DIR/evosuite-$CRITERION/ .") != 0) {
    $LOG->log_msg("Error: cannot compress test suites!");
    next;
}
# Move test suite to OUT_DIR/pid/suite_src/test_id
#
# e.g., .../Lang/evosuite-branch/1
#
my $dir = "$OUT_DIR/$PID/evosuite-$CRITERION/$TID";
system("mkdir -p $dir && mv $TMP_DIR/$archive $dir") == 0 or die "Cannot copy test suite archive to output directory!";

$LOG->log_time("End test generation");

# Close temporary log and append content to log file in output directory
$LOG->close();
system("cat $LOG->{file_name} >> $LOG_FILE");

# Remove temporary directory
system("rm -rf $TMP_DIR") unless $DEBUG;

=pod

=head1 AUTHORS

Rene Just

=head1 SEE ALSO

All valid project_ids are listed in F<Project.pm>

=cut