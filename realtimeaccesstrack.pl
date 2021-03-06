#!/usr/bin/env perl
package RealtimeResponseGraph;
use strict;
use warnings;
use OpenGL qw(:all);
use List::Util qw(sum first);
use POSIX qw(floor);
use Time::HiRes qw(gettimeofday tv_interval sleep);
use Getopt::Long;
use Pod::Usage;
use DateTime::Format::HTTP;
use constant FPS => 24;

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
		ids          => {},
		keys         => {},
		index        => 1,
		threshold    => 0,
		opts => {
			width     => 1150,
			height    => 800,
			path      => undef,
			method    => undef,
			format    => '',
			max       => 1000,
			dot       => undef,
			threshold => 5,
			most      => undef,
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
		"invert-match|v" => \$self->{opts}->{invert_match},
		"dot"            => \$self->{opts}->{dot},
		"threshold|t=i"  => \$self->{opts}->{threshold},
		"most"           => \$self->{opts}->{most},

		"pagemaker=s"    => \$self->{opts}->{pagemaker},
		"cache=s"        => \$self->{opts}->{cache},
	);
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
	my $max_wait     = 1 / FPS;

	my $start = [ gettimeofday ];
	my $rin = '';
	vec($rin, fileno(STDIN),  1) = 1;
	LINE: while (select($rin, undef, undef, $max_wait)) {
		sleep 0.001;
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
		
		my $id;
		for my $n (qw/{bcookie}e {X-DSi-SID}i {X-DCMGUID}i {X-UP-SUBNO}i {X-JPHONE-UID}i/) {
		#for my $n (qw/{bcookie}e/) {
			$id = $data->{$n} or next;
			$id = undef if $id eq '-';
			$id or next;
			last;
		}
		$id or next;

		my @paths      = split '/', $data->{path};
		my ($last)     = (pop(@paths) =~ /(.{0,10})$/);
		my $short_path = join('/', map { /^([a-z0-9]{0,3})/i } @paths) . "/$last";

		my $epoch = DateTime::Format::HTTP->parse_datetime($data->{t})->epoch;
		push @{ $self->{keys}->{$epoch} ||= [] }, +{
			id         => $id,
			method     => $data->{method},
			path       => $data->{path},
			short_path => $short_path,
		};
		$self->{ids}->{$id} ||= {
			id     => $id,
			x      => $self->{index} += 7,
			color  => [rand(), rand(), rand()],
			ua     => '[' . $self->transform_ua($data->{'{User-Agent}i'}) . ']',
			first  => $epoch,
			count  => 0,
		};
		$self->{ids}->{$id}->{count}++;
		$self->{last_time} = $epoch if !$self->{last_time} || $self->{last_time} < $epoch;

		last if tv_interval($start) > $max_wait;
	}
}

sub transform_ua {
	my ($self, $ua) = @_;
	if ($ua =~ /DSi/) {
		return 'DSi';
	} elsif ($ua =~ /Opera/) {
		return 'Opera';
	} elsif ($ua =~ /MSIE/) {
		return 'MSIE';
	} elsif ($ua =~ /Firefox/) {
		return 'Firefox';
	} elsif ($ua =~ /Chrome/) {
		return 'Chrome';
	} elsif ($ua =~ /Safari/) {
		return 'Safari';
	} elsif ($ua =~ /WebKit/) {
		return 'WebKit';
	} elsif ($ua =~ /BOT|Crawler|Spider/i) {
		return 'BOT';
	} elsif ($ua =~ /KDDI|NetFront|DoCoMo/i) {
		return 'KTai';
	} else {
		return $ua;
	}
}

sub gc {
	my ($self) = @_;
	my $now = $self->{last_time} or return;
	for my $key (keys %{ $self->{keys} }) {
		if ($key < ($now - $self->{opts}->{height} / 3)) {
			my $reqs = delete $self->{keys}->{$key};
			for my $req (@$reqs) {
				my $id = $req->{id};
				$self->{ids}->{$id}->{count}--;
				# warn "decr: $id / " . $self->{ids}->{$id}->{count};
				if ($self->{ids}->{$id}->{count} <= 0) {
					# warn "GC: ". $self->{ids}->{$id};;
					delete $self->{ids}->{$id};
				}
			}
		}
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

		{;
			glPointSize(4);
			my $t = {};
			my $decr = 0;
			my $counter = {};

			my $now = $self->{last_time} || time();
			for (my $y = 0; $y < $h; $y++) { # 縦が秒
				my $reqs = $self->{keys}->{$now - $y} or next;
				for my $req (@$reqs) {
					my $id = $req->{id};
					my $d = $self->{ids}->{$id};
					if ($d->{count} < $self->{threshold}) {
						next;
					} elsif ($d->{count} > $self->{threshold}) {
						$decr++;
					}

					glColor3d(@{ $d->{color} });
					my $xx = 1 / $w * (($d->{x} % 200) * 5);
					my $yy = 1 / $h * ($y * 5);
					if (my $prev = $t->{$id}) {
						glBegin(GL_LINE_STRIP);
						glVertex2d($prev->{xx}, $prev->{yy});
						glVertex2d($xx, $yy);
						glEnd();
					} else {
						$counter->{ $d->{count} }++;
					}
					$t->{$id} = +{ xx => $xx, yy => $yy };

					glBegin(GL_POINTS);
					glVertex2d($xx, $yy);
					glEnd();

					unless ($self->{opts}->{dot}) {
						my $desc     = $req->{short_path};
						my $short_id = substr($id, -4, 4);
						glRasterPos2d($xx, $yy);
						glutBitmapCharacter(GLUT_BITMAP_HELVETICA_10, ord($_)) for split //, " " . ($req->{method} eq 'GET' ? $desc : $req->{method} . "=" . $desc);
						if ($d->{first} == $now - $y) {
							glutBitmapCharacter(GLUT_BITMAP_HELVETICA_10, ord($_)) for split //, sprintf(" [%s]%s", $short_id, $d->{ua});
						}
					}
				}
			}

			if ($self->{opts}->{most}) {
				if ($decr) {
					$self->{threshold}++;
				} else {
					$self->{threshold}--;
				}
			} else {
				my $next_threshold = do { my $i = 0; first { $i += $counter->{$_} ; $i >= $self->{opts}->{threshold}; } sort { $b <=> $a } keys %$counter };
				if ($next_threshold) {
					$self->{threshold} = $next_threshold;
				} else {
					$self->{threshold}--;
				}
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

		$self->gc;
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

