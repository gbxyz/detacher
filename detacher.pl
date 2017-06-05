#!/usr/bin/perl
# Copyright 2017 Gavin Brown. You can use and/or modify this program under the
# same terms as Perl itself.
use Digest::SHA;
use File::Copy;
use File::Slurp;
use Getopt::Long;
use HTTP::Daemon;
use HTTP::Date;
use IO::File;
use JSON qw(encode_json decode_json);
use MIME::Parser;
use Mail::Internet;
use Sys::Hostname;
use Pod::Usage;
use strict;

=pod

=head1 NAME

C<detacher> - a program that can remove large attachments from email messages
and make them available via a web server.

=head1 USAGE

C<detacher> has two modes which can be selected using the C<--mode> argument:

=over

=item * C<--mode=milter>: milter mode; this is the default. C<detacher> accepts
an Internet mail message on C<STDIN>, replaces any attachments with links, and
emits it on C<STDOUT>.

=item * C<--mode=server>: server mode. C<detacher> starts up an HTTP server and
serves detached files.

=back

=head1 CONFIGURATION

You can configure C<detacher> using a configuration file which can be specified
using the C<--config=FILE> argument. The file must be in JSON format. If a
configuration file is not specified, C<detacher> will use the following default
configuration:

	{
	    "milter": {
	        "tmpdir": "/tmp",
	        "size": 1048576,
	        "msgfmt": "An attachment has been replaced. Please visit:\n\n%s\n"
	    },
	    "server": {
	        "name": $HOSTNAME,
	        "port": 8080,
	        "addr": "0.0.0.0"
	    },
	    "common": {
	        "dir": "/tmp"
	    }
	}

Using this configuration, any attachment larger than 1,048,576 (1MB) will be
detached from the message and stored in C</tmp>. It will be replaced with a
plaintext MIME entity, containing a URL which can be used to download the file.
C<$HOSTNAME> is determined using L<Sys::Hostname>.

=head1 SERVER MODE

C<detacher> uses L<HTTP::Daemon> which is a very simplistic HTTP server
implementation. It is RECOMMENDED that in production environments, you use a
reverse proxy such as Nginx or Squid in front of the C<detacher> server.

=head1 INSTALLATION

=head2 MILTER INSTALLATION

TO DO.

=head2 SERVER INSTALLATION

Simply add something like this to your C</etc/rc.local>:

    /path/to/detacher.pl --config=CONF --mode=server 1>/dev/null 2>&1 &

=head2 DEPENDENCIES

C<detacher> needs:

=over

=item * L<Digest::SHA>

=item * L<File::Copy>

=item * L<File::Slurp>

=item * L<Getopt::Long>

=item * L<HTTP::Daemon>

=item * L<HTTP::Date>

=item * L<IO::File>

=item * L<JSON>

=item * L<MIME::Parser>

=item * L<Mail::Internet>

=item * L<Pod::Usage>

=item * L<Sys::Hostname>

=back

Many of these modules will already be installed or can be got through CPAN.

=head1 COPYRIGHT

Copyright 2017 Gavin Brown. You can use and/or modify this program under the
same terms as Perl itself.

=cut

#
# send an informational message to STDERR
# has the same profile as sprintf()
#
sub note {
	my ($s, @a) = @_;
	printf(STDERR "$s\n", @a);
}

#
# send an error to STDERR and quit
# has the same profile as note()
#
sub fail {
	my ($s, @a) = @_;
	note("ERROR: $s", @a);
	exit(1);
}

#
# default command-line otpions
#
my $opt = {
	'mode' => 'milter',
};

#
# parse command-line options
#
GetOptions(
	$opt,
	'help',
	'mode=s',
	'config=s',
);

if ($opt->{'help'}) {
	pod2usage(
		'-verbose'	=> 99,
		'-sections'	=> 'NAME|USAGE|CONFIGURATION',
	);
	exit;
}

#
# parse config options from config file
#
my $conf;
if ($opt->{'config'}) {
	my $json;
	fail("Cannot read JSON from '%s'", $opt->{'config'}) if (!($json = read_file($opt->{'config'})));
	fail("Cannot parse JSON in '%s'",  $opt->{'config'}) if (!($conf = json_decode($json)));

} else {
	#
	# default options when no config file is specified
	#
	$conf = {
		'common' => {
			'dir' => '/tmp',	# location where detached files are stored
		},
		'milter' => {
			'size'   => 1024 ** 2,	# any file larger than this (in bytes) will be detached
			'tmpdir' => '/tmp',	# to where temporary files are written
			'msgfmt' => "An attachment has been replaced. Please visit:\n\n%s\n",
		},
		'server' => {
			'port' => 8080,		# TCP port
			'name' => hostname(),	# HTTP Host name
			'addr' => '0.0.0.0',	# Local address to bind to
		},
	};
}

if ('server' eq $opt->{'mode'}) {
	run_as_server();

} else {
	run_as_milter();

}

#
# server mode - listen for connections, extract the hash of a file
# from the request URI, and return it
#
sub run_as_server {
	#
	# set up HTTP server
	#
	my $server = HTTP::Daemon->new(
		'LocalAddr' => $conf->{'server'}->{'addr'},
		'LocalPort' => $conf->{'server'}->{'port'},
	);

	#
	# listen for connections
	#
	while (my $connection = $server->accept) {
		eval {
			my $request = $connection->get_request;

			#
			# parse request
			#
			if ($request->method eq 'GET') {

				#
				# remove all non-hex characters from the path to get the hash
				#
				my $hash = lc($request->uri->path);
				$hash =~ s/[^0-9a-f]//g;

				#
				# look for the file on disk
				#
				my $path = sprintf('%s/%s', $conf->{'common'}->{'dir'}, $hash);
				if (!-e $path) {
					$connection->send_error(404);

				} else {
					#
					# meta file must exist
					#
					my $meta = sprintf('%s.js', $path);
					if (!-e $meta) {
						$connection->send_error(500);

					} else {
						my $info = decode_json(read_file($meta));
						if (!$info) {
							$connection->send_error(500);

						} else {

							#
							# check If-Modified-Since
							#
							my $date = $request->header('If-Modified-Since');
							if ($date && $info->{'date'} < str2time($date)) {
								$connection->send_status_line(304);

							} else {
								#
								# send the file to the client
								#
								$connection->send_status_line;
								$connection->send_header('Content-Type',        $info->{'type'});
								$connection->send_header('Content-Disposition',	sprintf('attachment;filename="%s"', $info->{'name'})),
								$connection->send_header('Content-Length',      (stat($path))[7]);
								$connection->send_header('Last-Modified',       time2str($info->{'date'}));
								$connection->send_header('Connection',          'close');

								$connection->send_file($path);
							}
						}
					}
				}

			} else {
				$connection->send_error(400);

			}
		};
		$connection->close;
		undef($connection);
	}
}

#
# milter mode - read a message on STDIN, parse into parts,
# and examine each part, detaching as needed, then emit
# the filtered message on STDOUT
#
sub run_as_milter {

	#
	# MIME::Parser dumps message parts to disk, so
	# configure it to use a temporary directory
	#
	my $parser = MIME::Parser->new;
	$parser->output_under($conf->{'milter'}->{'tmpdir'});

	#
	# parse STDIN
	#
	my $entity = $parser->parse(\*STDIN);

	#
	# check the top-level entity: check_entity() will
	# call itself recursively if any child parts are
	# also multipart
	#
	check_entity($entity);

	#
	# emit (possibly) amended message to STDOUT
	#
	$entity->sync_headers('Length' => 'COMPUTE');
	$entity->print(\*STDOUT);

	#
	# remove temporary files
	#
	$entity->purge;
}

#
# check an entity: entities may themselves be multipart, so we
# run recursively
#
sub check_entity {
	my $entity = shift;
	if ($entity->is_multipart) {
		map { check_entity($_) } $entity->parts;

	} elsif ((stat($entity->bodyhandle->path))[7] > $conf->{'milter'}->{'size'}) {
		detach($entity);

	}
}

#
# "detach" an entity - copy the file to a stable location on disk, then
# replace it with a plaintext entity containing a URL which points to the
# detached file
#
sub detach {
	my $entity = shift;
	my $file   = $entity->bodyhandle->path;
	my $hash   = hash_file($file);
	my $path   = sprintf('%s/%s', $conf->{'common'}->{'dir'}, $hash);
	my $url    = sprintf('http://%s:%d/%s', $conf->{'server'}->{'name'}, $conf->{'server'}->{'port'}, $hash);
	my $meta   = sprintf('%s.js', $path);

	#
	# if we already have a file with the same hash, then don't bother overwriting it
	#
	if (!-e $path || hash_file($path) ne $hash) {
		copy($file, $path);
		chmod(0400, $path);

		#
		# store some meta-data
		#
		my $handle = IO::File->new;
		$handle->open($meta, 'w');
		$handle->print(encode_json({
			'type' => $entity->head->mime_type,
			'name' => $entity->head->recommended_filename,
			'date' => time(),
		}));
		$handle->close;
	}

	#
	# rebuilt the entity as plaintext containing a link to the detached file
	#
	$entity->build(
		'Type'	=> 'text/plain',
		'Data'	=> sprintf($conf->{'milter'}->{'msgfmt'}, $url),
	);
}

sub hash_file {
	my $digest = Digest::SHA->new;
	$digest->addfile(shift);
	return lc($digest->hexdigest);
}
