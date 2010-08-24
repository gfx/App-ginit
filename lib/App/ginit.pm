package App::ginit;
use 5.008_001;
use Mouse;

our $VERSION = '0.01';

use File::Which ();
use Config;
use constant WIN32 => $^O eq 'MSWin32';
use constant SUNOS => $^O eq 'solaris';

with 'MouseX::Getopt';

has verbose => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has try_lwp => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

has _git => (
    is  => 'ro',
    isa => 'Str',

    lazy => 1,
    default => sub {
        my($self) = @_;
        return $self->which('git') || $self->diag_fail("Command not found: git");
    },
);

sub run {
    my($self) = @_;

    foreach my $archive(@{$self->extra_argv}) {
        $self->process_one($archive);
    }
}

sub process_one {
    my($self, $uri) = @_;

    my $file = $self->fetch_module($uri);
    my $dir  = $self->unpack( $self->fetch_module($file) );
    if(not defined $dir) {
        $self->diag_fail("No root directry found for $file");
    }
    chdir $dir;
    $self->git('init')
        && $self->git(add => '.')
        && $self->git(commit => '-m', "Initial import from $uri")
        && $self->git(tag    => 'initial')
        && $self->git(tag    => $file) # alias
        && $self->diag("Looks good. Try `cd $dir`\n");
}

sub diag {
    my($self, @args) = @_;
    print @args;
}

sub chat {
    my($self, @args) = @_;
    print @args if $self->verbose;
}

sub diag_file {
    my($self, @args) = @_;
    die @args, "\n";
}

sub which {
    my($self, $command) = @_;
    return File::Which::which($command);
}

sub git {
    my($self, @args) = @_;
    $self->chat("git @args\n");
    return system($self->_git, @args) == 0;
}

sub fetch_module { # based on cpanm's fetch_module()
    my($self, $uri) = @_;

    return $uri if -e $uri;

    # Ugh, $dist->{filename} can contain sub directory
    my $name = File::Basename::basename($uri);

    my $cancelled;
    my $fetch = sub {
        my $file;
        eval {
            local $SIG{INT} = sub { $cancelled = 1; die "SIGINT\n" };
            $self->mirror($uri, $name);
            $file = $name if -e $name;
        };
        $self->chat("$@") if $@ && $@ ne "SIGINT\n";
        return $file;
    };

    my($try, $file);
    while ($try++ < 3) {
        $file = $fetch->();
        last if $cancelled or $file;
        $self->diag_fail("Download $uri failed. Retrying ... ");
    }

    if ($cancelled) {
        $self->diag_fail("Download cancelled.");
    }

    unless ($file) {
        $self->diag_fail("Failed to download $uri");
    }

    return $file;
}


# The following stuff are just copied from App::cpanminus::script

sub get      { $_[0]->{_backends}{get}->(@_) }
sub mirror   { $_[0]->{_backends}{mirror}->(@_) }
sub redirect { $_[0]->{_backends}{redirect}->(@_) }
sub untar    { $_[0]->{_backends}{untar}->(@_) }
sub unzip    { $_[0]->{_backends}{unzip}->(@_) }

sub unpack :method {
    my($self, $file) = @_;
    $self->chat("Unpacking $file\n");
    my $dir = $file =~ /\.zip/i ? $self->unzip($file) : $self->untar($file);
    unless ($dir) {
        $self->diag_fail("Failed to unpack $file: no directory");
    }
    return $dir;
}

sub BUILD {
    my $self = shift;

    return if $self->{initialized}++;

    if ($self->{make} = $self->which($Config{make})) {
        $self->chat("You have make $self->{make}\n");
    }

    # use --no-lwp if they have a broken LWP, to upgrade LWP
    if ($self->{try_lwp} && eval { require LWP::UserAgent; LWP::UserAgent->VERSION(5.802) }) {
        $self->chat("You have LWP $LWP::VERSION\n");
        my $ua = sub {
            LWP::UserAgent->new(
                parse_head => 0,
                env_proxy => 1,
                agent => __PACKAGE__ . "/$VERSION",
                timeout => 30,
                @_,
            );
        };
        $self->{_backends}{get} = sub {
            my $self = shift;
            my $res = $ua->()->request(HTTP::Request->new(GET => $_[0]));
            return unless $res->is_success;
            return $res->decoded_content;
        };
        $self->{_backends}{mirror} = sub {
            my $self = shift;
            my $res = $ua->()->mirror(@_);
            $res->code;
        };
        $self->{_backends}{redirect} = sub {
            my $self = shift;
            my $res = $ua->(max_redirect => 1)->simple_request(HTTP::Request->new(GET => $_[0]));
            return $res->header('Location') if $res->is_redirect;
            return;
        };
    } elsif (my $wget = $self->which('wget')) {
        $self->chat("You have $wget\n");
        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-q';
            open my $fh, "$wget $uri $q -O - |" or die "wget $uri: $!";
            local $/;
            <$fh>;
        };
        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-q';
            system "$wget --retry-connrefused $uri $q -O $path";
        };
        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            my $out = `$wget --max-redirect=0 $uri 2>&1`;
            if ($out =~ /^Location: (\S+)/m) {
                return $1;
            }
            return;
        };
    } elsif (my $curl = $self->which('curl')) {
        $self->chat("You have $curl\n");
        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-s';
            open my $fh, "$curl -L $q $uri |" or die "curl $uri: $!";
            local $/;
            <$fh>;
        };
        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;
            my $q = $self->{verbose} ? '' : '-s';
            system "$curl -L $uri $q -# -o $path";
        };
        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            my $out = `$curl -I -s $uri 2>&1`;
            if ($out =~ /^Location: (\S+)/m) {
                return $1;
            }
            return;
        };
    } else {
        require HTTP::Lite;
        $self->chat("Falling back to HTTP::Lite $HTTP::Lite::VERSION\n");
        my $http_cb = sub {
            my($uri, $redir, $cb_gen) = @_;

            my $http = HTTP::Lite->new;

            my($data_cb, $done_cb) = $cb_gen ? $cb_gen->() : ();
            my $req = $http->request($uri, $data_cb);
            $done_cb->($req) if $done_cb;

            my $redir_count;
            while ($req == 302 or $req == 301) {
                last if $redir_count++ > 5;
                my $loc;
                for ($http->headers_array) {
                    /Location: (\S+)/ and $loc = $1, last;
                }
                $loc or last;
                if ($loc =~ m!^/!) {
                    $uri =~ s!^(\w+?://[^/]+)/.*$!$1!;
                    $uri .= $loc;
                } else {
                    $uri = $loc;
                }

                return $uri if $redir;

                my($data_cb, $done_cb) = $cb_gen ? $cb_gen->() : ();
                $req = $http->request($uri, $data_cb);
                $done_cb->($req) if $done_cb;
            }

            return if $redir;
            return ($http, $req);
        };

        $self->{_backends}{get} = sub {
            my($self, $uri) = @_;
            return $self->file_get($uri) if $uri =~ s!^file:/+!/!;
            my($http, $req) = $http_cb->($uri);
            return $http->body;
        };

        $self->{_backends}{mirror} = sub {
            my($self, $uri, $path) = @_;
            return $self->file_mirror($uri, $path) if $uri =~ s!^file:/+!/!;

            my($http, $req) = $http_cb->($uri, undef, sub {
                open my $out, ">$path" or die "$path: $!";
                binmode $out;
                sub { print $out ${$_[1]} }, sub { close $out };
            });

            return $req;
        };

        $self->{_backends}{redirect} = sub {
            my($self, $uri) = @_;
            return $http_cb->($uri, 1);
        };
    }

    my $tar = $self->which('tar');
    my $tar_ver;
    my $maybe_bad_tar = sub { WIN32 || SUNOS || (($tar_ver = `$tar --version 2>/dev/null`) =~ /GNU.*1\.13/i) };

    if ($tar && !$maybe_bad_tar->()) {
        chomp $tar_ver;
        $self->chat("You have $tar: $tar_ver\n");
        $self->{_backends}{untar} = sub {
            my($self, $tarfile) = @_;

            my $xf = "xf" . ($self->{verbose} ? 'v' : '');
            my $ar = $tarfile =~ /bz2$/ ? 'j' : 'z';

            my($root, @others) = `$tar tf$ar $tarfile`
                or return undef;

            chomp $root;
            $root =~ s{^(.+?)/.*$}{$1};

            system "$tar $xf$ar $tarfile";
            return $root if -d $root;

            $self->diag_fail("Bad archive: $tarfile");
            return undef;
        }
    } elsif ( $tar
             and my $gzip = $self->which('gzip')
             and my $bzip2 = $self->which('bzip2')) {
        $self->chat("You have $tar, $gzip and $bzip2\n");
        $self->{_backends}{untar} = sub {
            my($self, $tarfile) = @_;

            my $x = "x" . ($self->{verbose} ? 'v' : '') . "f -";
            my $ar = $tarfile =~ /bz2$/ ? $bzip2 : $gzip;

            my($root, @others) = `$ar -dc $tarfile | $tar tf -`
                or return undef;

            chomp $root;
            $root =~ s{^(.+?)/.*$}{$1};

            system "$ar -dc $tarfile | $tar $x";
            return $root if -d $root;

            $self->diag_fail("Bad archive: $tarfile");
            return undef;
        }
    } elsif (eval { require Archive::Tar }) { # uses too much memory!
        $self->chat("Falling back to Archive::Tar $Archive::Tar::VERSION\n");
        $self->{_backends}{untar} = sub {
            my $self = shift;
            my $t = Archive::Tar->new($_[0]);
            my $root = ($t->list_files)[0];
            $root =~ s{^(.+?)/.*$}{$1};
            $t->extract;
            return -d $root ? $root : undef;
        };
    } else {
        $self->{_backends}{untar} = sub {
            die "Failed to extract $_[1] - You need to have tar or Archive::Tar installed.\n";
        };
    }

    if (my $unzip = $self->which('unzip')) {
        $self->chat("You have $unzip\n");
        $self->{_backends}{unzip} = sub {
            my($self, $zipfile) = @_;

            my $opt = $self->{verbose} ? '' : '-q';
            my(undef, $root, @others) = `$unzip -t $zipfile`
                or return undef;

            chomp $root;
            $root =~ s{^\s+testing:\s+(.+?)/\s+OK$}{$1};

            system "$unzip $opt $zipfile";
            return $root if -d $root;

            $self->diag_fail("Bad archive: [$root] $zipfile");
            return undef;
        }
    } else {
        $self->{_backends}{unzip} = sub {
            eval { require Archive::Zip }
                or die "Failed to extract $_[1] - You need to have unzip or Archive::Zip installed.\n";
            my($self, $file) = @_;
            my $zip = Archive::Zip->new();
            my $status;
            $status = $zip->read($file);
            $self->diag_fail("Read of file[$file] failed")
                if $status != Archive::Zip::AZ_OK();
            my @members = $zip->members();
            my $root;
            for my $member ( @members ) {
                my $af = $member->fileName();
                next if ($af =~ m!^(/|\.\./)!);
                $root = $af unless $root;
                $status = $member->extractToFileNamed( $af );
                $self->diag_fail("Extracting of file[$af] from zipfile[$file failed")
                    if $status != Archive::Zip::AZ_OK();
            }
            return -d $root ? $root : undef;
        };
    }
}

no Mouse;
__PACKAGE__->meta->make_immutable();
__END__

=head1 NAME

App::ginit - Command line tool to get, unpack and git-import source code archives

=head1 SYNOPSIS

  $ ginit http://example.com/app-1.0.0.tar.gz
  # or
  $ ginit app-1.0.0.tar.gz

=head1 DESCRIPTION

App::ginit is ...

=head1 AUTHOR

Goro Fuji (gfx) E<lt>gfuji at cpan.orgE<gt>

=head1 SEE ALSO

L<git(1)>

L<App::gh> - provides C<gh(1)> command

L<Git::CPAN::Patch> - provides a number of git sub-commands related to CPAN and git

=head1 LICENSE

Copyright (c) Fuji, Goro (gfx).

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
