#!/usr/bin/env perl
# usage: ssh proxy01 'tail -f /var/log/httpd/access_log' | realtimeresponsegraph.pl
use strict;
use warnings;
use OpenGL qw(:all);
use List::Util qw(sum);
use POSIX qw(floor);
use Time::HiRes;

my $w = 700;
my $h = 500;
my $stat = {};

my $main = sub {

	eval {
		my $rin = '';
		vec($rin, fileno(STDIN),  1) = 1;
		if (select($rin, undef, undef, 0)) {
			my $line = <>;
			die unless defined $line;
			my $microsec = [ split /\s+/, $line ]->[13] or die;
			my $millisec = $microsec / 1000;

			my $key = floor($millisec / 100 + 0.5) * 100;
			$key = 10000 if $key > 10000;
			$stat->{$key}++;
		}
	};

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

	my $total = sum values %$stat;
	if ($total) {
		{
			glColor3d(0.1, 0.9, 0.3);
			glBegin(GL_LINE_STRIP);
			my $stack = 0;
			for (my $i = 0; $i <= 10000; $i += 100) {
				$stack += $stat->{$i} || 0;
				my $rate = $stack / $total;
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

	glutSwapBuffers();

#	glRasterPos2d(0, 0);
#	glColor3d(1.0, 1.0, 1.0);
#	glutBitmapCharacter(GLUT_BITMAP_TIMES_ROMAN_24, ord($_)) for split //, 'foobar';
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