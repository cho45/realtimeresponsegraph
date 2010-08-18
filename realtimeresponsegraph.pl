#!/usr/bin/env perl
# usage: ssh proxy01 'tail -f /var/log/httpd/access_log' | grep --line-buffered -e "/ch/[0-9]*" | realtimeresponsegraph.pl
use strict;
use warnings;
use OpenGL qw(:all);
use List::Util qw(sum);
use POSIX qw(floor);
use Time::HiRes;
use Getopt::Long;

my $w      = 700;
my $h      = 500;
my $path   = '.';
my $method = 'GET|POST';
my $format = 'combined';

if (-e "$ENV{HOME}/.rrgrc") {
	do "$ENV{HOME}/.rrgrc";
}

my $stat = {};

GetOptions(
	"width=i"  => \$w,
	"height=i" => \$h,
	"path=s"   => \$path,
	"method=s"   => \$method,
	"format=s"   => \$format,
);

my $parser = LogFormat->new($format);
my $main = sub {

	my $rin = '';
	vec($rin, fileno(STDIN),  1) = 1;
	while (select($rin, undef, undef, 0)) {
		my $line = <>;
		defined $line or next;
		my $data = $parser->parse($line);
		$data->{path}   !~ /$path/   or next;
		$data->{method} =~ /$method/ or next;
		print STDERR $line;
		my $microsec = $data->{D} or next;
		my $millisec = $microsec / 1000;

		my $key = floor($millisec / 100 + 0.5) * 100;
		$key = 10000 if $key > 10000;
		$stat->{$key}++;
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

	my $sec1  = 0;
	my $total = sum(values %$stat) || 0;
	if ($total) {
		{
			glColor3d(0.1, 0.9, 0.3);
			glBegin(GL_LINE_STRIP);
			my $stack = 0;
			for (my $i = 0; $i <= 10000; $i += 100) {
				$stack += $stat->{$i} || 0;
				my $rate = $stack / $total;
				$sec1 = $rate if $i == 1000;
				glVertex2d($i / 10000, $rate);
			}
			glEnd();
		}
		{
			glColor3d(0.1, 0.9, 0.3);
			glPointSize(5);
			glBegin(GL_POINTS);
			my $stack = 0;
			for (my $i = 0; $i <= 10000; $i += 100) {
				$stack += $stat->{$i} || 0;
				my $rate = $stack / $total;
				glVertex2d($i / 10000, $rate);
			}
			glEnd();
		}
	}

	glRasterPos2d(0.1,  1 / $h * 2);
	glColor3d(1.0, 1.0, 1.0);
	glutBitmapCharacter(GLUT_BITMAP_TIMES_ROMAN_24, ord($_)) for split //, sprintf('Total:%d / %.1f%% in 1 second', $total, $sec1 * 100);

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
