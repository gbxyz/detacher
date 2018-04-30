#!/usr/bin/perl
# Copyright 2017 Gavin Brown. You can use and/or modify this program under the
# same terms as Perl itself.
use Digest::SHA;
use File::Copy;
use File::Path qw(make_path);
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
	    "common": {
	        "dir": "/tmp",
	        "alg": "sha256",
	        "key": ""
	    },
	    "milter": {
	        "tmpdir": "/tmp",
	        "size": 1048576,
		"urlfmt": "http://{host}:{port}/{hash}",
	        "msgfmt": "An attachment has been replaced. Please visit:\n\n{url}\n"
	    },
	    "server": {
	        "name": $HOSTNAME,
	        "addr": "0.0.0.0",
	        "port": 8080
	    }
	}

=head2 Common

=over

=item * C<dir> - where detached files are stored. The default value is C</tmp>,
which is UNSAFE as many operating system will purge the contents of this
directory during a power cycle.

=item * C<alg> - the hash algorithm to use. The default value is C<sha256>
which probably should not be changed unless you have good reason

=item * C<key> - if access to the web server is not restricted, then there is
a risk that an attacker might perform a "brute force" attack using known hash
values to learn if a particular file is present. This risk can be mitigated by
setting the C<key> parameter to a non-empty value. B<Important Note:> if this
value is ever changed, you will need to rename every detached file!

=back

=head2 Milter

=over

=item * C<tmpdir> - C<detacher> uses the L<MIME::Parser> library which writes
temporary files to disk. This parameter controls which directory is used. Any
files written to this location are removed when C<detacher> is finished.

=item * C<size> - any attachments larger than this size are detached. The
default value is 1MB.

=item * C<urlfmt> - this is a template used to construct a URL. The default
value is C<http://{host}:{port}/{hash}> which will be populated using the
values from the C<server> section; however, if you are using a reverse proxy
in front of the C<detacher> server, then you will want to change this value.

=item * C<msgfmt> - this is the template for the plaintext message that will
replace the attachment in the filtered message. Any instance of the string
C<{url}> will be replaced with the URL.

=back

=head2 Server

=over

=item * C<name> - the DNS name of the server. The default value is that
returned by C<Sys::Hostname>.

=item * C<addr> - the IP address to bind to on the server host. The
default value is C<0.0.0.0> but may be changed to some other value if a
reverse proxy is used.

=item * C<port> - The TCP port to bind to. The default value is C<8080>.

=back

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
	fail("Cannot parse JSON in '%s'",  $opt->{'config'}) if (!($conf = decode_json($json)));

} else {
	#
	# default options when no config file is specified
	#
	$conf = {
		'common' => {
			'dir' => '/tmp',	# location where detached files are stored
			'alg' => 'sha256',	# hash algorithm
			'key' => '',		# secret key to mix in when generating hashes
		},
		'milter' => {
			'size'   => 1024 ** 2,	# any file larger than this (in bytes) will be detached
			'tmpdir' => '/tmp',	# to where temporary files are written
			'urlfmt' => 'http://{host}:{port}/{hash}',
			'msgfmt' => "An attachment has been replaced. Please visit:\n\n%s\n",
		},
		'server' => {
			'port'   => 8080,	# TCP port
			'name'   => hostname(),	# HTTP Host name
			'addr'   => '0.0.0.0',	# Local address to bind to
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

		#
		# catch errors by using eval { ... }
		#
		eval {
			handle_connection($connection);
			$connection->close;
			undef($connection);
		};
	}
}

sub handle_connection {
	my $connection = shift;
	my $request = $connection->get_request;

	if ($request->method ne 'GET') {
		$connection->send_error(405);
		return;
	}

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
		return;
	}

	#
	# meta file must exist
	#
	my $meta = sprintf('%s.js', $path);
	if (!-e $meta) {
		$connection->send_error(500, "Metadata for $hash not found");
		return;
	}

	#
	# parse meta file
	#
	my $json = read_file($meta);
	if (!$json) {
		$connection->send_error(500, "Metadata for $hash not readable");
		return;
	}

	my $info = decode_json($json);
	if (!$info) {
		$connection->send_error(500, "Metadata for $hash not parseable");
		return;
	}

	#
	# avoid sending the entire file if the client already has it cached:
	#
	my $date = $request->header('If-Modified-Since');
	my $etag = $request->header('If-None-Match');

	if (
		($date && (stat($path))[9] <= str2time($date)) ||
		($etag && $etag eq $hash)
	) {
		$connection->send_status_line(304);
		return;
	}

	#
	# cache miss, so send the file to the client
	#
	$connection->send_status_line;
	$connection->send_header('Content-Type',        $info->{'type'});
	$connection->send_header('Content-Disposition',	sprintf('attachment;filename="%s"', $info->{'name'})),
	$connection->send_header('Content-Length',      (stat($path))[7]);
	$connection->send_header('Last-Modified',       time2str((stat($path))[9]));
	$connection->send_header('ETag',		$hash);
	$connection->send_header('Connection',          'close');
	$connection->send_crlf;
	$connection->send_file($path);
}

#
# milter mode - read a message on STDIN, parse into parts,
# and examine each part, detaching as needed, then emit
# the filtered message on STDOUT
#
sub run_as_milter {

	#
	# check and secure the temporary directory
	#
	if (-e $conf->{'milter'}->{'tmpdir'}) {
		# make sure tmpdir is readable only by this user
		chmod(0600, $conf->{'milter'}->{'tmpdir'});

	} else {
		# create temporary directory
		make_path($conf->{'milter'}->{'tmpdir'}, { 'mode' => 0600 });

	}

	#
	# instantiate MIME parser
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
		foreach my $part ($entity->parts) {
			check_entity($part);
		}

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
	my $url    = get_url($hash);
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
		}));
		$handle->close;
		chmod(0400, $meta);
	}

	#
	# rebuilt the entity as plaintext containing a link to the detached file
	#
	$entity->build(
		'Type'	=> 'text/plain',
		'Data'	=> get_msg($url),
	);
}

#
# generate a URL
#
sub get_url {
	my $url = $conf->{'milter'}->{'urlfmt'};
	$url =~ s/\{host\}/$conf->{'server'}->{'host'}/g;
	$url =~ s/\{port\}/$conf->{'server'}->{'port'}/g;
	$url =~ s/\{hash\}/$_[0]/g;
	return $url;
}

#
# generate a plaintext message
#
sub get_msg {
	my $url = shift;
	my $msg = $conf->{'milter'}->{'msgfmt'};
	$msg =~ s/\{url\}/$url/g;
	return $msg;
}

#
# hash a file
#
sub hash_file {
	my $digest = Digest::SHA->new($conf->{'common'}->{'alg'});
	$digest->add($conf->{'common'}->{'key'});
	$digest->addfile(shift, 'b');
	return lc($digest->hexdigest);
}
