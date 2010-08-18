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
my $pagemaker = '.';
my $cache = '.';
my $logformat;

my $regexp = qr/^(.*?) (.*?) (.*?) \[(.*?)\] "(\S+?)(?: +(.*?) +(\S*?))?" (.*?) (.*?) "(.*?)" "(.*?)" "(.*?)" (.*?) /;
my $fields = [qw/host l user time method path protocol status bytes referer ua bcookie response/];
my $stat = {};
my $detail_stat = {};

my $index = 0;
my $max = 1000;
my @keys;
my $detail_keys = {};

GetOptions(
	"width=i"  => \$w,
	"height=i" => \$h,
	"path=s"   => \$path,
	"method=s"   => \$method,
	"pagemaker=s"   => \$pagemaker,
	"max=s"   => \$max,
	"cache=s"   => \$cache,
	"logformat=s"   => \$logformat,
);

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

	my $rin = '';
	vec($rin, fileno(STDIN),  1) = 1;
	while (select($rin, undef, undef, 0)) {
		my $line = <>;
		defined $line or next;
		my %data;
		if(defined($logformat)){
			foreach my $field (split(/\t/, $line)){
				my ($key, $value) = split(/:/, $field);
				$data{$key} = $value;
			}
		} else {
			@data{@$fields} = ($line =~ /$regexp/);
		}
		$data{isrobot} =~ /\-/ or next;
		$data{pagemaker} =~ /$pagemaker/ or next;
		$data{cache} =~ /$cache/ or next;
		($data{cache}) = $data{cache} =~ /^([\w\-]+)/;
		#$data{path}   =~ /$path/   or next;
		#$data{method} =~ /$method/ or next;
		print STDERR $line;
		my $microsec = $data{taken} or next;
		my $millisec = $microsec / 1000;

		my $key = floor($millisec / 100 + 0.5) * 100;
		$key = 10000 if $key > 10000;
		$stat->{$key}++;
		$stat->{$keys[$index]}-- if defined($keys[$index]);

		$detail_stat->{$data{cache}} ||= {};
		$detail_keys->{$data{cache}} ||= ();

		$detail_stat->{$data{cache}}->{$key}++;

		$keys[$index] = $key;
		foreach (%$detail_keys){
			$detail_stat->{$_}->{$detail_keys->{$_}[$index]}-- if defined($detail_keys->{$_}[$index]);
			undef $detail_keys->{$_}[$index];
		}
		$detail_keys->{$data{cache}}[$index] = $key;
		$index++;
		$index = 0 if $index >= $max;
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
	my $totals = {};
	my $sec1s = {};
	if ($total) {
		$sec1 = draw($total, $stat, [0.1, 0.9, 0.3], GL_LINE_STRIP);
		draw($total, $stat, [0.1, 0.9, 0.3], GL_POINTS);
	}

	my $i = 0;
	my @color = ([0.9, 0.9, 0.1], [0.9, 0.2, 0.4], [0.2, 0.5, 0.9]);
	foreach (keys %$detail_stat){
		$totals->{$_} = sum(values %{$detail_stat->{$_}}) || 0;
		$sec1s->{$_} ||= 0;
		if ($totals->{$_}) {
			$sec1s->{$_} = draw($totals->{$_}, $detail_stat->{$_}, $color[$i], GL_LINE_STRIP);
			draw($totals->{$_}, $detail_stat->{$_}, $color[$i], GL_POINTS);
		}
		$i++;
	}

	glRasterPos2d(0.1,  1 / $h * 2);
	glColor3d(1.0, 1.0, 1.0);

	my @dat;
	foreach (keys %$totals){
		push @dat, sprintf('%s:%s', $_, $totals->{$_});
	}
	my $s = join('/', @dat);

	glutBitmapCharacter(GLUT_BITMAP_TIMES_ROMAN_24, ord($_)) for split //, sprintf('Total:%d / %.1f%% in 1 second (%s)', $total, $sec1 * 100, $s);

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
