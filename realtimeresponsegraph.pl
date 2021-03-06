#!/usr/bin/env perl
package RealtimeResponseGraph;
use strict;
use warnings;
use OpenGL qw(:all);
use List::Util qw(sum);
use POSIX qw(floor);
use Time::HiRes qw(gettimeofday tv_interval);
use Getopt::Long;
use Pod::Usage;
use constant FPS => 24;
use constant COLORS => [ map { [ map { $_ ? hex($_) / 0xff : () } split /(..)/ ] } qw/
	00dd1a
	5c0800
	a6a404
	6da604
	1a6801
	01684e
	203d9d
	48209d
	9d2096
/];

sub run {
	my ($class) = @_;
	my $self = $class->new;
	$self->load_rc;
	$self->parse_options;
	$self->run_loop;
}

sub help {
	pod2usage;
	exit 1;
}

sub new {
	my ($class, %opts) = @_;
	bless {
		parser       => undef,
		stats        => {},
		detail_stats => {},
		detail_keys  => {},
		keys         => [],
		index        => 0,
		opts => {
			width     => 700,
			height    => 500,
			path      => undef,
			method    => undef,
			format    => '',
			max       => 1000,
			group     => 'method',
			isrobot   => '-',
		},
		%opts
	}, $class;
}

sub parse_options {
	my ($self) = @_;
	GetOptions(
		"width=i"        => \$self->{opts}->{width},
		"height=i"       => \$self->{opts}->{height},
		"max=i"          => \$self->{opts}->{max},
		"path=s"         => \$self->{opts}->{path},
		"method=s"       => \$self->{opts}->{method},
		"format=s"       => \$self->{opts}->{format},
		"group=s"        => \$self->{opts}->{group},
		"invert-match|v" => \$self->{opts}->{invert_match},

		"pagemaker=s"    => \$self->{opts}->{pagemaker},
		"cache=s"        => \$self->{opts}->{cache},
	);
	if ($self->{opts}->{group} =~ /^sub\s*\{/) {
		$self->{opts}->{group} = eval($self->{opts}->{group});
		die $@ if ($@);
	}
	$self;
}

sub load_rc {
	my ($self) = @_;
	local $_ = $self;
	-e "$ENV{HOME}/.rrgrc" and do "$ENV{HOME}/.rrgrc";
	if ($@) {
		die "Couldn't load ~/.rrgc: $@";
	}
}

sub read_input {
	my ($self) = @_;
	my $stats        = $self->{stats};
	my $detail_stats = $self->{detail_stats};
	my $detail_keys  = $self->{detail_keys};
	my $keys         = $self->{keys};

	my $max_wait     = 1 / FPS;

	my $start = [ gettimeofday ];
	my $rin = '';
	vec($rin, fileno(STDIN),  1) = 1;
	LINE: while (select($rin, undef, undef, $max_wait)) {
		my $line = <>;
		defined $line or next;
		my $data = $self->{parser}->parse($line);
		for (qw/path method pagemaker cache isrobot/) {
			my $reg = $self->{opts}->{$_};
			if ($self->{opts}->{invert_match}) {
				defined $reg && defined $data->{$_} and ($data->{$_} !~ /$reg/ or next LINE);
			} else {
				defined $reg && defined $data->{$_} and ($data->{$_} =~ /$reg/ or next LINE);
			}
		}

		($data->{cache}) = ($data->{cache} =~ /^([\w\-]+)/) if defined $data->{cache};
		print STDERR $line;

		my $microsec = $data->{D} || $data->{taken} or next;
		my $millisec = $microsec / 1000;

		my $key = floor($millisec / 100 + 0.5) * 100;
		$key = 10000 if $key > 10000;

		my $index = $self->{index};
		$stats->{$key}++;
		$stats->{$keys->[$index]}-- if defined $keys->[$index];

		my $group_by = $self->{opts}->{group};
		my $group = ref($group_by) ? $group_by->(local $_ = $data) : $data->{$group_by};

		$detail_stats->{$group} ||= {};
		$detail_stats->{$group}->{$key}++;

		$keys->[$index] = $key;
		foreach (%$detail_keys){
			$detail_stats->{$_}->{$detail_keys->{$_}[$index]}-- if defined $detail_keys->{$_}[$index];
			undef $detail_keys->{$_}[$index];
		}
		$detail_keys->{$group}[$index] = $key;
		$index++;
		$index = 0 if $index >= $self->{opts}->{max};
		$self->{index} = $index;

		last if tv_interval($start) > $max_wait;
	}
}

sub run_loop {
	my ($self) = @_;
	$self->{opts}->{format} or $self->help;
	$self->{parser} = ($self->{opts}->{format} eq 'tsv') ? Format::TSV->new:
	                                                       Format::Apache::LogFormat->new($self->{opts}->{format});

	my ($w, $h) = ($self->{opts}->{width}, $self->{opts}->{height});
	my $frame = 0;
	my $fps   = FPS;
	my $start = [ gettimeofday ];
	my $main = sub {
		$self->read_input;

		glClear(GL_COLOR_BUFFER_BIT);

		{; # draw border
			glColor3d(1, 1, 1);
			glBegin(GL_LINE_LOOP);
			glVertex2d(1 / $w, 1 / $h);
			glVertex2d(     1, 1 / $h);
			glVertex2d(     1,      1);
			glVertex2d(1 / $w,      1);
			glEnd();
		}

		{; # draw ruled lines
			glColor3d(0.1, 0.1, 0.1);
			glBegin(GL_LINES);
			for (my $i = 0; $i < 10; $i++) {
				glVertex2d($i * 0.1, 0);
				glVertex2d($i * 0.1, 1);
			}
			for (my $i = 0; $i < 10; $i++) {
				glVertex2d(0, $i * 0.1);
				glVertex2d(1, $i * 0.1);
			}
			glEnd();
		}

		my $stats = $self->{stats};
		my $detail_stats = $self->{detail_stats};

		my $total  = sum(values %$stats) || 0;
		my $sec1   = 0;
		my $sec1s  = {};
		my $totals = {};
		my $colors = {};

		{; # draw graphs
			if ($total) {
				$sec1 = draw($total, $stats, [0.5, 0.5, 0.5], GL_LINE_STRIP);
				draw($total, $stats, [0.5, 0.5, 0.5], GL_POINTS);
			}

			my $i = 0;
			foreach (keys %$detail_stats) {
				my $color = COLORS->[ $i % @{COLORS()}];
				$colors->{$_} = $color;
				$totals->{$_} = sum(values %{$detail_stats->{$_}}) || 0;
				$sec1s->{$_} ||= 0;
				if ($totals->{$_}) {
					$sec1s->{$_} = draw($totals->{$_}, $detail_stats->{$_}, $color, GL_LINE_STRIP);
					draw($totals->{$_}, $detail_stats->{$_}, $color, GL_POINTS);
				}
				$i++;
			}
		}

		{; # statics
			glColor3d(1, 1, 1);
			glRasterPos2d(0.1, 0.01 + 1 / $h * 2);
			glutBitmapCharacter(GLUT_BITMAP_HELVETICA_18, ord($_)) for split //, sprintf('Total:%d | %.1f%%@1sec', $total, $sec1 * 100);
		}

		{; # legend
			my $i = 0;
			foreach (keys %$totals){
				glColor3d(@{ $colors->{$_} });
				glRasterPos2d(0.7,  0.01 + (1 / $h * 15) * $i++);
				glutBitmapCharacter(GLUT_BITMAP_HELVETICA_12, ord($_)) for split //, sprintf('%.1f%% | %s:%s', $sec1s->{$_} * 100, $_, $totals->{$_});
			}
		}

		{; # fps
			$frame++;
			my $time     = [ gettimeofday ];
			my $interval = tv_interval($start, $time);
			if ($interval > 1) {
				$fps   = $frame / $interval;
				$frame = 0;
				$start = $time;
			}
			glColor3d(0.3, 0.3, 0.3);
			glRasterPos2d(0.05,  0.01);
			glutBitmapCharacter(GLUT_BITMAP_HELVETICA_12, ord($_)) for split //, sprintf('%dfps', $fps);
		}

		glutSwapBuffers();
	};


	glutInit();
	glutInitDisplayMode(GLUT_RGBA | GLUT_DOUBLE | GLUT_DEPTH | GLUT_ALPHA);
	glutInitWindowSize($w, $h);
	glutCreateWindow( 'realtimeresponsegraph' );
	glutReshapeFunc(sub {
			my ($aw, $ah) = @_;

			glViewport(0, 0, $aw, $ah);
			glLoadIdentity();
			glOrtho(
				0, 1,
				0, 1,
				-1.0, 1.0
			);
			# glTranslated(-1, -1, 0);
		});
	glutDisplayFunc($main);
	glutIdleFunc($main);
	glutMainLoop();
}

sub draw {
	my ($total, $dat, $color, $type) = @_;

	my $sec1 = 0;
	glColor3d(@$color);
	glPointSize(5) if($type == GL_POINTS);
	glBegin($type);
	my $stack = 0;
	for (my $i = 0; $i <= 10000; $i += 100) {
		$stack += $dat->{$i} || 0;
		my $rate = $stack / $total;
		$sec1 = $rate if $i == 1000;
		glVertex2d($i / 10000, $rate);
	}
	glEnd();

	$sec1;
}

__PACKAGE__->run;

exit;

package Format::TSV;
use strict;
use warnings;

sub new {
	my ($class) = @_;
	bless {}, $class;
}

sub parse {
	my ($self, $line) = @_;
	my %data;
	foreach my $field (split(/\t/, $line)){
		my ($key, $value) = split(/:/, $field);
		$data{$key} = $value;
	}
	\%data;
}

package Format::Apache::LogFormat;
use strict;
use warnings;
use base qw(Class::Data::Inheritable);
use Carp;

my $regexp;

INIT {
	$regexp = {
		't' => qr/\[([^\]]+?)\]/,
		'r' => qr/(.+?)/,
	};

	__PACKAGE__->mk_classdata(logformats => {});

	__PACKAGE__->define_logformats(q[
		LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
		LogFormat "%h %l %u %t \"%r\" %>s %b" common
	]);
};

sub define_logformats {
	my ($class, $format) = @_;
	for my $line (split /\n/, $format) {
		my ($format, $name) = ($line =~ /^\s*LogFormat\s+"((?:\\\\|\\\"|[^\"])+)"\s+(\S+)\s*$/) or next;
		my $fields = [];
		$format =~ s{\\"}{"}g;
		$format =~ s{%[<>\d,]*(\w|\{[^\}]+\}\w)}{
			my $type = $1;
			push @$fields, $type;
			$regexp->{$type} || ($type =~ /\{/ ? qr/(.+?)/ : qr/(\S*)/);
		}eg;
		$format =~ s{%%}{%}g;
		$class->logformats->{$name} = {
			fields => $fields,
			regexp => qr/^$format$/,
		};
	}
	$class->logformats;
}

sub new {
	my ($class, $name) = @_;
	my $format = $class->logformats->{$name};
	$format or croak "undefined format: $format";
	bless {
		name   => $name,
		regexp => $format->{regexp},
		fields => $format->{fields},
	}, $class;
}

sub parse {
	my ($self, $line) = @_;
	my $fields = $self->{fields};
	my $regexp = $self->{regexp};
	my %data; @data{@$fields} = ($line =~ $regexp);
	if (defined $data{r}) {
		@data{qw/method path protocol/} = split / /, $data{r};
	}
	\%data
}

sub regexp {
	my ($self) = @_;
	$self->{regexp};
}

__END__

=head1 NAME

realtimeresponsegraph.pl

=head1 SYNOPSIS

 realtimeresponsegraph --format <format>

 ssh proxy01 'tail -f /var/log/httpd/access_log' | realtimeresponsegraph.pl --format rich_log --path '^/$'

 Options:
    --format [name]       required.
    --width  [num]        window width (default: 700)
    --height [num]        window height (default: 500)
    --max    [n]          number of max requests
    --path   [regexp]     gather only path matching this regexp
    --method [regexp]     gather only method matching this regexp
    --group  [name|sub]   draw all graphs group by this.
                          --group 'sub{$_->{method}}' is same as --group method
    -v --invert-match     invert all condition

    --pagemaker
    --cache


 Read (do) ~/.rrgrc on startup.

