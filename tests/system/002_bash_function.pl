#!/usr/bin/perl
use strict;

print STDERR "$0 - ";

my $REGEX_UNIQUE_ID = '\[[0-9]{6}\.[0-9]{4}\.[0-9]+\.[^\]]+\]';
my $REGEX_TIME = '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}';
my $REGEX_ELAPSE = '\(elapsed: [^)]+\)';

#==========================================================#

sub test_001
{
	# prepare input
	open my $fh, ">foo.pipe" or die;
	print $fh 'hello() {
	echo "Hello, world!"
	echo "Goodbye!"
}
';
	close $fh;

	# run command
	my $output = `seqpipe foo.pipe hello` or die;

	# check results
	my @lines = split("\n", $output);
	die if scalar @lines != 11;
	die if $lines[0] !~ /^$REGEX_UNIQUE_ID seqpipe foo.pipe hello$/;
	die if $lines[1] !~ /^\(1\) \[pipeline\] hello$/;
	die if $lines[2] !~ /^\(1\) starts at ${REGEX_TIME}$/;
	die if $lines[3] !~ /^  \(2\) \[shell\] echo 'Hello, world!'$/;
	die if $lines[4] !~ /^  \(2\) starts at ${REGEX_TIME}$/;
	die if $lines[5] !~ /^  \(2\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[6] !~ /^  \(3\) \[shell\] echo 'Goodbye!'$/;
	die if $lines[7] !~ /^  \(3\) starts at ${REGEX_TIME}$/;
	die if $lines[8] !~ /^  \(3\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[9] !~ /^\(1\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[10] !~ /^$REGEX_UNIQUE_ID Pipeline finished successfully! $REGEX_ELAPSE$/;

	die if `cat .seqpipe/last/log` ne $output;
	die if `cat .seqpipe/last/pipeline` ne "hello() {\n\techo 'Hello, world!'\n\techo 'Goodbye!'\n}\n\nhello\n";
	die if `cat .seqpipe/last/1.hello.call` ne "hello\n";
	die if `cat .seqpipe/last/2.echo.cmd` ne "echo 'Hello, world!'\n";
	die if `cat .seqpipe/last/2.echo.log` ne "Hello, world!\n";
	die if `cat .seqpipe/last/2.echo.err` ne "";
	die if `cat .seqpipe/last/3.echo.cmd` ne "echo 'Goodbye!'\n";
	die if `cat .seqpipe/last/3.echo.log` ne "Goodbye!\n";
	die if `cat .seqpipe/last/3.echo.err` ne "";
}
test_001;

#==========================================================#

sub test_002
{
	# prepare input
	open my $fh, ">>foo.pipe" or die;
	print $fh "hello\n";
	close $fh;

	# run command
	my $output = `seqpipe foo.pipe` or die;

	# check results
	my @lines = split("\n", $output);
	die if scalar @lines != 11;
	die if $lines[0] !~ /^$REGEX_UNIQUE_ID seqpipe foo.pipe$/;
	die if $lines[1] !~ /^\(1\) \[pipeline\] hello$/;
	die if $lines[2] !~ /^\(1\) starts at ${REGEX_TIME}$/;
	die if $lines[3] !~ /^  \(2\) \[shell\] echo 'Hello, world!'$/;
	die if $lines[4] !~ /^  \(2\) starts at ${REGEX_TIME}$/;
	die if $lines[5] !~ /^  \(2\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[6] !~ /^  \(3\) \[shell\] echo 'Goodbye!'$/;
	die if $lines[7] !~ /^  \(3\) starts at ${REGEX_TIME}$/;
	die if $lines[8] !~ /^  \(3\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[9] !~ /^\(1\) ends at ${REGEX_TIME} ${REGEX_ELAPSE}$/;
	die if $lines[10] !~ /^$REGEX_UNIQUE_ID Pipeline finished successfully! $REGEX_ELAPSE$/;

	die if `cat .seqpipe/last/log` ne $output;
	die if `cat .seqpipe/last/pipeline` ne "hello() {\n\techo 'Hello, world!'\n\techo 'Goodbye!'\n}\n\nhello\n";
	die if `cat .seqpipe/last/1.hello.call` ne "hello\n";
	die if `cat .seqpipe/last/2.echo.cmd` ne "echo 'Hello, world!'\n";
	die if `cat .seqpipe/last/2.echo.log` ne "Hello, world!\n";
	die if `cat .seqpipe/last/2.echo.err` ne "";
	die if `cat .seqpipe/last/3.echo.cmd` ne "echo 'Goodbye!'\n";
	die if `cat .seqpipe/last/3.echo.log` ne "Goodbye!\n";
	die if `cat .seqpipe/last/3.echo.err` ne "";
}
test_002;

#==========================================================#

sub clean_up
{
	unlink "foo.pipe";
}
clean_up;

#==========================================================#
print "OK!\n";
exit 0;