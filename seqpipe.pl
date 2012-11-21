#!/usr/bin/perl -w
use strict;
use warnings;
use File::Basename;
use File::stat;
use Cwd 'abs_path';
use Fcntl qw(:flock);
use File::Temp qw/tempfile/;

############################################################
# Check perl multi-thread supporting
my $can_use_threads = exists $INC{"forks.pm"} or exists $INC{"threads.pm"};

############################################################
# All logs are saved into this directory.
use constant UNIQ_ID => sprintf('%02d%02d%02d.%d', (localtime)[5] % 100, (localtime)[4] + 1, (localtime)[3], $$);
use constant LOG_ROOT => './.seqpipe';
use constant LOG_DIR => LOG_ROOT . '/' . UNIQ_ID;
use constant APP_ROOT => dirname abs_path $0;
use constant DEF_PIPE => APP_ROOT . '/default.pipe';

############################################################
# Command line parsing results.
my $help_mode = 0;      # 1 - show help; 2 - show detail help
my $list_mode = 0;      # 1 - list procedures; 2 - list all procedures (include internal ones)
my $show_mode = 0;
my $keep_temps = 0;
my $exec_cmd = '';
my $shell = '/bin/bash';
my @files = glob(APP_ROOT . '/*.pipe');  # All *.pipe files in SeqPipe install directory will be loaded automatically.

my $obsolete_warned = 0;
my $max_thread_number = 2;
my $thread_number :shared = 0;

# All procedures are loaded at startup.
my %proc_list = ();
my @blocks = ();

# Global variables (which are defined outside procedures in .pipe files).
my %global_vars = ();

# Count how many shell commands have run so far.
my $run_counter :shared = 0;

# Flag for exiting (when received KILL signal like Ctrl+C, or met failure).
my $exiting :shared = 0;

# Command line entered by user.
my $command_line = bash_line_encode(dirname(abs_path($0)) . '/seqpipe', @ARGV);

############################################################

sub init_config
{
	if (not -e APP_ROOT . '/config.inc') {
		if (-e APP_ROOT . '/config.inc.tpl') {
			system('cp ' . APP_ROOT . '/config.inc.tpl ' . APP_ROOT . '/config.inc');
		}
	} else {
		my %vars = ();
		my @variable_list = ();
		open FILE, APP_ROOT . '/config.inc.tpl' or return;
		while (my $line = <FILE>) {
			chomp $line;
			if ($line =~ /^\s*(\w+)=(.*)$/) {
				my ($name, $value) = ($1, $2);
				$vars{$name} = $value;
				push @variable_list, $name;
			}
		}
		close FILE;

		my @lines = ();
		open FILE, APP_ROOT . '/config.inc' or return;
		while (my $line = <FILE>) {
			chomp $line;
			if ($line =~ /^\s*(\w+)=(.*)$/) {
				my ($name, $value) = ($1, $2);
				if (exists $vars{$name}) {
					delete $vars{$name};
				} else {
					$line =~ s/=(.*)/=$value/;
				}
			}
			push @lines, $line;
		}
		close FILE;
		foreach my $name (@variable_list) {
			if (exists $vars{$name}) {
				push @lines, "$name=$vars{$name}";
			}
		}

		open FILE, '>' . APP_ROOT . '/config.inc' or return;
		foreach my $line (@lines) {
			print FILE "$line\n";
		}
		close FILE;
	}
}

############################################################
# Time display helper functions

sub time_string
{
	my ($sec, $min, $hour, $mday, $mon, $year) = localtime shift;
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $year + 1900, $mon + 1, $mday, $hour, $min, $sec);
}

sub time_elapse_string
{
	my ($start_time, $end_time) = @_;
	my $elapsed_time = $end_time - $start_time;
	my $time_elapse_text = '';
	if ($elapsed_time >= 86400) {
		$time_elapse_text .= int($elapsed_time / 86400) . 'd ';
		$elapsed_time %= 86400;
	}
	if ($time_elapse_text or $elapsed_time >= 3600) {
		$time_elapse_text .= int($elapsed_time / 3600) . 'h ';
		$elapsed_time %= 3600;
	}
	if ($time_elapse_text or $elapsed_time >= 60) {
		$time_elapse_text .= int($elapsed_time / 60) . 'm ';
		$elapsed_time %= 60;
	}
	if ($time_elapse_text eq '' or $elapsed_time > 0) {
		$time_elapse_text .= $elapsed_time . 's ';
	}
	$time_elapse_text =~ s/\s$//g;
	return $time_elapse_text;
}

############################################################

sub log_print
{
	flock LOG_FILE, LOCK_EX;
	print LOG_FILE @_;
	flock LOG_FILE, LOCK_UN;
}

sub log_printf
{
	flock LOG_FILE, LOCK_EX;
	printf LOG_FILE @_;
	flock LOG_FILE, LOCK_UN;
}

############################################################
# Catch signals for KILL, Ctrl+C, etc.

sub kill_signal_handler
{
	lock($exiting);
	$exiting = 1;

	my $now = time_string time;
	log_print "ERROR: [$now] got KILL signal!\n";
}

sub set_kill_signal_handler
{
	$SIG{'INT'} = \&kill_signal_handler;
	$SIG{'ABRT'} = \&kill_signal_handler;
	$SIG{'QUIT'} = \&kill_signal_handler;
	$SIG{'TERM'} = \&kill_signal_handler;
}

############################################################

sub get_new_run_id
{
	lock($run_counter);
	$run_counter++;
	return $run_counter;
}

############################################################

sub bash_line_encode
{
	my @argv = @_;
	foreach my $arg (@argv) {
		$arg =~ s/\'/\'\\\'\'/g;
		if ($arg =~ /[\s|><]/) {
			if ($arg =~ /^(\w+)=(.*)$/) {
				$arg = "$1='$2'";
			} else {
				$arg = "'" . $arg . "'";
			}
		} elsif ($arg =~ /^(\w+)=$/) {
			$arg = "$1=\'\'";
		}
	}
	return join(' ', @argv);
};

sub remove_tailing_comment
{
	my ($line) = @_;

	# Split to bash command and tailing comment.
	return undef if $line !~ /^(("(\\.|[^"])*"|'[^']*'|[^\s#][^\s'"]*|\\.|\s+)*)(#.*|)$/;
	my $cmd = $1;
	my $rest = $4;

	# Return the comment if no bash command
	$cmd =~ s/^\s*//g;
	$cmd =~ s/\s*$//g;
	$cmd = $rest if $cmd eq '' and $rest;

	return $cmd;
}

sub remove_comment
{
	my $cmd = remove_tailing_comment @_;
	$cmd = '' if $cmd =~ '^#';
	return $cmd;
}

sub bash_line_decode
{
	my ($cmd) = @_;

	$cmd = remove_comment($cmd);
	die 'Bad bash line!' if not defined $cmd;

	# Split bash command line to @argv.
	my @argv = ();
	while ($cmd =~ /(("(\\.|[^"])*"|'[^']*'|[^\s#][^\s'"]*|\\.)+)/g) {
		push @argv, $1;
	}

	# Process quot strings.
	foreach my $arg (@argv) {
		my $result = '';
		while ($arg =~ /("((\\.|[^"])*)"|'([^']*)'|([^\s'"]+))/g) {
			my $part = '';
			if (defined $2) {
				$part = $2;
				$part =~ s/\\(.)/$1/g;
			} elsif (defined $4) {
				$part = $4;
			} elsif (defined $5) {
				$part = $5;
			}
			$result .= $part;
		}
		$arg = $result;
	}
	return @argv;
}

############################################################

sub add_dep
{
	my ($name, $dep, $deps_ref) = @_;
	$deps_ref->{$name} = {} if not exists $deps_ref->{$name};
	$deps_ref->{$name}{$dep} = 1;
}

sub has_dep
{
	my ($name, $dep, $deps_ref, $indent) = @_;
	$indent = '' if not defined $indent;

	if ($name ne $dep and exists $deps_ref->{$name}) {
		return 1 if exists $deps_ref->{$name}{$dep};
		foreach my $sub (keys %{$deps_ref->{$name}}) {
			next if $sub eq $name;
			return 1 if has_dep($sub, $dep, $deps_ref, $indent . '  ');
		}
	}
	return 0;
}

############################################################

sub get_vars
{
	my ($args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	my %vars = ();
	foreach my $name (keys %{$args_ref}) {
		$vars{$name} = $args_ref->{$name};
	}
	foreach my $name (keys %{$proc_vars_ref}) {
		$vars{$name} = $proc_vars_ref->{$name} if not exists $vars{$name};
	}
	foreach my $name (keys %{$global_vars_ref}) {
		$vars{$name} = $global_vars_ref->{$name} if not exists $vars{$name};
	}
	return %vars;
}

sub get_vars_dep
{
	my %vars = @_;

	my %deps = ();
	foreach my $name (keys %vars) {
		while ($vars{$name} =~ /\${(\w+)}/g) {
			next if $name eq $1;           # Ignore self-dependency
			next if not exists $vars{$1};  # Ignore undefined variable
			die "ERROR: Cyclic-dependency between variables '$name' and '$1' detected!\n" if has_dep($1, $name, \%deps);
			$deps{$name} = {} if not exists $deps{$name};
			$deps{$name}{$1} = 1;
		}
	}
	return %deps;
}

sub sort_vars
{
	my ($vars_ref, $deps_ref) = @_;

	my %vars = %{$vars_ref};
	my @vars = ();
	search_again: while (%vars) {
		my $name = '';
		foreach (keys %vars) {
			next if exists $deps_ref->{$_};
			$name = $_;
			unshift @vars, $name;
			delete $vars{$name};
			delete $deps_ref->{$name};
			foreach my $dep (keys %{$deps_ref}) {
				my $sub_ref = $deps_ref->{$dep};
				delete $sub_ref->{$name} if exists $sub_ref->{$name};
				delete $deps_ref->{$dep} if not %{$sub_ref};
			}
			goto search_again;
		}
		last if $name eq '';
	}
	return @vars;
}

sub check_vars_info
{
	my ($opt_vars_ref, $req_vars_ref, $args_ref, $proc_vars_ref, $global_vars_ref, @texts) = @_;

	while (@texts) {
		my $text = shift @texts;
		while ($text =~ /\${(\w+)}/g) {
			next if exists $opt_vars_ref->{$1} or exists $req_vars_ref->{$1};
			if (exists $args_ref->{$1}) {
				push @texts, $opt_vars_ref->{$1} = $args_ref->{$1};
			} elsif (exists $proc_vars_ref->{$1}) {
				push @texts, $opt_vars_ref->{$1} = $proc_vars_ref->{$1};
			} elsif (exists $global_vars_ref->{$1}) {
				push @texts, $opt_vars_ref->{$1} = $global_vars_ref->{$1};
			} else {
				$req_vars_ref->{$1} = '';
			}
		}
	}
}

sub eval_text
{
	my ($text, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	$text = remove_comment($text);
	return '' if not defined $text;

	$text =~ s/^"(.*?)"$/$1/;  # Remove quot marks.

	my %opt_vars = ();
	my %req_vars = ();
	check_vars_info(\%opt_vars, \%req_vars, $args_ref, $proc_vars_ref, $global_vars_ref, $text);

	my %vars = ();
	foreach my $name (keys %opt_vars) {
		$vars{$name} = $opt_vars{$name};
	}
	foreach my $name (keys %req_vars) {
		$vars{$name} = "\${$name}";
	}

	my %deps = get_vars_dep %vars;
	my @order = sort_vars(\%vars, \%deps);

	foreach my $name (@order) {
		if ($text =~ /\${$name}/) {
			$text =~ s/\${$name}/$vars{$name}/g;
		}
	}
	return $text;
}

############################################################

sub check_vars_dep
{
	my ($args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	my %deps = ();
	foreach my $name (keys %{$args_ref}, keys %{$proc_vars_ref}, keys %{$global_vars_ref}) {
		my $value = '';
		if (exists $args_ref->{$name}) {
			$value = $args_ref->{$name};
		} elsif (exists $proc_vars_ref->{$name}) {
			$value = $proc_vars_ref->{$name};
		} elsif (exists $global_vars_ref->{$name}) {
			$value = $global_vars_ref->{$name};
		}
		
		while ($value =~ /\${(\w+)}/g) {
			my $dep = $1;
			die "ERROR: Cyclic-dependency between variables '$name' and '$dep' detected!\n" if has_dep($dep, $name, \%deps);
			add_dep($name, $dep, \%deps);
		}
	}
}

sub check_files_dep
{
	my ($requires_of_ref, $inputs_of_ref) = @_;

	my %deps = ();
	foreach my $file (keys %{$requires_of_ref}) {
		foreach my $dep (keys %{$requires_of_ref->{$file}}) {
			die "ERROR: Cyclic-dependency between files '$file' and '$dep' detected!\n" if has_dep($dep, $file, \%deps);
			add_dep($file, $dep, \%deps);
		}
	}
	foreach my $file (keys %{$inputs_of_ref}) {
		foreach my $dep (keys %{$inputs_of_ref->{$file}}) {
			die "ERROR: Cyclic-dependency between files '$file' and '$dep' detected!\n" if has_dep($dep, $file, \%deps);
			add_dep($file, $dep, \%deps);
		}
	}
}

############################################################

sub parse_cmd
{
	my ($proc_name, $command, $l, $file, $lines_ref, $commands_ref, $cmd_info_ref, $proc_info_ref) = @_;

	my $cmd_ref = { command => $command, requires => $cmd_info_ref->{requires},
		inputs => $cmd_info_ref->{inputs}, outputs => $cmd_info_ref->{outputs},
		saves => $cmd_info_ref->{saves}, temps => $cmd_info_ref->{temps}, line_info => $l->{info} };

	my @argv = bash_line_decode($command);
	if ($argv[0] =~ /^SP_/) {
		if ($argv[0] eq 'SP_set') {
			die 'ERROR: Invalid option for SP_set!' if $command !~ /^\s*SP_set\s+(\w+)=(.*)$/;
			$cmd_ref->{command} = 'SP_set';
			$cmd_ref->{variable} = $1;
			$cmd_ref->{text} = $2;
			check_vars_dep({}, {$1=>$2}, {}, $global_vars{$file});

		} elsif ($argv[0] eq 'SP_if') {
			$cmd_ref->{command} = 'SP_if';
			$cmd_ref->{condition} = [];
			if ($command =~ /^SP_if\s*(|!)\s*\((.*)\)\s*$/) {
				push @{$cmd_ref->{condition}}, { command => 'SP_if', negative => $1, bash => $2 };
			} elsif ($command =~ /^SP_if\s+(.*)\s*$/) {
				push @{$cmd_ref->{condition}}, { command => 'SP_if', text => $1 };
			} else {
				die 'ERROR: Invalid format of SP_if!';
			}
			
			my $l = shift @{$lines_ref};
			my $line = $l->{text};
			die "ERROR: Invalid format of SP_if in $l->{info}.\n" if $line !~ /^\s*(\{|\{\{)\s*$/;
			my $blocking = $1;
			push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, $proc_info_ref);
			$cmd_ref->{condition}[-1]{block} = scalar @blocks - 1;

			while (@{$lines_ref})
			{
				next if $lines_ref->[0]->{text} =~ /^\s*#.*$/;
				if ($lines_ref->[0]->{text} =~ /^\s*SP_else_if/) {
					$l = shift @{$lines_ref};
					my $line = $l->{text};
					if ($line =~ /^\s*SP_else_if\s*(|!)\s*\((.*)\)\s*$/) {
						push @{$cmd_ref->{condition}}, { command => 'SP_else_if', negative => $1, bash => $2 };
					} elsif ($line =~ /^\s*SP_else_if\s+(.*)\s*$/) {
						push @{$cmd_ref->{condition}}, { command => 'SP_else_if', text => $1 };
					} else {
						die 'ERROR: Invalid format of SP_else_if!';
					}

					$l = shift @{$lines_ref};
					$line = $l->{text};
					die "ERROR: Invalid format of SP_else_if in $l->{info}.\n" if $line !~ /^\s*(\{|\{\{)\s*$/;
					$blocking = $1;
					push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, $proc_info_ref);
					$cmd_ref->{condition}[-1]{block} = scalar @blocks - 1;

				} elsif ($lines_ref->[0]->{text} =~ /^\s*SP_else\s*$/) {
					shift @{$lines_ref};
					$l = shift @{$lines_ref};
					my $line = $l->{text};
					die 'ERROR: Invalid option for SP_else!' if $line !~ /^\s*(\{|\{\{)\s*$/;
					my $blocking = $1;
					push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, $proc_info_ref);
					$cmd_ref->{else_block} = scalar @blocks - 1;
					last;
				} else {
					last;
				}
			}
		} elsif ($argv[0] eq 'SP_for' or $argv[0] eq 'SP_for_parallel') {
			if ($command !~ /^\s*(SP_for(_parallel|))\s+(\w+)=(.*)$/) {
				die "ERROR: Invalid format for '$argv[0]'!";
			}
			$cmd_ref->{command} = $1;
			$cmd_ref->{variable} = $3;
			$cmd_ref->{text} = $4;
			die "ERROR: Variable of $cmd_ref->{command} should start with '_' in $l->{info}.\n" if $3 !~ /^_/;
			
			my $l = shift @{$lines_ref};
			my $line = $l->{text};
			die "ERROR: Invalid format of $cmd_ref->{command}!" if $line !~ /^\s*(\{|\{\{)\s*$/;
			my $blocking = $1;
			push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, $proc_info_ref);
			$cmd_ref->{block} = scalar @blocks - 1;

		} elsif ($argv[0] eq 'SP_while') {
			die 'ERROR: Invalid option for SP_while!' if $command !~ /^\s*SP_while\s*(|!)\s*\((.*)\)\s*$/;
			$cmd_ref->{command} = 'SP_while';
			$cmd_ref->{negative} = $1;
			$cmd_ref->{bash} = $2;
			
			my $l = shift @{$lines_ref};
			my $line = $l->{text};
			die 'ERROR: Invalid format of SP_while!' if $line !~ /^\s*(\{|\{\{)\s*$/;
			my $blocking = $1;
			push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, $proc_info_ref);
			$cmd_ref->{block} = scalar @blocks - 1;

		} elsif ($argv[0] eq 'SP_run') {
			$cmd_ref->{command} = shift @argv;
			$cmd_ref->{proc_name} = shift @argv;
			die 'ERROR: Invalid option for SP_run!' if $cmd_ref->{proc_name} !~ /^\w+$/;
			$cmd_ref->{options} = {};
			for my $opt (@argv) {
				die 'ERROR: Invalid option for SP_run!' . $opt if $opt !~ /^(\w+)=(.*)$/;
				die 'ERROR: Duplicate option for SP_run!' . $opt if exists $cmd_ref->{options}{$1};
				$cmd_ref->{options}{$1} = $2;
				my $name = $1;
				die "ERROR: Invalid option '$name'! Option name starts with '_' is reserved!\n" if $name =~ /^_/;
			}
		} else {
			die "ERROR: Invalid primitive line '$argv[0]'!\n";
		}
	}

	return $cmd_ref;
}

sub create_cmd_info
{
	return ( requires => {}, inputs => {}, outputs => {}, saves => {}, temps => {} );
}

sub parse_block
{
	my ($proc_name, $blocking, $file, $lines_ref, $proc_info_ref) = @_;

	my $line = '';
	my $last_line = '';
	my @commands = ();
	my %cmd_info = create_cmd_info();

	while (1) {
		if (scalar @{$lines_ref} <= 0) {
			die "ERROR: Invalid procedure declaration! Line '}' or '}}' expected!";
		}
		my $l = shift @{$lines_ref};
		my $line = $l->{text};
		if ($line =~ /^\s*(\}|\}\}|SP_parallel_end)\s*(|#.*)$/) {
			if ($blocking eq '{') {
				last if $1 eq '}';
				die "ERROR: Unmatched curly bracket! Line '}' expected!";
			}
			if ($blocking eq '{{') {
				last if $1 eq '}}' or $1 eq 'SP_parallel_end';
				die "ERROR: Unmatched curly bracket! Line '}}' expected!";
			}
		} elsif ($line =~ /^\s*(\{|\{\{|SP_parallel_begin)\s*(|#.*)$/) {
			my $sub_blocking = $1;
			if ($sub_blocking eq 'SP_parallel_begin') {
				if (not $obsolete_warned) {
					print "WARNING: Obsolete 'SP_parallel_begin' or 'SP_parallel_end' in $l->{info}.\n";
					print "   NOTE: Please use '{{' or '}}' instead.\n";
					$obsolete_warned = 1;
				}
				$sub_blocking = '{{';
			}
			push @blocks, parse_block($proc_name, $sub_blocking, $file, $lines_ref, $proc_info_ref);
			my $block_index = scalar @blocks - 1;
			push @commands, { command => '', block => $block_index, requires => {}, inputs => {}, outputs => {}, saves => {}, temps => {} };
			next;
		}

		$line = remove_tailing_comment($line);
		print "Parse failed!" if not defined $line;

		if ($last_line eq '') {
			$line =~ s/^\s+//g;
		} else {
			my $b1 = $last_line =~ s/\s+$//g;
			my $b2 = $line =~ s/^\s+//g;
			$line = $last_line . (($b1 or $b2) ? ' ' : '') . $line;
			$last_line = '';
		}

		if ($line =~ s/\\$//) {
			$last_line = $line;
		} elsif ($line =~ /^#/) {
			if ($line =~ /^#\[/) {
				die "ERROR: Invalid format of command attribute declaration in $l->{info}.\n"
					if $line !~ /^#\[(command\s+|)([\w\.]+)="[^"]*"(\s+([\w\.]+)="[^"]*")*\]$/;

				if ($1 =~ /^command\s+$/ and not $obsolete_warned) {
					print "WARNING: Obsolete format of command attribute in $l->{info}.\n";
					print "   NOTE: Please use '#[attr=\"...\"] instead of '#[command attr=\"...\" ...]'.\n";
					$obsolete_warned = 1;
				}
				while ($line =~ /([\w\.]+)="(.*?)"/g) {
					if ($1 eq 'require') {
						if (exists $cmd_info{requires}{$2} or exists $cmd_info{inputs}{$2} or exists $cmd_info{outputs}{$2}) {
							die "ERROR: Duplicated attribute for require file '$2'!";
						}
						$cmd_info{requires}{$2} = 1;
					} elsif ($1 eq 'input') {
						if (exists $cmd_info{requires}{$2} or exists $cmd_info{inputs}{$2} or exists $cmd_info{outputs}{$2}) {
							die "ERROR: Duplicated attribute for input file '$2'!";
						}
						$cmd_info{inputs}{$2} = 1;
					} elsif ($1 eq 'output' or $1 eq 'output.temp' or $1 eq 'output.save') {
						if (exists $cmd_info{requires}{$2} or exists $cmd_info{inputs}{$2} or exists $cmd_info{outputs}{$2}) {
							die "ERROR: Duplicated attribute for output file '$2'!";
						}
						$cmd_info{outputs}{$2} = 1;
						$cmd_info{saves}{$2} = 1 if $1 eq 'output.save';
						$cmd_info{temps}{$2} = 1 if $1 eq 'output.temp';
					} else {
						die "ERROR: Unknown command attribute '$1' in $l->{info}.\n";
					}
				}
			}
		} elsif ($line) {
			my $cmd_ref = parse_cmd($proc_name, $line, $l, $file, $lines_ref, \@commands, \%cmd_info, $proc_info_ref);

			push @commands, $cmd_ref;
			if (keys %{$cmd_info{saves}}) {
				foreach my $file (keys %{$cmd_info{saves}}) {
					$proc_info_ref->{saves}{$file} = '';
				}
			}
			if (keys %{$cmd_info{temps}}) {
				foreach my $file (keys %{$cmd_info{temps}}) {
					$proc_info_ref->{temps}{$file} = '';
				}
			}
			if (keys %{$cmd_info{outputs}}) {
				foreach my $file (keys %{$cmd_info{outputs}}) {
					$proc_info_ref->{outputs}{$file} = '';
				}
			}
			foreach my $output (keys %{$cmd_info{outputs}}) {
				@{$proc_info_ref->{requires_of}{$output}} = keys %{$cmd_info{requires}};
				@{$proc_info_ref->{inputs_of  }{$output}} = keys %{$cmd_info{inputs  }};
			}
			%cmd_info = create_cmd_info();
		}
	}
	if ($last_line) {
		die 'ERROR: Invalid procedure declaration! Last command line not finished!';
	}

	return { proc_name => $proc_name,
		requires => $proc_info_ref->{requires},
		inputs => $proc_info_ref->{inputs},
		outputs => $proc_info_ref->{outputs},
		commands => \@commands,
		parallel => ($blocking eq '{{' ? 1 : 0),
		file => $file };
}

sub load_lines
{
	my ($file, $loaded_ref, $including_ref) = @_;
	my @lines = ();

	if (not exists $loaded_ref->{$file}) {

		open my $handle, $file or die join("\n\t",
			("ERROR: Can't open file '$file', which is included by:", @{$including_ref})) . "\nFailed";
		$loaded_ref->{$file} = 1;

		my $line_no = 0;
		while (my $line = <$handle>) {
			chomp $line;
			$line_no++;

			if ($line =~ /^\s*(SP_include|\.)\s+(.*)$/) { # Process file including
				my $inc_file = $2;
				$inc_file = dirname($file) . '/' . $inc_file unless $inc_file =~ /^\//;
				push @lines, load_lines(abs_path($inc_file), $loaded_ref, [ "$file($line_no)", @{$including_ref} ]);
			} else {
				push @lines, { text => $line, info => "$file($line_no)" };
			}
		}
		close $handle;
	}
	return @lines;
}

sub create_proc_info
{
	return ( requires_of => {}, inputs_of => {}, requires => {}, inputs => {}, outputs => {}, saves => {}, temps => {} );
}

sub parse_proc
{
	my ($file, $lines_ref) = @_;
	my %requires = ();
	my %inputs = ();
	my %outputs = ();
	my $met_proc = 0;

	while (@{$lines_ref}) {
		my $l = shift @{$lines_ref};

		if ($l->{text} =~ /^\s*#/) {
			if ($l->{text} =~ /^\s*#\[/) {
				next if $l->{text} =~ /^#\[(seqpipe|version)/;
				die "ERROR: Invalid format of procedure attribute declaration in $l->{info}.\n"
					if $l->{text} !~ /^#\[(procedure\s+|)([\w\.]+)="[^"]*"(\s+([\w\.]+)="[^"]*")*\]$/;

				if ($1 =~ /^procedure\s+$/ and not $obsolete_warned) {
					print "WARNING: Obsolete format of procedure attribute in $l->{info}.\n";
					print "   NOTE: Please use '#[attr=\"...\"] instead of '#[procedure attr=\"...\" ...]'.\n";
					$obsolete_warned = 1;
				}
				while ($l->{text} =~ /([\w\.]+)="[^"]*"/g) {
					if ($1 eq 'type') {
						print "WARNING: Obsolete procedure attribute 'type' in $l->{info}.\n" if not $obsolete_warned;
						$obsolete_warned = 1;
					} elsif ($1 eq 'require') {
						if (exists $requires{$2} or exists $inputs{$2} or exists $outputs{$2}) {
							die "ERROR: Duplicated attribute for require file '$2' in $l->{info}.\n";
						}
						$requires{$2} = 1;
					} elsif ($1 eq 'input') {
						if (exists $requires{$2} or exists $inputs{$2} or exists $outputs{$2}) {
							die "ERROR: Duplicated attribute for input file '$2' in $l->{info}.\n";
						}
						$inputs{$2} = 1;
					} elsif ($1 eq 'output') {
						if (exists $requires{$2} or exists $inputs{$2} or exists $outputs{$2}) {
							die "ERROR: Duplicated attribute for output file '$2' in $l->{info}.\n";
						}
						$outputs{$2} = 1;
					} else {
						die "ERROR: Unknown procedure attribute '$1' in $l->{info}.\n";
					}
					next;
				}
			}
		} elsif ($l->{text} =~ /^\s*function\s+/) {
			die 'ERROR: Invalid procedure declaration!' if $l->{text} !~ /^function\s+(\w+)\s*(\{|\{\{|)\s*$/;
			my $proc_name = $1;
			my $blocking = $2;

			if (exists $proc_list{$proc_name}) {
				print "WARNING: Redeclaration of procedure '$proc_name' in $l->{info}.\n";
			}

			if ($blocking eq '') {
				while (1) {
					$l = shift @{$lines_ref};
					next if $l->{text} =~ /^\s*$/;
					if ($l->{text} =~ /^\s*(\{|\{\{)\s*$/) {
						$blocking = $1;
						last;
					}
					die "ERROR: Invalid procedure declaration! Line '{' or '{{' expected in $l->{info}.\n";
				}
			}
			$met_proc = 1;

			my %proc_info = create_proc_info();
			push @blocks, parse_block($proc_name, $blocking, $file, $lines_ref, \%proc_info);
			$proc_info{block} = scalar @blocks - 1;

			foreach my $file (keys %requires) {
				$proc_info{requires}{$file} = 1;
			}
			foreach my $file (keys %inputs) {
				$proc_info{inputs}{$file} = 1;
			}
			foreach my $file (keys %outputs) {
				$proc_info{outputs}{$file} = 1;
			}

			$proc_info{name} = $proc_name;
			$proc_info{file} = $file;
			$proc_list{$proc_name} = \%proc_info;

			%requires = ();
			%inputs = ();
			%outputs = ();

		} elsif ($l->{text} =~ /^\s*(\w+)=(.*)$/) {
			if ($met_proc) {
				print "WARNING: Global variables should be defined before procedures in $l->{info}.\n" if not $obsolete_warned;
				$obsolete_warned = 1;
			}

			my $name = $1;
			my $value = remove_comment($2);
			die "ERROR: Bad declaration format of global variable '$name' in $l->{info}.\n" if not defined $value;
			$value =~ s/^"(.*?)"$/$1/;  # Remove quot marks.
			if (exists $global_vars{$file}{$name}) {
				die "ERROR: Redeclaration of global variable '$name' in $l->{info}.\n";
			}
			$global_vars{$file}{$name} = $value;
			check_vars_dep({}, {}, {}, $global_vars{$file});
		}
	}
}

sub load_modules
{
	my ($files_ref, $args_ref) = @_;

	# Load procedure code of modules
	foreach my $file (@{$files_ref}) {
		if (not exists $global_vars{$file}) {
			$global_vars{$file} = { _SEQPIPE => 'seqpipe', _SEQPIPE_ROOT => APP_ROOT };
		}
		my @lines = load_lines($file, {}, []);
		while (@lines) {
			parse_proc($file, \@lines, $args_ref);
		}
		if (open my $file_handle, "$file.conf") {
			while (my $line = <$file_handle>) {
				chomp $line;
				$line = remove_comment($line);
				if ($line =~ /^\s*(\w+)=(.*)$/) {
					$global_vars{$file}{$1} = $2;
				}
			}
			close $file_handle;
		}
	}
}

sub print_usage
{
	print '
SeqPipe: a SEQuencing data analsysis PIPEline framework
Version: 0.4.5 ($Rev$)
Author : Linlin Yan (yanll<at>mail.cbi.pku.edu.cn)
Copyright: 2012, Centre for Bioinformatics, Peking University, China

Usage: seqpipe [options] <procedure> [NAME=VALUE ...]

Options:
   -h / -H     Show this or procedure usage. -H for more details.
   -m <file>   Load procedure module file, this option can be used many times.
   -l / -L     List current available proc_list. -L for all procedures (include internal ones).
   -T          Show the raw procedure declaration.
   -k          Keep intermediate files.
   -t <int>    Max thread number, 0 for unlimited. default: ' . $max_thread_number . '
   -e <cmd>    Inline mode, execute a bash command directly.
   -s <shell>  Send commands to another shell (such as "qsub_sync"), default: ' . $shell . '

';
	exit 1;
}

sub merge_vars_info
{
	my ($opt_vars_ref, $req_vars_ref, $sub_info_ref) = @_;

	foreach my $name (keys %{$sub_info_ref->{opt_vars}}) {
		next if exists $opt_vars_ref->{$name} or exists $req_vars_ref->{$name};
		$opt_vars_ref->{$name} = $sub_info_ref->{opt_vars}{$name};
	}
	foreach my $name (keys %{$sub_info_ref->{req_vars}}) {
		next if exists $opt_vars_ref->{$name} or exists $req_vars_ref->{$name};
		$req_vars_ref->{$name} = $sub_info_ref->{req_vars}{$name};
	}
}

sub add_dep_info
{
	my ($requires_of_ref, $inputs_of_ref, $outputs_ref, $saves_ref, $temps_ref,
		$args_ref, $proc_vars_ref, $global_vars_ref,
		$cmd_requires_ref, $cmd_inputs_ref, $cmd_outputs_ref, $cmd_saves_ref, $cmd_temps_ref) = @_;

	foreach my $output (keys %{$cmd_outputs_ref}) {
		my $output_result = eval_text($output, $args_ref, $proc_vars_ref, $global_vars_ref);
		next if $output_result eq '';
		next if exists $outputs_ref->{$output_result};
		$outputs_ref->{$output_result} = $output;
	}

	foreach my $save (keys %{$cmd_saves_ref}) {
		my $save_result = eval_text($save, $args_ref, $proc_vars_ref, $global_vars_ref);
		next if $save_result eq '';
		next if exists $saves_ref->{$save_result};
		$saves_ref->{$save_result} = $save;
	}

	foreach my $temp (keys %{$cmd_temps_ref}) {
		my $temp_result = eval_text($temp, $args_ref, $proc_vars_ref, $global_vars_ref);
		next if $temp_result eq '';
		next if exists $temps_ref->{$temp_result};
		$temps_ref->{$temp_result} = $temp;
	}

	foreach my $output (keys %{$cmd_outputs_ref}) {
		my $output_result = eval_text($output, $args_ref, $proc_vars_ref, $global_vars_ref);

		foreach my $require (keys %{$cmd_requires_ref}) {
			my $require_result = eval_text($require, $args_ref, $proc_vars_ref, $global_vars_ref);
			next if $require_result eq '';
			$requires_of_ref->{$output_result} = {} if not exists $requires_of_ref->{$output_result};
			$requires_of_ref->{$output_result}{$require_result} = $require;
		}

		foreach my $input (keys %{$cmd_inputs_ref}) {
			my $input_result = eval_text($input, $args_ref, $proc_vars_ref, $global_vars_ref);
			next if $input_result eq '';
			$inputs_of_ref->{$output_result} = {} if not exists $inputs_of_ref->{$output_result};
			$inputs_of_ref->{$output_result}{$input_result} = $input;
		}
	}
}

sub trace_dep
{
	my ($output_ref, $info_ref, $is_require) = @_;

	foreach my $output (keys %{$output_ref}) {
		if (exists $info_ref->{requires_of}{$output}) {
			my %items = ();
			foreach my $file (keys %{$info_ref->{requires_of}{$output}}) {
				if (not exists $info_ref->{requires}{$file}) {
					$info_ref->{requires}{$file} = $info_ref->{requires_of}{$output}{$file};
					$items{$file} = '';
				}
			}
			if (%items) {
				trace_dep(\%items, $info_ref, 1);
			}
		}
		if (exists $info_ref->{inputs_of}{$output}) {
			my %items = ();
			foreach my $file (keys %{$info_ref->{inputs_of}{$output}}) {
				if (defined $is_require and $is_require) {
					if (not exists $info_ref->{requires}{$file}) {
						$info_ref->{requires}{$file} = $info_ref->{inputs_of}{$output}{$file};
						$items{$file} = '';
					}
				} else {
					if (not exists $info_ref->{inputs}{$file}) {
						$info_ref->{inputs}{$file} = $info_ref->{inputs_of}{$output}{$file};
						$items{$file} = '';
					}
				}
			}
			if (%items) {
				trace_dep(\%items, $info_ref, $is_require);
			}
		}
	}
}

sub transform_vars
{
	my ($vars_ref, $options_ref) = @_;
	foreach my $name (keys %{$vars_ref}) {
		$vars_ref->{$name} = eval_text($vars_ref->{$name}, $options_ref, {}, {});
	}
}

sub transform_files
{
	my ($files_ref, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;
	my %results = ();
	foreach my $file (keys %{$files_ref}) {
		my $expand_one_level = eval_text($file, $options_ref, {}, {});
		my $expand_all_level = eval_text($expand_one_level, $args_ref, $proc_vars_ref, $global_vars_ref);
		$results{$expand_all_level} = $expand_one_level;
	}
	%{$files_ref} = %results;
}

sub transform_deps
{
	my ($deps_ref, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;
	my %results = ();
	foreach my $file (keys %{$deps_ref}) {
		my $file_expand_one_level = eval_text($file, $options_ref, {}, {});
		my $file_expand_all_level = eval_text($file_expand_one_level, $args_ref, $proc_vars_ref, $global_vars_ref);
		foreach my $dep (keys %{$deps_ref->{$file}}) {
			my $dep_expand_one_level = eval_text($dep, $options_ref, {}, {});
			my $dep_expand_all_level = eval_text($dep_expand_one_level, $args_ref, $proc_vars_ref, $global_vars_ref);
			$results{$file_expand_all_level} = {} if not exists $results{$file_expand_all_level};
			$results{$file_expand_all_level}{$dep_expand_all_level} = $dep_expand_one_level;
		}
	}
	%{$deps_ref} = %results;
}

sub transform_info
{
	my ($info_ref, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	transform_vars($info_ref->{opt_vars}, $options_ref);
	transform_vars($info_ref->{req_vars}, $options_ref);

	transform_files($info_ref->{requires}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
	transform_files($info_ref->{inputs}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
	transform_files($info_ref->{outputs}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
	transform_files($info_ref->{saves}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
	transform_files($info_ref->{temps}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);

	transform_deps($info_ref->{requires_of}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
	transform_deps($info_ref->{inputs_of}, $options_ref, $args_ref, $proc_vars_ref, $global_vars_ref);
}

sub check_block
{
	my ($block_ref, $args_ref, $proc_vars_ref) = @_;

	my %opt_vars = ();
	my %req_vars = ();
	my %requires_of = ();
	my %inputs_of = ();
	my %requires = ();
	my %inputs = ();
	my %outputs = ();
	my %saves = ();
	my %temps = ();

	my %proc_vars = %{$proc_vars_ref};
	my $global_vars_ref = $global_vars{$block_ref->{file}};

	foreach my $cmd_ref (@{$block_ref->{commands}}) {

		%proc_vars = %{$proc_vars_ref} if $block_ref->{parallel};

		if ($cmd_ref->{command} =~ /^SP_/) {
			if ($cmd_ref->{command} eq 'SP_set') {
				if (not exists $args_ref->{$cmd_ref->{variable}}) {
					$proc_vars{$cmd_ref->{variable}} = $cmd_ref->{text};
				}
			} elsif ($cmd_ref->{command} eq 'SP_run') {
				die "ERROR: Unknown procedure '$cmd_ref->{proc_name}' for SP_run in $cmd_ref->{line_info}.\n" if not exists $proc_list{$cmd_ref->{proc_name}};

				my @items = (values %{$cmd_ref->{options}}, keys %{$cmd_ref->{requires}}, keys %{$cmd_ref->{inputs}}, keys %{$cmd_ref->{outputs}}, keys %{$cmd_ref->{saves}}, keys %{$cmd_ref->{temps}});
				check_vars_info(\%opt_vars, \%req_vars, $args_ref, \%proc_vars, $global_vars_ref, @items);
				
				my %args = ();
				foreach my $name (keys %{$cmd_ref->{options}}) {
					$args{$name} = '${' . $name . '}';
				}
				my $info_ref = check_proc($proc_list{$cmd_ref->{proc_name}}, \%args, {}, $global_vars_ref);
				if (%{$info_ref->{req_vars}}) {
					die "ERROR: No enough variable(s) for SP_run '$cmd_ref->{proc_name}' in $cmd_ref->{line_info}:\n   " . join(', ', sort keys %{$info_ref->{req_vars}}) . "\n";
				}
				transform_info $info_ref, $cmd_ref->{options}, $args_ref, \%proc_vars, $global_vars_ref;
				
				foreach my $file (keys %{$cmd_ref->{requires}}) {
					my $file_result = eval_text($file, $args_ref, \%proc_vars, $global_vars_ref);
					if (not exists $info_ref->{requires}{$file_result}) {
						$info_ref->{requires}{$file_result} = $file;
					}
				}
				foreach my $file (keys %{$cmd_ref->{inputs}}) {
					my $file_result = eval_text($file, $args_ref, \%proc_vars, $global_vars_ref);
					if (not exists $info_ref->{inputs}{$file_result}) {
						$info_ref->{inputs}{$file_result} = $file;
					}
				}
				foreach my $file (keys %{$cmd_ref->{outputs}}) {
					my $file_result = eval_text($file, $args_ref, \%proc_vars, $global_vars_ref);
					if (not exists $info_ref->{outputs}{$file_result}) {
						$info_ref->{outputs}{$file_result} = $file;
					}
				}
				foreach my $file (keys %{$cmd_ref->{saves}}) {
					my $file_result = eval_text($file, $args_ref, \%proc_vars, $global_vars_ref);
					if (not exists $info_ref->{saves}{$file_result}) {
						$info_ref->{saves}{$file_result} = $file;
					}
				}
				foreach my $file (keys %{$cmd_ref->{temps}}) {
					my $file_result = eval_text($file, $args_ref, \%proc_vars, $global_vars_ref);
					if (not exists $info_ref->{temps}{$file_result}) {
						$info_ref->{temps}{$file_result} = $file;
					}
				}

				foreach my $output (keys %{$info_ref->{outputs}}) {
					$outputs{$output} = $info_ref->{outputs}{$output};

					foreach my $require (keys %{$info_ref->{requires}}) {
						$requires_of{$output} = {} if not exists $requires_of{$output};
						$requires_of{$output}{$require} = $info_ref->{requires}{$require};
					}
					foreach my $input (keys %{$info_ref->{inputs}}) {
						$inputs_of{$output} = {} if not exists $inputs_of{$output};
						$inputs_of{$output}{$input} = $info_ref->{inputs}{$input};
					}
				}

				foreach my $save (keys %{$info_ref->{saves}}) {
					$saves{$save} = $info_ref->{saves}{$save};
				}
				foreach my $temp (keys %{$info_ref->{temps}}) {
					$temps{$temp} = $info_ref->{temps}{$temp};
				}

			} elsif ($cmd_ref->{command} eq 'SP_if') {
				foreach my $cond_ref (@{$cmd_ref->{condition}}) {
					my @items = ();
					push @items, $cond_ref->{bash} if exists $cond_ref->{bash};
					push @items, $cond_ref->{text} if exists $cond_ref->{text};
					check_vars_info(\%opt_vars, \%req_vars, $args_ref, \%proc_vars, $global_vars_ref, @items);

					my $info_ref = check_block($blocks[$cond_ref->{block}], $args_ref, \%proc_vars);
					merge_vars_info \%opt_vars, \%req_vars, $info_ref;
				}
				if (exists $cmd_ref->{else_block}) {
					my $info_ref = check_block($blocks[$cmd_ref->{else_block}], $args_ref, \%proc_vars);
					merge_vars_info \%opt_vars, \%req_vars, $info_ref;
				}
			} elsif ($cmd_ref->{command} eq 'SP_for' or $cmd_ref->{command} eq 'SP_for_parallel') {
				$proc_vars{$cmd_ref->{variable}} = '';
				check_vars_info(\%opt_vars, \%req_vars, $args_ref, \%proc_vars, $global_vars_ref, $cmd_ref->{text});

				my $info_ref = check_block($blocks[$cmd_ref->{block}], $args_ref, \%proc_vars);
				merge_vars_info \%opt_vars, \%req_vars, $info_ref;
			} elsif ($cmd_ref->{command} eq 'SP_while') {
				check_vars_info(\%opt_vars, \%req_vars, $args_ref, \%proc_vars, $global_vars_ref, $cmd_ref->{bash});

				my $info_ref = check_block($blocks[$cmd_ref->{block}], $args_ref, \%proc_vars);
				merge_vars_info \%opt_vars, \%req_vars, $info_ref;
			}

		} elsif ($cmd_ref->{command} eq '') {
			my $info_ref = check_block($blocks[$cmd_ref->{block}], $args_ref, \%proc_vars);
			merge_vars_info \%opt_vars, \%req_vars, $info_ref;

			foreach my $file (keys %{$info_ref->{requires_of}}) {
				foreach my $dep (keys %{$info_ref->{requires_of}{$file}}) {
					$requires_of{$file}{$dep} = $info_ref->{requires_of}{$file}{$dep};
				}
			}
			foreach my $file (keys %{$info_ref->{inputs_of}}) {
				foreach my $dep (keys %{$info_ref->{inputs_of}{$file}}) {
					$inputs_of{$file}{$dep} = $info_ref->{inputs_of}{$file}{$dep};
				}
			}
			foreach my $file (keys %{$info_ref->{requires}}) {
				$requires{$file} = $info_ref->{requires}{$file};
			}
			foreach my $file (keys %{$info_ref->{inputs}}) {
				$inputs{$file} = $info_ref->{inputs}{$file};
			}
			foreach my $file (keys %{$info_ref->{outputs}}) {
				$outputs{$file} = $info_ref->{outputs}{$file};
			}
			foreach my $file (keys %{$info_ref->{saves}}) {
				$saves{$file} = $info_ref->{saves}{$file};
			}
			foreach my $file (keys %{$info_ref->{temps}}) {
				$temps{$file} = $info_ref->{temps}{$file};
			}
		} else {
			check_vars_info(\%opt_vars, \%req_vars, $args_ref, \%proc_vars, $global_vars_ref,
				$cmd_ref->{command}, keys %{$cmd_ref->{requires}},
				keys %{$cmd_ref->{inputs}}, keys %{$cmd_ref->{outputs}},
				keys %{$cmd_ref->{saves}}, keys %{$cmd_ref->{temps}});
			add_dep_info \%requires_of, \%inputs_of, \%outputs, \%saves, \%temps,
				$args_ref, \%proc_vars, $global_vars_ref,
				$cmd_ref->{requires}, $cmd_ref->{inputs}, $cmd_ref->{outputs}, $cmd_ref->{saves}, $cmd_ref->{temps};
		}
	}

	return { opt_vars => \%opt_vars, req_vars => \%req_vars, requires_of => \%requires_of, inputs_of => \%inputs_of,
		requires => \%requires, inputs => \%inputs, outputs => \%outputs, saves => \%saves, temps => \%temps };
}

sub remove_intermediate_outputs
{
	my ($info_ref) = @_;

	my %items = ();
	foreach my $output (keys %{$info_ref->{outputs}}) {
		if (exists $info_ref->{requires_of}{$output}) {
			@items{keys %{$info_ref->{requires_of}{$output}}} = '';
		}
		if (exists $info_ref->{inputs_of}{$output}) {
			@items{keys %{$info_ref->{inputs_of}{$output}}} = '';
		}
	}

	my $output_ref = $info_ref->{outputs};
	foreach my $file (keys %items) {
		if (exists $output_ref->{$file}) {
			delete $output_ref->{$file};
		}
	}
}

sub check_proc
{
	my ($proc_ref, $args_ref, $proc_vars_ref) = @_;

	my $global_vars_ref = $global_vars{$proc_ref->{file}};

	my $info_ref = check_block($blocks[$proc_ref->{block}], $args_ref, $proc_vars_ref);
	check_files_dep($info_ref->{requires_of}, $info_ref->{inputs_of});

	remove_intermediate_outputs $info_ref;
	trace_dep($info_ref->{outputs}, $info_ref);
	
	foreach my $file (keys %{$info_ref->{inputs}}) {
		if (exists $info_ref->{requires}{$file}) {
			delete $info_ref->{requires}{$file};
		}
	}
	foreach my $file (keys %{$info_ref->{requires}}) {
		if (exists $info_ref->{requires_of}{$file} or exists $info_ref->{inputs_of}{$file}) {
			delete $info_ref->{requires}{$file};
		}
	}
	foreach my $file (keys %{$info_ref->{inputs}}) {
		if (exists $info_ref->{requires_of}{$file} or exists $info_ref->{inputs_of}{$file}) {
			if (not exists $info_ref->{saves}{$file}) {
				$info_ref->{temps}{$file} = $info_ref->{inputs}{$file};
			}
			delete $info_ref->{inputs}{$file};
		}
	}
	foreach my $file (keys %{$info_ref->{saves}}) {
		$info_ref->{outputs}{$file} = $info_ref->{saves}{$file} if not exists $info_ref->{outputs}{$file};
		delete $info_ref->{temps}{$file} if exists $info_ref->{temps}{$file};
	}
	foreach my $file (keys %{$info_ref->{temps}}) {
		delete $info_ref->{outputs}{$file} if exists $info_ref->{outputs}{$file};
	}
	return $info_ref;
}

sub show_info
{
	my ($proc_name, $info_ref) = @_;
	
	print "\n";

	if (%{$info_ref->{req_vars}} or ($help_mode == 2 and %{$info_ref->{opt_vars}})) {
		print "Variables for " . ($proc_name ? "procedure '$proc_name'" : "inline command '$exec_cmd'") . ":\n";

		if (%{$info_ref->{req_vars}}) {
			foreach my $name (sort keys %{$info_ref->{req_vars}}) {
				printf "   %-30s  Required\n", $name;
			}
			print "\n";
		}

		if ($help_mode == 2 and %{$info_ref->{opt_vars}}) {
			foreach my $name (sort keys %{$info_ref->{opt_vars}}) {
				printf "   %-30s  Default: %s\n", $name, $info_ref->{opt_vars}{$name};
			}
			print "\n";
		}
	}

	my @text_list = ( 'Require', 'Input', 'Output', 'Temporary' );
	my @files_list = ( $info_ref->{requires}, $info_ref->{inputs}, $info_ref->{outputs}, $info_ref->{temps} );
	if ($help_mode != 2) {
		pop @text_list;
		pop @files_list;
	}
	while (@text_list) {
		my $msg = (shift @text_list) . " file(s):\n";
		my $files_ref = shift @files_list;
		if (%{$files_ref}) {
			print $msg;
			foreach my $file (sort keys %{$files_ref}) {
				my $text = $files_ref->{$file};
				if (length($file) > 30) {
					printf "   %s\n   %-30s  Definition: %s\n", $file, '', $text;
				} else {
					printf "   %-30s  Definition: %s\n", $file, $text;
				}
			}
			print "\n";
		}
	}
	exit 1;
}

sub list_proc
{
	my ($proc_name) = @_;
	print "\nCurrent available proc_list";
	print " (search for '$proc_name')" if $proc_name;
	print ":\n";
	foreach my $name (sort keys %proc_list) {
		next if $list_mode == 1 and $name =~ /^_/;
		print "   $name\n" if $name =~ /$proc_name/;
	}
	print "\n";
	exit 1;
}

sub show_block
{
	my ($block_ref, $indent, $args_ref) = @_;
	my %procedure = %{$block_ref};

	printf "$indent%s\n", ($procedure{parallel} ? '{{' : '{');

	my $block_start = 1;
	foreach my $cmd_ref (@{$procedure{commands}}) {

		if ($cmd_ref->{command} eq '{{' or %{$cmd_ref->{requires}} or %{$cmd_ref->{inputs}} or %{$cmd_ref->{outputs}}) {
			if (not $block_start and $cmd_ref->{command} ne 'SP_set') {
				print "\n";
			}

			foreach my $file (keys %{$cmd_ref->{requires}}) {
				print "$indent\t#[require=\"$file\"]\n";
			}
			foreach my $file (keys %{$cmd_ref->{inputs}}) {
				print "$indent\t#[input=\"$file\"]\n";
			}
			foreach my $file (keys %{$cmd_ref->{outputs}}) {
				print "$indent\t#[output";
				print '.temp' if exists $cmd_ref->{temps}{$file};
				print '.save' if exists $cmd_ref->{saves}{$file};
				print "=\"$file\"]\n";
			}
		}

		if ($cmd_ref->{command} eq '') {
			show_block($blocks[$cmd_ref->{block}], $indent . "\t", $args_ref);
		} elsif ($cmd_ref->{command} eq 'SP_set') {
			if (not exists $args_ref->{$cmd_ref->{variable}}) {
				print "$indent\tSP_set $cmd_ref->{variable}=$cmd_ref->{text}\n";
			}
		} elsif ($cmd_ref->{command} eq 'SP_run') {
			print "$indent\tSP_run $cmd_ref->{proc_name}";
			print " $_=$cmd_ref->{options}->{$_}" foreach (keys %{$cmd_ref->{options}});
			print "\n";
		} elsif ($cmd_ref->{command} eq 'SP_if') {
			foreach my $cond_ref (@{$cmd_ref->{condition}}) {
				if (exists $cond_ref->{bash}) {
					print "$indent\t$cond_ref->{command} $cond_ref->{negative}($cond_ref->{bash})\n";
				} else {
					print "$indent\t$cond_ref->{command} $cond_ref->{text}\n";
				}
				show_block($blocks[$cond_ref->{block}], $indent . "\t", $args_ref);
			}
			if (exists $cmd_ref->{else_block}) {
				print "$indent\tSP_else\n";
				show_block($blocks[$cmd_ref->{else_block}], $indent . "\t", $args_ref);
			}
		} elsif ($cmd_ref->{command} eq 'SP_for' or $cmd_ref->{command} eq 'SP_for_parallel') {
			print "$indent\t$cmd_ref->{command} $cmd_ref->{variable}=$cmd_ref->{text}\n";
			show_block($blocks[$cmd_ref->{block}], $indent . "\t", $args_ref);
		} elsif ($cmd_ref->{command} eq 'SP_while') {
			print "$indent\tSP_while $cmd_ref->{negative}($cmd_ref->{bash})\n";
			show_block($blocks[$cmd_ref->{block}], $indent . "\t", $args_ref);
		} else {
			print "$indent\t$cmd_ref->{command}\n";
		}
		$block_start = ($cmd_ref->{command} eq '{{');
	}

	printf "$indent%s\n", ($procedure{parallel} ? '}}' : '}');
}

sub show_proc
{
	my ($proc_name, $args_ref) = @_;

	print "#[require=\"$_\"]\n" for (keys %{$proc_list{$proc_name}{requires}});
	print "#[input=\"$_\"]\n" for (keys %{$proc_list{$proc_name}{inputs}});
	print "#[output=\"$_\"]\n" for (keys %{$proc_list{$proc_name}{outputs}});
	print "function $proc_name\n";

	show_block $blocks[$proc_list{$proc_name}{block}], '', $args_ref;
	exit 1;
}

sub check_files
{
	my ($info_ref, $indent) = @_;

	foreach my $require (keys %{$info_ref->{requires}}) {
		if (not -e $require) {
			log_print "ERROR: Required file '$require' does not exist!\n";
			return -1;
		}
	}

	foreach my $input (keys %{$info_ref->{inputs}}) {
		if (not -e $input) {
			log_print "ERROR: Input file '$input' does not exist!\n";
			return -1;
		}
	}
	
	if (%{$info_ref->{outputs}}) {
		foreach my $output (keys %{$info_ref->{outputs}}) {
			if (exists $info_ref->{requires}{$output} or exists $info_ref->{inputs}{$output}) {
				log_print "ERROR: Output file '$output' has also been defined as require or input!\n";
				return -1;
			}
			if (-e $output) {
				foreach my $input (keys %{$info_ref->{inputs}}) {
					if ((stat($input))->mtime > (stat($output))->mtime) {
						return 0;
					}
				}
			} else {
				my $output_dir = dirname $output;
				system 'mkdir', '-p', $output_dir unless -d $output_dir;
				return 0;
			}
		}
		return 1;
	} else {
		# Force to run pipeline if no any output file defined.
		return 0;
	}
}

sub save_cmd
{
	my ($cmd, $file) = @_;
	open FILE, ">>$file";
	print FILE "$cmd\n";
	close FILE;
}

sub run_shell
{
	my ($command, $procedure_type, $run_id, $indent) = @_;

	my $command_with_log = '';
	my $log_file = '';

	if ($procedure_type eq 'sysinfo') {
		$command_with_log = "($command) 2>&1 >>" . LOG_DIR . '/sysinfo';
	} elsif ($procedure_type eq 'checker') {
		my $name = LOG_DIR . "/$run_id.check";
		$command_with_log = "($command) >>/dev/null 2>>/dev/null";
		save_cmd $command, "$name.cmd";
	} elsif ($procedure_type eq 'evaluator') {
		if ($run_id == 0) {
			(undef, $log_file) = tempfile();
		} else {
			my $name = LOG_DIR . "/$run_id.eval";
			$log_file = "$name.result";
			save_cmd $command, "$name.cmd";
		}
		$command_with_log = "($command) >>$log_file 2>>/dev/null";
	} else {
		my @argv = bash_line_decode($command);
		my $name = '';
		while (@argv) {
			$name = basename shift @argv;
			$name =~ s/\W//g;
			last if $name;
		}
		if ($name eq '') {
			$name = 'shell';
		} else {
			while (@argv) {
				my $arg = shift @argv;
				last if $arg !~ /^\w+$/;
				$name .= "_$arg";
			}
		}
		$name = LOG_DIR . "/$run_id." . $name;
		$command_with_log = "($command) >>$name.log 2>>$name.err";
		save_cmd $command, "$name.cmd";
	}
	
	my $start_time = time;
	if ($procedure_type ne 'sysinfo' and $procedure_type ne 'checker' and $procedure_type ne 'evaluator') {
		log_print "$indent($run_id) [shell] $command\n";
		log_print "$indent($run_id) starts at " . time_string($start_time) . "\n";
	}
	
	if (not open BASH, "|$shell") {
		log_print "$indent($run_id) starts failed!\n";
		return undef;
	}
	print BASH $command_with_log;
	close BASH;
	if ($? == -1) {
		log_print "$indent($run_id) starts failed!\n";
		return undef;
	} elsif ($? & 127) {
		log_printf "$indent($run_id) starts failed! Child died with signal %d (%s coredump)\n",
			($? & 127), ($? & 128) ? 'with' : 'without';
		return undef;
	}
	my $ret = ($? >> 8);

	if ($procedure_type ne 'sysinfo' and $procedure_type ne 'checker' and $procedure_type ne 'evaluator') {
		my $end_time = time;
		log_printf "$indent($run_id) ends at %s (elapsed: %s)\n",
			time_string($end_time), time_elapse_string($start_time, $end_time);
	}
	return { ret => $ret, log_file => $log_file };
}

sub eval_text_in_shell
{
	my ($text, $indent, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	my $result = eval_text($text, $args_ref, $proc_vars_ref, $global_vars_ref);
	while (1) {
		# Following patterns require shell to eval
		last if $result =~ /\${\w+}/;
		last if $result =~ /\$\(\(.*\)\)/;
		last if $result =~ /{[0-9]+\.\.[0-9]+}/;
		last if $result =~ /{\S\.\.\S}/;
		last if $result =~ /\$\(.*\)/;
		last if $result =~ /\*/;
		last if $result =~ /\?/;
		return $result;
	}

	my $run_id = get_new_run_id;
	log_print "$indent($run_id) [eval] $text\n";
	my $ret_ref = run_shell("echo $result", 'evaluator', $run_id, $indent);
	return undef if not defined $ret_ref;

	open FILE, $ret_ref->{log_file} or return '';
	my @text = ();
	while (my $line = <FILE>) {
		chomp $line;
		push @text, $line;
	}
	close FILE;
	unlink $ret_ref->{log_file} if $run_id == 0;
	return join("\n", @text);
}

sub run_cmd
{
	my ($proc_name, $cmd_ref, $indent, $args_ref, $proc_vars_ref, $global_vars_ref) = @_;

	#   Since run_cmd may be started as in a new thread, copy the variable list
	# to record the changes, and after all return the copy to parent thread.
	my %proc_vars = %{$proc_vars_ref};
	my $ret = 0;

	{
		lock($exiting);
		return { ret => $ret, vars => \%proc_vars } if $exiting;
	}

	if ($cmd_ref->{command} eq 'SP_set') {
		my $name = $cmd_ref->{variable};
		if (not exists $args_ref->{$name}) {
			my $value = eval_text_in_shell($cmd_ref->{text}, $indent, $args_ref, \%proc_vars, $global_vars_ref);
			return undef if not defined $value;
			$proc_vars{$name} = $value;
		}

	} elsif ($cmd_ref->{command} eq 'SP_run') {
		my %options = %{$cmd_ref->{options}};
		foreach my $name (keys %options) {
			$options{$name} = eval_text_in_shell($options{$name}, $indent, $args_ref, \%proc_vars, $global_vars_ref);
		}
		$ret = run_proc($cmd_ref->{proc_name}, $indent, \%options);

	} elsif ($cmd_ref->{command} eq 'SP_if') {
		my $yes;
		my $cmd;
		my $run_id = get_new_run_id;
		foreach my $cond_ref (@{$cmd_ref->{condition}}) {
			if (exists $cond_ref->{bash}) {
				$cmd = "$cond_ref->{command} $cond_ref->{negative}($cond_ref->{bash})";
				my $cmd_result = eval_text($cond_ref->{bash}, $args_ref, \%proc_vars, $global_vars_ref);
				my $ret_ref = run_shell($cmd_result, 'checker', $run_id, $indent);
				return undef if not defined $ret_ref;
				$yes = ($ret_ref->{ret} == 0) ^ ($cond_ref->{negative} ne '');
			} else {
				$cmd = "$cond_ref->{command} $cond_ref->{text}";
				my $s = eval_text_in_shell($cond_ref->{text}, $indent, $args_ref, \%proc_vars, $global_vars_ref);
				return undef if not defined $s;
				$yes = ($s ne '');
			}
			log_print "$indent($run_id) $cmd returns '" . ($yes ? 'yes' : 'no') . "'\n";
			if ($yes) {
				$ret = run_block($blocks[$cond_ref->{block}], $indent, $args_ref, \%proc_vars);
				last;
			}
		}
		if (not $yes and exists $cmd_ref->{else_block}) {
			$ret = run_block($blocks[$cmd_ref->{else_block}], $indent, $args_ref, \%proc_vars);
		}

	} elsif ($cmd_ref->{command} eq 'SP_for' or $cmd_ref->{command} eq 'SP_for_parallel') {
		my $run_id = get_new_run_id;
		my $name = $cmd_ref->{variable};
		my $value = eval_text_in_shell($cmd_ref->{text}, $indent, $args_ref, \%proc_vars, $global_vars_ref);
		return undef if not defined $value;
		if ($cmd_ref->{command} eq 'SP_for' or $max_thread_number == 1) {
			foreach my $each_value (split(/\s+/, $value)) {
				{
					lock($exiting);
					last if $exiting;
				}
				$proc_vars{$name} = $each_value;
				$ret = run_block($blocks[$cmd_ref->{block}], $indent, $args_ref, \%proc_vars);
				return undef if not defined $ret;
				last if $ret != 0;
			}
			delete $proc_vars{$name};
		} else {
			my @threads = ();
			foreach my $each_value (split(/\s+/, $value)) {
				{
					lock($exiting);
					last if $exiting;
				}
				my %thd_vars = %proc_vars;
				$thd_vars{$name} = $each_value;
				push @threads, threads->create(\&run_block,
					$blocks[$cmd_ref->{block}], $indent, $args_ref, \%thd_vars);
			}
			foreach my $thd (@threads) {
				my $thd_ret = $thd->join();
				if (not defined $thd_ret) {
					undef $ret;
				} elsif ($thd_ret != 0) {
					$ret = $thd_ret if defined $ret;
				}
			}
			return undef if not defined $ret;
		}

	} elsif ($cmd_ref->{command} eq 'SP_while') {
		my $run_id = get_new_run_id;
		my $cmd = "SP_while $cmd_ref->{negative}($cmd_ref->{bash})";
		while (1) {
			{
				lock($exiting);
				last if $exiting;
			}
			my $cmd_result = eval_text($cmd_ref->{bash}, $args_ref, \%proc_vars, $global_vars_ref);
			my $ret_ref = run_shell($cmd_result, 'checker', $run_id, $indent);
			return undef if not defined $ret_ref;
			my $yes = ($ret_ref->{ret} == 0) ^ ($cmd_ref->{negative} ne '');
			log_print "$indent($run_id) $cmd returns '" . ($yes ? 'yes' : 'no') . "'\n";
			last if (not $yes);
			$ret = run_block($blocks[$cmd_ref->{block}], $indent, $args_ref, \%proc_vars);
			return undef if not defined $ret;
			last if $ret != 0;
		}

	} elsif ($cmd_ref->{command} eq '') {
		# code block
		$ret = run_block($blocks[$cmd_ref->{block}], $indent, $args_ref, \%proc_vars);
		return undef if not defined $ret;

	} else {
		# For single bash command
		if ($proc_name =~ /_sysinfo$/) {
			my $cmd_result = eval_text($cmd_ref->{command}, $args_ref, \%proc_vars, $global_vars_ref);
			run_shell($cmd_result, 'sysinfo', 0, '');
		} else {
			if ($max_thread_number > 1) {
				LOOP: while (1) {
					{
						lock($thread_number);
						if ($thread_number < $max_thread_number) {
							$thread_number++;
							last LOOP;
						}
					}
					sleep 1;
				}
			}
			my $run_id = get_new_run_id;
			my $cmd_result = eval_text($cmd_ref->{command}, $args_ref, \%proc_vars, $global_vars_ref);

			my $ret_ref = run_shell($cmd_result, '', $run_id, $indent);
			if ($max_thread_number > 1) {
				lock($thread_number);
				$thread_number--;
			}
			if (not defined $ret_ref or $ret_ref->{ret} != 0) {
				lock($exiting);
				$exiting = 2 if $exiting == 0;
			}
			return undef if not defined $ret_ref;
			$ret = $ret_ref->{ret};
			if ($ret != 0) {
				log_print "$indent($run_id) returns $ret\n";
				foreach my $output (keys %{$cmd_ref->{outputs}}) {
					my $file = eval_text($output, $args_ref, \%proc_vars, $global_vars_ref);
					if (-e $file) {
						log_print "$indent($run_id) removes bad output file '$file'!\n";
						unlink $file;
					}
				}
			}
		}
	}
	return { ret => $ret, vars => \%proc_vars };
}

sub run_proc
{
	my ($proc_name, $indent, $args_ref) = @_;

	my $proc_ref = $proc_list{$proc_name};
	my $global_vars_ref = $global_vars{$proc_ref->{file}};
	my %proc_vars = ();

	# If it is sysinfo, run without other checking
	if ($proc_name =~ /_sysinfo$/) {
		log_print "Log sysinfo: $proc_name\n";
		run_block($blocks[$proc_ref->{block}], '', $args_ref, {});
		return 0;
	}

	# Otherwise (not a sysinfo)
	my $cmd = "SP_run $proc_name";
	$cmd .= " $_=$args_ref->{$_}" foreach (keys%{$args_ref});

	my $info_ref = check_proc($proc_ref, $args_ref, \%proc_vars, $args_ref);
	my $ret = check_files($info_ref);
	return $ret if $ret < 0;
	if ($ret > 0) {
		log_print "$indent(Skip) $cmd\n";
		return 0;
	}

	my $run_id = get_new_run_id;
	my $start_time = time;
	log_print "$indent($run_id) $cmd\n";
	log_print "$indent($run_id) starts at " . time_string($start_time) . "\n";

	$ret = run_block($blocks[$proc_ref->{block}], $indent, $args_ref, \%proc_vars);

	if (defined $ret and $ret == 0 and not $keep_temps) {

		# When successeed, remove intermediate files
		foreach my $item (keys %{$proc_ref->{temps}}) {
			my $file = eval_text($item, $args_ref, \%proc_vars, $global_vars_ref);
			if (-e $file) {
				log_printf "$indent($run_id) removes intemediate file '%s'\n", $file;
				unlink $file;
			}
		}
	}

	# Record the finish time
	my $end_time = time;
	log_printf "$indent($run_id) ends at %s (elapsed: %s)\n",
		time_string($end_time), time_elapse_string($start_time, $end_time);

	return $ret;
}

sub run_block
{
	my ($block_ref, $indent, $args_ref, $proc_vars_ref) = @_;
	my $ret = 0;

	{
		lock($exiting);
		return $ret if $exiting;
	}

	my $global_vars_ref = $global_vars{$block_ref->{file}};

	my @cmds = ();
	if ($block_ref->{proc_name} !~ /_sysinfo$/) {
		@cmds = @{$block_ref->{commands}};
	} else {
		my $ok = 0;
		foreach my $cmd_ref (@{$block_ref->{commands}}) {
			if (%{$cmd_ref->{requires}} or %{$cmd_ref->{inputs}} or %{$cmd_ref->{outputs}}) {
				push @cmds, $cmd_ref;
				$ok = 0;
			} elsif (not $ok) {
				push @cmds, $cmd_ref;
				$ok = 1;
			} else {
				$cmds[-1]->{command} .= "\n" . $cmd_ref->{command};
			}
		}
	}

	my @thread_list = ();
	foreach my $cmd_ref (@cmds) {
		
		my $info_ref = { requires => {}, inputs => {}, outputs => {}, saves => {}, temps => {} };
		foreach my $require (keys %{$cmd_ref->{requires}}) {
			my $file = eval_text($require, $args_ref, $proc_vars_ref, $global_vars_ref);
			$info_ref->{requires}{$file} = '';
		}
		foreach my $input (keys %{$cmd_ref->{inputs}}) {
			my $file = eval_text($input, $args_ref, $proc_vars_ref, $global_vars_ref);
			$info_ref->{inputs}{$file} = '';
		}
		foreach my $output (keys %{$cmd_ref->{outputs}}) {
			my $file = eval_text($output, $args_ref, $proc_vars_ref, $global_vars_ref);
			$info_ref->{outputs}{$file} = '';
		}
		foreach my $save (keys %{$cmd_ref->{saves}}) {
			my $file = eval_text($save, $args_ref, $proc_vars_ref, $global_vars_ref);
			$info_ref->{saves}{$file} = '';
		}
		foreach my $temp (keys %{$cmd_ref->{temps}}) {
			my $file = eval_text($temp, $args_ref, $proc_vars_ref, $global_vars_ref);
			$info_ref->{temps}{$file} = '';
		}
		my $check_ret = check_files($info_ref);
		last if $check_ret < 0;
		if ($check_ret > 0) {
			log_print "$indent(Skip) $cmd_ref->{command}\n";
			next;
		}

		if ($can_use_threads and $max_thread_number != 1) {
			my $thd = threads->create({'context' => 'list'}, \&run_cmd,
				$block_ref->{proc_name}, $cmd_ref, $indent . '  ', $args_ref, $proc_vars_ref, $global_vars_ref);

			if ($block_ref->{parallel}) {
				push @thread_list, $thd;
			} else {
				my $thread_ret = $thd->join();
				if (not defined $ret) {
					undef $ret;
					last;
				}
				$ret = $thread_ret->{ret};
				foreach my $name (keys %{$thread_ret->{vars}}) {
					$proc_vars_ref->{$name} = $thread_ret->{vars}->{$name};
				}
			}
		} else {
			my $cmd_ret = run_cmd($block_ref->{proc_name}, $cmd_ref, $indent . '  ',
				$args_ref, $proc_vars_ref, $global_vars_ref);
			if (not defined $cmd_ret) {
				undef $cmd_ret;
				last;
			}
			$ret = $cmd_ret->{ret};
			foreach my $name (keys %{$cmd_ret->{vars}}) {
				$proc_vars_ref->{$name} = $cmd_ret->{vars}->{$name};
			}
		}
		last if not defined $ret or $ret != 0;
	}
	if (scalar @thread_list > 0) {
		foreach my $thd (@thread_list) {
			my $thd_ret = $thd->join();
			if (not defined $thd_ret) {
				undef $ret;
			} elsif ($thd_ret->{ret} != 0) {
				$ret = $thd_ret->{ret} if defined $ret;
			} else {
				foreach my $name (keys %{$thd_ret->{vars}}) {
					$proc_vars_ref->{$name} = $thd_ret->{vars}->{$name};
				}
			}
		}
		@thread_list = ();
	}
	if (not defined $ret or $ret != 0) {
		lock($exiting);
		$exiting = 2 if $exiting == 0;
	}
	return $ret;
}

############################################################
# Main program start from here.

init_config;

my $proc_name = '';
my %args = ();

if ($#ARGV < 0) {
	$help_mode = 1;
} else {
	while (my $arg = shift @ARGV) {
		if ($arg eq '-h' or $arg eq '-H') {
			$help_mode = ($arg eq '-h' ? 1 : 2);
		} elsif ($arg eq '-m') {
			die "ERROR: Missing argument for '$arg' option!\n" if $#ARGV < 0;
			push(@files, abs_path shift @ARGV);
		} elsif ($arg eq '-l' or $arg eq '-L') {
			$list_mode = ($arg eq '-l' ? 1 : 2);
		} elsif ($arg eq '-T') {
			$show_mode = 1;
		} elsif ($arg eq '-k') {
			$keep_temps = 1;
		} elsif ($arg eq '-t') {
			die "ERROR: Missing argument for '$arg' option!\n" if $#ARGV < 0;
			$max_thread_number = shift @ARGV;
			die "ERROR: Invalid max thread number: $max_thread_number!\n" if $max_thread_number < 0;
		} elsif ($arg eq '-e') {
			die "ERROR: Missing argument for '$arg' option!\n" if $#ARGV < 0;
			die "ERROR: Duplicated '$arg' option!\n" if $exec_cmd;
			$exec_cmd = shift @ARGV;
			die "ERROR: Empty inline command is not allowed!\n" if $exec_cmd =~ /^\s*$/;
			die "ERROR: Multi-line inline command is not allowed!\n" if $exec_cmd =~ /\n/;
		} elsif ($arg eq '-s') {
			die "ERROR: Missing argument for '$arg' option!\n" if $#ARGV < 0;
			$shell = shift @ARGV;
			die "ERROR: Empty shell command is not allowed!\n" if $shell =~ /^\s*$/;
			my $qsub_sync = APP_ROOT . '/qsub_sync';
			$shell =~ s/^qsub(\s.*|)/$qsub_sync$1/;
		} else {
			die "ERROR: Unknown option '$arg'!\n" if $arg =~ /^-/;
			if ($arg =~ /^(\w+)=(.*)$/) {
				die "ERROR: duplicated option '$1'!\n" if exists $args{$1};
				my $name = $1;
				$args{$name} = $2;
				die "ERROR: Invalid option '$name'! Option name starts with '_' is reserved.\n" if $name =~ /^_/;
			} else {
				die "ERROR: Invalid format of option: $arg\n" if $proc_name or $exec_cmd;
				$proc_name = $arg;
			}
		}
	}
}
die "ERROR: Can not use both '-e' and '<proc_name>'!\n" if $proc_name and $exec_cmd;

load_modules \@files, \%args;

list_proc $proc_name if $list_mode;

if ($exec_cmd) {
	die "ERROR: Can not use both '-e' and '-T'!\n" if $show_mode;

	# Load inline command as a block
	push @blocks, { commands => [ { command => $exec_cmd } ], file => DEF_PIPE, proc_name => '' };

} elsif ($proc_name) {
	die "ERROR: Unknown procedure '$proc_name'! Use '-l' to list available procedures.\n"
		unless exists $proc_list{$proc_name};
	
	show_proc $proc_name, \%args if $show_mode;

} else {
	print "ERROR: No procedure name provided!\n" unless $help_mode;
	print_usage;
}

my $info_ref;
if ($proc_name) {
	$info_ref = check_proc($proc_list{$proc_name}, \%args, {}, \%args);
} else {
	$info_ref = check_block($blocks[-1], \%args, {}, \%args, {});
}
show_info $proc_name, $info_ref if $help_mode;

if (%{$info_ref->{req_vars}}) {
	die 'ERROR: Variable(s) required for ' . ($proc_name ? "procedure '$proc_name'" : "inline command '$exec_cmd'")
		. ":\n   " . join(', ', sort keys %{$info_ref->{req_vars}}) . "\n";
}
die "ERROR: Can not run internal procedures '$proc_name' directly!\n" if $proc_name =~ /^_/;

mkdir LOG_ROOT or die "ERROR: Can't create directory '" . LOG_ROOT . "'!" unless -d LOG_ROOT;
mkdir LOG_DIR or die "ERROR: Can't create directory '" . LOG_DIR . "'!";

open LOG_FILE, '>>' . LOG_ROOT . '/history.log';
log_print UNIQ_ID . "\t$command_line\n";
close LOG_FILE;

open LOG_FILE, '| tee -ai ' . LOG_DIR . '/log';

log_print '[' . UNIQ_ID . "] $command_line\n";

set_kill_signal_handler;

foreach my $name (keys %proc_list) {
	if ($name =~ /_sysinfo$/) {
		if ($name eq '_sysinfo' or ($proc_name and $proc_list{$name}{file} eq $proc_list{$proc_name}{file})) {
			run_proc $name, '', {};
		}
	}
}

my $ret = 0;
if ($proc_name eq '') {
	$ret = run_block($blocks[-1], '', \%args, {});
} else {
	$ret = run_proc($proc_name, '', \%args);
}
if ($exiting == 1) {
	log_print "Pipeline aborted for KILL signal!\n";
} elsif (not defined $ret) {
	log_print "Pipeline finished abnormally!\n";
} elsif ($ret != 0) {
	log_print "Pipeline finished abnormally with exit value: $ret!\n";
} else {
	log_print "Pipeline finished successfully!\n";
}
close LOG_FILE;

exit (defined $ret ? $ret : 1);