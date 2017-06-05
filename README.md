# NAME

`detacher` - a program that can remove large attachments from email messages
and make them available via a web server.

# USAGE

`detacher` has two modes which can be selected using the `--mode` argument:

- `--mode=milter`: milter mode; this is the default. `detacher` accepts
an Internet mail message on `STDIN`, replaces any attachments with links, and
emits it on `STDOUT`.
- `--mode=server`: server mode. `detacher` starts up an HTTP server and
serves detached files.

# CONFIGURATION

You can configure `detacher` using a configuration file which can be specified
using the `--config=FILE` argument. The file must be in JSON format. If a
configuration file is not specified, `detacher` will use the following default
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
detached from the message and stored in `/tmp`. It will be replaced with a
plaintext MIME entity, containing a URL which can be used to download the file.
`$HOSTNAME` is determined using [Sys::Hostname](https://metacpan.org/pod/Sys::Hostname).

# SERVER MODE

`detacher` uses [HTTP::Daemon](https://metacpan.org/pod/HTTP::Daemon) which is a very simplistic HTTP server
implementation. It is RECOMMENDED that in production environments, you use a
reverse proxy such as Nginx or Squid in front of the `detacher` server.

# INSTALLATION

## MILTER INSTALLATION

TO DO.

## SERVER INSTALLATION

Simply add something like this to your `/etc/rc.local`:

    /path/to/detacher.pl --config=CONF --mode=server 1>/dev/null 2>&1 &

## DEPENDENCIES

`detacher` needs:

- [Digest::SHA](https://metacpan.org/pod/Digest::SHA)
- [File::Copy](https://metacpan.org/pod/File::Copy)
- [File::Slurp](https://metacpan.org/pod/File::Slurp)
- [Getopt::Long](https://metacpan.org/pod/Getopt::Long)
- [HTTP::Daemon](https://metacpan.org/pod/HTTP::Daemon)
- [HTTP::Date](https://metacpan.org/pod/HTTP::Date)
- [IO::File](https://metacpan.org/pod/IO::File)
- [JSON](https://metacpan.org/pod/JSON)
- [MIME::Parser](https://metacpan.org/pod/MIME::Parser)
- [Mail::Internet](https://metacpan.org/pod/Mail::Internet)
- [Pod::Usage](https://metacpan.org/pod/Pod::Usage)
- [Sys::Hostname](https://metacpan.org/pod/Sys::Hostname)

Many of these modules will already be installed or can be got through CPAN.

# COPYRIGHT

Copyright 2017 Gavin Brown. You can use and/or modify this program under the
same terms as Perl itself.
