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

## Common

- `dir` - where detached files are stored. The default value is `/tmp`,
which is UNSAFE as many operating system will purge the contents of this
directory during a power cycle.
- `alg` - the hash algorithm to use. The default value is `sha256`
which probably should not be changed unless you have good reason
- `key` - if access to the web server is not restricted, then there is
a risk that an attacker might perform a "brute force" attack using known hash
values to learn if a particular file is present. This risk can be mitigated by
setting the `key` parameter to a non-empty value. **Important Note:** if this
value is ever changed, you will need to rename every detached file!

## Milter

- `tmpdir` - `detacher` uses the [MIME::Parser](https://metacpan.org/pod/MIME::Parser) library which writes
temporary files to disk. This parameter controls which directory is used. Any
files written to this location are removed when `detacher` is finished.
- `size` - any attachments larger than this size are detached. The
default value is 2MB.
- `urlfmt` - this is a template used to construct a URL. The default
value is `http://{host}:{port}/{hash}` which will be populated using the
values from the `server` section; however, if you are using a reverse proxy
in front of the `detacher` server, then you will want to change this value.
- `msgfmt` - this is the template for the plaintext message that will
replace the attachment in the filtered message. Any instance of the string
`{url}` will be replaced with the URL.

## Server

- `name` - the DNS name of the server. The default value is that
returned by `Sys::Hostname`.
- `addr` - the IP address to bind to on the server host. The
default value is `0.0.0.0` but may be changed to some other value if a
reverse proxy is used.
- `port` - The TCP port to bind to. The default value is `8080`.

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
