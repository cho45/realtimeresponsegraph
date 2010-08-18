#!/usr/bin/env perl
use strict;
use warnings;
use OpenGL qw(:all);
use List::Util qw(sum);
use POSIX qw(floor);
use Time::HiRes qw(gettimeofday tv_interval);
use Getopt::Long;
use Pod::Usage;
use constant COLORS => [ map { [ map { $_ ? hex($_) / 0xff : () } split /(..)/ ] } qw/
	5c0800
	a6a404
	6da604
	1a6801
	01684e
	203d9d
	48209d
	9d2096
/];

my $w         = 700;
my $h         = 500;
my $path      = '.';
my $method    = 'GET|POST';
my $format    = '';
my $pagemaker = '.';
my $cache     = '.';
my $max       = 1000;
my $group     = 'method';

-e "$ENV{HOME}/.rrgrc" and do "$ENV{HOME}/.rrgrc";

GetOptions(
	"width=i"     => \$w,
	"height=i"    => \$h,
	"max=i"       => \$max,
	"path=s"      => \$path,
	"method=s"    => \$method,
	"format=s"    => \$format,
	"group=s"     => \$group,

	"pagemaker=s" => \$pagemaker,
	"cache=s"     => \$cache,
);

sub usage {
	pod2usage;
	exit 1;
}

$format or usage;

my $stat = {};
my $detail_stat = {};
my $detail_keys = {};

my $index = 0;
my @keys;

my $parser = LogFormat->new($format);

sub draw {
	my $total = shift;
	my $dat = shift;
	my $color = shift;
	my $type = shift;

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
	return $sec1;
}


my $main = sub {
	my $start = [ gettimeofday ];
	my $rin = '';
	vec($rin, fileno(STDIN),  1) = 1;
	while (select($rin, undef, undef, 0)) {
		my $line = <>;
		defined $line or next;
		my %data;
		if ($format eq 'tsv') {
			foreach my $field (split(/\t/, $line)){
				my ($key, $value) = split(/:/, $field);
				$data{$key} = $value;
			}
		} else {
			%data = %{ $parser->parse($line) };
		}
		defined $data{isrobot}   and ($data{isrobot}   =~ /\-/         or next);
		defined $data{pagemaker} and ($data{pagemaker} =~ /$pagemaker/ or next);
		defined $data{path}      and ($data{path}      =~ /$path/      or next);
		defined $data{method}    and ($data{method}    =~ /$method/    or next);
		if (defined $data{cache}) {
			$data{cache} =~ /$cache/ or next;
			($data{cache}) = $data{cache} =~ /^([\w\-]+)/;
		} else {
			$data{cache} = '';
		}

		print STDERR $line;
		my $microsec = $data{D} || $data{taken} or next;
		my $millisec = $microsec / 1000;

		my $key = floor($millisec / 100 + 0.5) * 100;
		$key = 10000 if $key > 10000;
		$stat->{$key}++;
		$stat->{$keys[$index]}-- if defined($keys[$index]);

		$detail_stat->{$data{$group}} ||= {};
		$detail_keys->{$data{$group}} ||= ();
		$detail_stat->{$data{$group}}->{$key}++;

		$keys[$index] = $key;
		foreach (%$detail_keys){
			$detail_stat->{$_}->{$detail_keys->{$_}[$index]}-- if defined($detail_keys->{$_}[$index]);
			undef $detail_keys->{$_}[$index];
		}
		$detail_keys->{$data{$group}}[$index] = $key;
		$index++;
		$index = 0 if $index >= $max;

		last if tv_interval($start) > 0.0416666666666667;
	}

	glClear(GL_COLOR_BUFFER_BIT);

	glColor3d(1, 1, 1);
	glBegin(GL_LINE_LOOP);
	glVertex2d(1 / $w, 1 / $h);
	glVertex2d(     1, 1 / $h);
	glVertex2d(     1,      1);
	glVertex2d(1 / $w,      1);
	glEnd();

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

	my $sec1   = 0;
	my $total  = sum(values %$stat) || 0;
	my $totals = {};
	my $sec1s  = {};
	if ($total) {
		$sec1 = draw($total, $stat, [0.1, 0.9, 0.3], GL_LINE_STRIP);
		draw($total, $stat, [0.1, 0.9, 0.3], GL_POINTS);
	}

	my $i = 0;
	my $colors = {};
	foreach (keys %$detail_stat) {
		my $color = COLORS->[ $i % @{COLORS()}];
		$colors->{$_} = $color;
		$totals->{$_} = sum(values %{$detail_stat->{$_}}) || 0;
		$sec1s->{$_} ||= 0;
		if ($totals->{$_}) {
			$sec1s->{$_} = draw($totals->{$_}, $detail_stat->{$_}, $color, GL_LINE_STRIP);
			draw($totals->{$_}, $detail_stat->{$_}, $color, GL_POINTS);
		}
		$i++;
	}

	glColor3d(1, 1, 1);
	glRasterPos2d(0.1, 0.01 + 1 / $h * 2);

	glutBitmapCharacter(GLUT_BITMAP_HELVETICA_18, ord($_)) for split //, sprintf('Total:%d | %.1f%% in 1 second ', $total, $sec1 * 100);

	{
		my $i = 0;
		foreach (keys %$totals){
			glColor3d(@{ $colors->{$_} });
			glRasterPos2d(0.9,  0.01 + (1 / $h * 15) * $i++);
			glutBitmapCharacter(GLUT_BITMAP_HELVETICA_12, ord($_)) for split //, sprintf('%s:%s ', $_, $totals->{$_});
			glFlush();
		}
	}

	glutSwapBuffers();

};


glutInit();
glutInitDisplayMode(GLUT_RGBA | GLUT_DOUBLE | GLUT_DEPTH | GLUT_ALPHA);
glutInitWindowSize($w, $h);
glutCreateWindow( 'realtimeresponsegraph' );
# glEnable(GL_COLOR_MATERIAL);
glutReshapeFunc(sub {
		my ($aw, $ah) = @_;

		glViewport(0, 0, $aw, $ah);
		glLoadIdentity();
		glOrtho(
			-$aw / $w + 1, $aw / $w,
			-$ah / $h + 1, $ah / $h,
			-1.0, 1.0
		);
		# glTranslated(-1, -1, 0);
	});
glutDisplayFunc($main);
glutIdleFunc($main);
glutMainLoop();

package LogFormat;
use strict;
use warnings;
use base qw(Class::Data::Inheritable);

my $regexp;

INIT {
	$regexp = {
		't' => qr/\[([^\]]+?)\]/,
		'r' => qr/(.+?)/,
	};

	__PACKAGE__->mk_classdata(logformats => {});

	LogFormat->define_logformats(q[
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
    --format      required.
    --width       window width (default: 700)
    --height      window height (default: 500)
    --max         number of max requests
    --path        gather only path matching this regexp
    --method
    --pagemaker
    --cache


 Read (do) ~/.rrgrc on startup.

